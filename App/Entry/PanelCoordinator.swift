import AppKit
import ApplicationServices
import Combine
import QuartzCore
import SwiftUI
import os

/// Shared duration for drawer-related animations. AppKit (panel frame / alpha) and SwiftUI (content scale / grid reflow) both use it,
/// so the "panel size slide" and the "inner content animation" have the same duration and stay in step (Codex: v1 picks the panel as primary + content with the same parameters).
enum DrawerAnimation {
    static let duration: TimeInterval = 0.22
}

/// Panel open/close + content entrance motion for popups/drawers (fast out, soft stop, close to native Stacks feel, owner 2026-07-06).
/// The taskbar width / panel frame layout animations still use DrawerAnimation.duration=0.22; the two durations must not be merged (AGENTS).
enum PopoverAnimation {
    static let openDuration: TimeInterval = 0.18
    static let closeDuration: TimeInterval = 0.13
    /// Strong ease-out: fast start, gentle finish, like the native pop-out feel.
    static func curve() -> CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.0)
    }

    /// Native stack open / close, measured: grid and fan both take 0.25s. Change only against a
    /// new native reading.
    static let stackDuration: TimeInterval = 0.25
    /// The grid's curve is Core Animation's default (the native animator sets none).
    static func gridCurve() -> CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1)
    }
    /// The fan's item positions fly on ease-in-ease-out (fit error 0.010 against the recording).
    static func fanCurve() -> CAMediaTimingFunction {
        CAMediaTimingFunction(name: .easeInEaseOut)
    }
}

/// Runs once when Core Animation reports the animation started, i.e. the render server has
/// taken the transaction that carried it.
final class AnimationStartSignal: NSObject, CAAnimationDelegate {
    private var onStart: (() -> Void)?

    init(_ onStart: @escaping () -> Void) { self.onStart = onStart }

    func animationDidStart(_ anim: CAAnimation) {
        onStart?()
        onStart = nil
    }
}

/// Where a folder popup was asked for. Only a pinned folder's own chip reads its view mode and
/// shows the open look on the chip; a Finder window's preview is always the grid.
enum FolderPopupOrigin {
    case pinnedFolder
    case finderWindowPreview
}

@MainActor
final class PanelCoordinator: NSObject {
    /// Panel geometry follows the user's bar height, so these are **instance** properties that
    /// read the store; only `shadowPadding` stays static (fixed 20, referenced by the drawer
    /// and both popups).
    var layoutMetrics: PanelLayoutMetrics { settingsStore.dockPanelHeight.metrics }
    var panelHeight: CGFloat { layoutMetrics.panelHeight }
    var windowHeight: CGFloat { layoutMetrics.windowHeight }
    var capsuleWidth: CGFloat { layoutMetrics.capsuleWidth }
    /// Corner radius of the glass background window. It must use the same value as the SwiftUI taskbar backplate, otherwise the window blur would show square corners
    /// outside the glass's rounded corners. Both sides share one source: `DockShape.taskbarCornerRadius`.
    /// Whether the five floating panels use native Liquid Glass -- a **single source of truth**.
    ///
    /// The criterion is "did the taskbar's glass composition get built successfully": the background window is built in `setupDockPanel`,
    /// while the drawer and both popups are lazily built on demand, so by the time they are created this value is already settled. All five panels share the same decision,
    /// so we never get "the bar is glass but the adjacent capsule is still frosted glass".
    var usesLiquidGlass: Bool { dockGlassBackgroundPanel != nil }

    /// Builds a floating panel. **When glass is on, `DockLiquidGlassPanel` must be used; none of the five panels may be missed.**
    ///
    /// Liquid Glass's "active" appearance is decided by the **window's** key / main / active state, but all of our panels
    /// are `.nonactivatingPanel` and never become key. With a plain `NonConstrainingPanel` the glass
    /// falls back to the "inactive" tier and renders as an almost opaque milky-white slab. `DockLiquidGlassPanel` overrides those five
    /// private appearance checks so the window always reports as active.
    ///
    /// Before 2026-08-17 **only the taskbar** used this subclass, so the drawer / capsule / both popups / bubble were not
    /// the same material as it (owner reported "the drawer area doesn't look like liquid glass either"). Light transmission measured with black / white target windows:
    ///
    /// | | taskbar | capsule | drawer |
    /// |---|---|---|---|
    /// | before fix | 145 | **172** | **170** |
    /// | after fix | 145 | 149 | 148 |
    ///
    /// A gap of 25-27 levels -> converged to within 4 levels. **Do not use "looks about the same on the same background" as verification**:
    /// on a black-and-white striped target both read mid-gray, which is how I once wrongly concluded "the capsule matches the taskbar".
    /// The criterion must be the **transmission** (the difference between readings of the same panel over pure black and pure white backgrounds).
    ///
    /// The two SwiftUI-side lines `.materialActiveAppearance(.active)` / `.environment(\.appearsActive,)`
    /// **cannot override this layer**: they govern the view environment, while window state has to be fixed on the window.
    /// Experiment switch: `DOCK_PANEL_LEVEL=<raw>` overrides the window level of the three taskbar panels (default .floating=3).
    /// Purpose: verify whether "windows at a high enough level (system Dock=20, menu bar higher) are exempt from being baked
    /// into WindowServer's desktop-slide transition snapshot". On 2026-08-30 burst captures confirmed the gray overlay = the bar baked into the two side snapshots and then sliding on top.
    static let panelLevelOverride: NSWindow.Level? = DebugSwitch.panelLevel.value().flatMap(Int.init).map { NSWindow.Level(rawValue: $0) }

    var taskbarPlateCornerRadius: CGFloat {
        DockShape.taskbarCornerRadius * settingsStore.dockPanelHeight.scale
    }
    static let shadowPadding: CGFloat = PanelLayoutMetrics.shadowPadding

    let runtime: AppRuntime
    let drawerStore: DrawerStore
    let messagingStore: MessagingAppStore
    let badgeStore: BadgeStore
    let stripOrderStore: StripOrderStore
    let drawerOrderStore: DrawerOrderStore
    let settingsStore: AppSettingsStore
    let pinnedFolderStore: PinnedFolderStore
    let folderCoverStore: PinnedFolderCoverStore
    let shelfStore: ShelfStore
    let keptAppStore: KeptAppStore
    let runningApplicationStore: RunningApplicationStore
    let appMembershipController: AppMembershipController
    /// The single execution queue for moving external files into a pinned folder: eligibility checks and disk operations are serialized per drop batch.
    let fileDropQueue = DispatchQueue(label: "app.neobar.NeoBar.folder-drop", qos: .userInitiated)
    /// Entry point for right-clicking "Add Folder..." on a folder chip / staging cell (injected by AppDelegate; it owns the NSOpenPanel).
    var onAddFolder: () -> Void = {}
    /// Shows the NeoBar menu on right-click of the taskbar / capsule. The menu is owned by `StatusMenuController`; this only forwards the event.
    /// In normal operation the app is `.accessory` (no menu bar, hence no ⌘,), so if the status-bar icon gets squeezed out or hidden behind the notch,
    /// this is the only way left to open Settings.
    var onRequestTaskbarMenu: ((NSEvent, NSView) -> Void)?
    var dockPanel: NSPanel?
    var dockGlassBackgroundPanel: NonConstrainingPanel?
    var dockGlassBackgroundView: DockTaskbarLiquidGlassBackgroundView?
    /// SwiftUI host for the main taskbar. The window frame belongs to PanelCoordinator; content size is only read from here.
    var dockContentHost: ManualPanelHost?
    var drawerPanel: NSPanel?
    var capsulePanel: NSPanel?
    /// SwiftUI host for the capsule. The capsule's width and height are fixed (`capsuleWidth`), and nobody currently reads its `fittingSize`,
    /// but it is still held **strongly** instead of being discarded with `_ =`: if discarded, only the view hierarchy would indirectly keep the container alive, and the day
    /// a `deinit` cleanup is added to `ManualPanelHost`, the capsule would silently break.
    var capsuleContentHost: ManualPanelHost?
    /// The hosting view that actually carries SwiftUI for the drawer (the drawer's contentView is a plain NSView container, so fittingSize must be read from this one).
    var drawerContentHost: NSView?
    /// A typed reference to the same host, used for "only swap rootView on each open". **Built only once** (2026-09-04):
    /// previously every open built a fresh drawer view tree + synchronously measured size + rendered the first frame, stalling the main thread 55-135ms,
    /// right at the start of the 0.18s fade-in, which was the main cause of the owner's "drawer drops frames when opening". While closed it stays alive just like the drawer on the closed screen under ③④,
    /// and drag callbacks always ask `isDrawerOpen()` first, so it is not new state.
    var drawerHosting: NSHostingView<DrawerRootView>?
    /// The available height that the rootView currently in the host was built with; if unchanged, rootView is not even swapped, so SwiftUI does no graph update at all on open.
    var drawerHostedLimits: StackGridLayout.Limits?
    /// The drawer plate's arrow. One for the coordinator's lifetime: the drawer host is built once
    /// and holds on to it. Written only by `syncDrawerArrow`.
    let drawerArrow = StackPopupArrowModel()
    /// The drawer's showings: the open plate holds its columns (`DrawerShowingModel`).
    let drawerShowing = DrawerShowingModel()
    /// Keeps the arrow on the capsule while the drawer's frame animates (`syncDrawerArrow`).
    var drawerArrowFollowTimer: Timer?
    /// The sole authority for cross-panel dragging (dragging a card into the drawer, route C): the carrier panel + mouse monitor + drop finalization all live inside it.
    /// Must be built before setupDockPanel/setupCapsulePanel because it has to be injected into those two panels' hosting.
    /// Cross-panel drag authority. **There is exactly one per process**, created by the orchestration layer and injected into every unit
    /// (shared by the N taskbars under ③④: the drop zone is the union of the units, and the carrier panel is one set per screen anyway).
    let dragController: DragController
    /// Suspended state after permission loss. Deliberately **not** reusing `visibilityState.hideReasons`:
    /// that set is for fullscreen and edge auto-hide, and mixing in would let a bottom-edge wake pull the panel back onto the screen.
    var isSuspendedForPermissionLoss = false
    var drawerLocalMonitor: Any?
    var drawerGlobalMonitor: Any?
    // MARK: Folder / staging popup state (only one live session at a time, plus at most one that is collapsing)
    /// Content currently held by the shared popup: a pinned folder, the staging area, or the Trash.
    enum PopupContent: Equatable {
        case folder(path: String)
        case shelf
        case trash
    }
    /// One showing of the popup, from open to the end of its close animation. Every asynchronous
    /// write-back (content resize, deferred re-measure, frame tween, animation completion, menu
    /// return) carries the session's id and is dropped when that session is no longer the one it
    /// belongs to: an exiting session's content is still alive and may still report.
    final class FolderPopupSession {
        enum Presentation: Equatable { case grid, fan, list }
        let id: Int
        let content: PopupContent
        let origin: FolderPopupOrigin
        let presentation: Presentation
        let anchor: CGRect
        /// nil for the list, which is a menu.
        var panel: NSPanel?
        var contentHost: NSView?
        var arrow: StackPopupArrowModel?
        var listMenu: StackPopupListMenu?
        var fanView: StackPopupFanView?
        /// The fan's window while items fly: down over the chip they fly out of.
        var fanFlightFrame: CGRect = .zero
        /// The fan's window once landed: its bottom on the chip's top, so the chip and its
        /// neighbours take their own clicks.
        var fanRestFrame: CGRect = .zero
        /// The transparent panel above the bar that catches clicks while the fan flies open.
        var clickCatcher: NSPanel?
        var openedAt = Date()

        init(id: Int, content: PopupContent, origin: FolderPopupOrigin, presentation: Presentation, anchor: CGRect) {
            self.id = id
            self.content = content
            self.origin = origin
            self.presentation = presentation
            self.anchor = anchor
        }
    }
    /// The live session: it takes clicks, counts in hit tests and holds off auto-hide.
    var activePopupSession: FolderPopupSession?
    /// The session playing its close animation, at most one; it ignores the mouse.
    var exitingPopupSession: FolderPopupSession?
    /// The windows on screen: the live session's and the exiting one's, so the old popup shrinks
    /// back while the new one grows, as on the native Dock. Each session gets its own window.
    var folderPopupPanels: [NSPanel] = []
    var sparePopupPanel: NSPanel?
    var popupSessionCounter = 0
    var popupReopenCooldown = StackReopenCooldown()
    /// The open folder's chip look (pile arrow / dimmed), read by this unit's strip.
    let folderPopupPresence = FolderPopupPresence()
    var popupLocalMonitor: Any?
    var popupGlobalMonitor: Any?
    var lastPopupTargetFrame: NSRect = .zero
    /// The live session's anchor chip (screen coordinates); `.zero` when none is open.
    var popupAnchorVisibleRect: CGRect { activePopupSession?.anchor ?? .zero }
    /// Current popup content (nil = not open).
    var openPopupContent: PopupContent? { activePopupSession?.content }
    /// Convenience view: gives the path only when the popup holds a folder (for folder-only logic such as the sort subscription and closing on removal).
    var openPopupPath: String? {
        if case let .folder(path) = openPopupContent { return path }
        return nil
    }
    /// **Logical** open state of the popup (during the collapse animation the panel is still visible but logically closed; same as drawerWantsOpen).
    var folderPopupWantsOpen: Bool { activePopupSession != nil }
    var lastPopupSize = CGSize(width: 424, height: 240)
    /// Hand-rolled per-frame interpolation timer for popup toggle/reposition (interpolates by centerX/bottomY/width/height, replacing
    /// NSWindow.animator().setFrame's raw x/y/width/height linear interpolation, which has no anchor concept: once the relative positions of two folder
    /// frames change, the growth direction randomly drifts toward some corner instead of a stable "bottom-anchored, horizontally centered").
    var folderPopupFrameTimer: Timer?
    /// Incremented every time a new tween starts. The tick callback checks this token before changing the frame:
    /// Timer.invalidate() cannot stop a callback that "has already fired but whose Task is still queued on the main actor and hasn't run yet",
    /// so invalidate alone is not enough; the token lets stale queued tasks turn themselves into no-ops.
    var folderPopupTweenToken: Int = 0
    /// Target frame of the tween currently in flight (nil = none in flight). The fallback correction from the double defer often re-enters with the **same** target,
    /// and a blind restart would interrupt the just-started animation and reset the clock (speed jump + longer total duration); with an identical target we let it through so it runs to completion.
    var folderPopupTweenTarget: NSRect?
    // MARK: Window-title tooltip (dedicated panel, does not reuse folderPopupPanel)
    var windowTitleTooltipPanel: NSPanel?
    var windowTitleTooltipRequest: WindowTitleTooltipRequest?
    var windowTitleTooltipSuppressedChipID: String?
    /// The request a suppression took off screen: a closing folder popup brings it back.
    var windowTitleTooltipSuppressedRequest: WindowTitleTooltipRequest?
    var windowTitleTooltipLingerTimer: Timer?
    /// Watchdog that runs only while the bubble is on screen; see `startWindowTitleTooltipWatchdog`.
    var windowTitleTooltipWatchdog: Timer?
    var windowTitleTooltipLocalMonitor: Any?
    var windowTitleTooltipGlobalMonitor: Any?
    /// Reuses the same hosted view tree: creating a new `NSHostingView` on every hover would flash when switching chips and also pay the build cost for nothing.
    var windowTitleTooltipHosting: NSHostingView<WindowTitleTooltipView>?
    var windowTitleTooltipHost: ManualPanelHost?
    var pinnedFolderStoreSubscription: AnyCancellable?
    var pinnedFolderSortSubscription: AnyCancellable?
    var pinnedFolderViewModeSubscription: AnyCancellable?
    var snapshotWidthSubscription: AnyCancellable?
    var drawerStoreWidthSubscription: AnyCancellable?
    var messagingStoreWidthSubscription: AnyCancellable?
    var keptAppStoreSubscription: AnyCancellable?
    var runningApplicationStoreSubscription: AnyCancellable?
    var dragSpringSubscription: AnyCancellable?
    var dragInhibitorSubscription: AnyCancellable?
    var edgeDelaySubscription: AnyCancellable?
    var taskbarScreenPlacementSubscription: AnyCancellable?
    var displayTopologySubscription: AnyCancellable?
    var showShelfSubscription: AnyCancellable?
    var showTrashSubscription: AnyCancellable?
    var dockPanelHeightSubscription: AnyCancellable?
    /// Height-change transaction generation: swallows animated relayouts other paths queue
    /// while a height change is in flight (see `beginPanelHeightChange`).
    var panelHeightChangeGeneration: UInt64 = 0
    /// The drag session when **this** unit's grip is being dragged; nil on every other unit.
    var interactiveResize: DockHeightDragSession?
    /// True on **every** unit while any unit's grip is being dragged (orchestrator broadcast):
    /// the height is shared, so every bar is mid-transaction. Gates animated layouts and the
    /// label-width follow; see `setInteractiveHeightResizeActive`.
    var interactiveHeightResizeActive = false
    let heightResizePresentation = PanelHeightResizePresentation()
    /// Bar height the window-lift context reports while a drag is active. Frozen at drag start
    /// so the lift controller's context set stays equal tick to tick (a changed set restores
    /// every lifted window and re-lifts ≤0.2s later — several times per second during a drag).
    var liftContextPanelHeightOverride: CGFloat?
    /// This unit's grip began (`true`) / ended (`false`) a drag. The orchestrator fans it out to
    /// every unit and remembers the origin so a topology change can end the drag cleanly.
    var onInteractiveHeightResizeSession: ((Bool) -> Void)?
    var onInteractiveHeightResizeUpdate: (() -> Void)?
    /// Handle into the strip's grip view for `cancelInteractiveResize()`.
    let resizeGripController = StripResizeGripController()
    /// The ▲▼ glyph panel that stands in for the system cursor (`PanelCoordinator+ResizeCursor`).
    var resizeCursorPanel: NSPanel?
    var resizeCursorHost: ManualPanelHost?
    /// Latest grip-zone hover report, kept so a menu opening or closing can put the ▲▼ back
    /// without waiting for the pointer to move.
    var gripHoverPointer: CGPoint?
    var resizeCursorReassertTimer: Timer?
    /// Drawer drag back to the taskbar, "only grow on release": while promotion is in progress the taskbar width is frozen, and relayout happens after the promoted state ends (drop settles / drag-out restores).
    var stripSlotCollapseSubscription: AnyCancellable?
    /// The drawer's two spring-load timer slots, shared by the bar's card drags (`updateSpringLoad`)
    /// and drags from outside the app (`PanelCoordinator+ExternalDragSpring`): the two never run at
    /// once (one needs the button down on a chip, the other on another app), and one pair of slots
    /// keeps one drawer under one clock.
    var springOpenTimer: Timer?
    /// Timer that **delays collapsing** after leaving the drawer + capsule (owner 2026-06-22: wants a delay, shouldn't close as soon as the pointer grazes the taskbar).
    var springCloseTimer: Timer?
    /// Where the drag from outside is, and which timer it armed (`ExternalDragSpringLoad`).
    var externalDragSpring = ExternalDragSpringLoad.State()
    /// Whether this drag **started from the taskbar**. A card from the taskbar dragged into the drawer body is "promoted" to a `.drawer` source (see DragController),
    /// but the spring behavior (open / delayed collapse / reopen) must apply for the entire drag, so it keys on this and not on the live source (owner 2026-06-22).
    var dragOriginatedFromStrip = false
    /// **Logical** open state of the drawer (ignores isVisible: during the fade-out animation the panel is still visible but logically closed). toggle / spring / interruptible close all look at it.
    var drawerWantsOpen = false
    /// Incremented on every openDrawer(). closeDrawerAfterAction() captures the current value and discards the close if it doesn't match when it fires,
    /// which prevents an old click's delayed close from wrongly killing a drawer that was reopened.
    var drawerActionCloseToken = 0
    /// Whether this drawer was opened by the **spring** (drag hover). If so, and the card didn't land in the drawer on release (dragged back to the taskbar) -> auto-collapse.
    var drawerSpringOpened = false
    /// bundleID of the strip card being dragged; used on release to decide whether it was taken into the drawer.
    var springDragBundleID: String?
    var lastDesiredWidth: CGFloat = 0
    /// "Follow window" for labels growing and shrinking: the label box in the bar grows per frame in real width via `LabelWidthAnimation` (`LabelBoxWidthDriver`),
    /// reporting the live width each frame (`labelBoxWidthDidTick`), and the panel sets its frame without animation in the same pass, committing together with that frame's
    /// content. Total content width = width measured at start + sum(live box width - box start width). **It cannot be measured after the fact** (it would read the previous frame,
    /// display a frame late, and the backplate would steadily lag by two frames), **nor predicted from the curve itself** (the two clocks don't align, causing +/-1 frame jitter);
    /// screen burst captures on 2026-09-13 measured both routes. After the end, one final measurement is taken as a safety net.
    var labelFollowTimer: Timer?
    var labelFollowRestWidth: CGFloat = 0
    var labelBoxStart: [String: CGFloat] = [:]
    var labelBoxLive: [String: CGFloat] = [:]
    var labelFollowDeadline: CFTimeInterval = 0
    /// Window-id set of the previous snapshot: if the set changed (cards added/removed), the 0.22s window animation runs even if the follow window is open; a snapshot whose set is unchanged
    /// while the follow window is open does not measure width (the measured value would be an intermediate one and drag the panel back).
    var lastSnapshotWindowIDs: Set<WindowID>?
    /// Expected end time of the most recent **animated** `setFrames`: the follow window's per-frame setFrame does not preempt before then (otherwise it would cut the 0.22s window animation
    /// for card add/remove into a one-step jump).
    var animatedFramesUntil: CFTimeInterval = 0
    var lastDrawerSize: CGSize = StackPopupMetrics.panelSize(
        forPlate: StackPlateMetrics.drawer.plateSize(columns: StackGridLayout.noteMinColumns, rows: 1, hasNote: false,
                                                     scrolls: false))
    /// Target-frame-driven layout: each layoutPanels computes all three targets and stores them here. Drop-zone hit testing and drawer positioning both read the **target**
    /// rather than the live frame, since during an animation the live frame is an intermediate value and would briefly disagree with the visual/logical state (Codex second review P2).
    /// The target frame sequence last actually committed by `setFrames`. Used to stop "restarting the animation when the target hasn't changed":
    /// measurement showed 8 such idle runs in the first 7 seconds after launch, 6 of them crammed into 1.1ms, which restarted the same set of window-size animations
    /// six times in a row, and every frame of them has to redraw the glass backplate and stroke.
    var lastCommittedFrames: [NSRect] = []
    var lastDockTargetFrame: NSRect = .zero
    var lastCapsuleTargetFrame: NSRect = .zero
    var lastDrawerTargetFrame: NSRect = .zero
    /// The first-frame layout is forced to be instant (the panels were just built; don't slide in from the initial/origin position).
    var didInitialLayout = false
    let logger = Logger(subsystem: "app.neobar.NeoBar", category: "dock-panel")
    let fullscreenIntentLogger = Logger(
        subsystem: "app.neobar.NeoBar",
        category: "FullscreenIntent"
    )
    var fullscreenReconcileTimer: Timer?
    var workspaceObserverTokens: [NSObjectProtocol] = []
    /// The orchestration layer owns the single `FullscreenIntentMonitor` (session event tap) and routes requests in here;
    /// this flag = "routing is connected", replacing the old `fullscreenIntentMonitor != nil` guard.
    var fullscreenIntentRoutingEnabled = false
    var fullscreenIntentTimeoutTimer: Timer?
    var fullscreenIntentGeneration: UInt64 = 0
    var fullscreenIntentTransaction: FullscreenIntentTransaction?
    var fullscreenProbeGeneration: UInt64 = 0
    var fullscreenSpaceHoldGeneration: UInt64 = 0
    var fullscreenSpaceHold: FullscreenSpaceHold?
    var fullscreenSpaceHoldTimer: Timer?
    /// Overlay-hide watch (`OverlayWindowWatch`): the CG window whose frame-fallback verdict hid the bar.
    /// Kill switch `DOCK_OVERLAY_WINDOW_WATCH=0` (falls back to the 5s reconcile alone).
    static let overlayWindowWatchEnabled =
        DebugSwitch.overlayWindowWatch.isEnabled(in: ProcessInfo.processInfo.environment)
    var overlayWindowWatchTimer: Timer?
    var overlayWindowWatchID: CGWindowID?
    /// Control+Left/Right predictive hide. **On by default**; turn it off with `DOCK_SPACE_INTENT=0`
    /// (the decision lives in `spaceSwitchEnabled` of `FullscreenIntentMonitor`). It shares the `.fullscreenTransitionPending` slot of
    /// `visibilityState` with the window-level intent transaction, so the two are mutually exclusive and only one can be active at a time.
    var fullscreenSpaceIntentGeneration: UInt64?
    var fullscreenSpaceIntentTimer: Timer?
    var fullscreenSpaceIntentVerdictTimer: Timer?
    /// Whether the last hide was due to fullscreen. If yes, the next reveal uses a 0.18s fade-in (the entrance animation for returning from fullscreen);
    /// if no, the reveal from edge auto-hide stays instant. Written only in two places: applyPanelVisibility and predictive hide.
    var lastHideWasForFullscreen = false
    /// Membership repair for "stay on all desktops" (issue #19). See the mechanism notes in `AllSpacesMembership`.
    /// Turn it off with `DOCK_SPACE_MEMBERSHIP_REPAIR=0`.
    static let spaceMembershipRepairEnabled =
        DebugSwitch.spaceMembershipRepair.isEnabled(in: ProcessInfo.processInfo.environment)
    var spaceMembershipRepairInFlight = false
    var lastActiveApplicationPID: pid_t?
    var visibilityState = PanelVisibilityState()
    var panelsAreVisible = true
    var edgeIdleHideTimer: Timer?
    var edgeWakeTimer: Timer?
    var edgeWakeTargetScreen: NSScreen?
    var edgeWakeRequiresHotZone = true
    /// The mouse monitor owned by the orchestration layer needs to be re-evaluated (edge-hide switch / display position / screen set changed).
    var onHoverMonitorsNeedReconcile: (() -> Void)?
    /// This unit's panel moved to another screen (or first layout). The orchestration layer uses it to feed every unit's screen set to the fullscreen intent tap.
    var onPanelScreenChanged: (() -> Void)?
    /// This unit's logical visibility changed (including the predictive-hide fast path). The orchestration layer does the "any visible" merge for badge gating.
    var onLogicalVisibilityChanged: ((Bool) -> Void)?
    /// This unit is about to open an auxiliary panel. The orchestration layer uses it to close same-kind panels of other units (only one drawer / popup / bubble open at a time).
    var onAccessoryWillOpen: ((PanelCoordinator, AccessoryKind) -> Void)?

    enum AccessoryKind { case drawer, popup, tooltip }

    /// Where this unit is placed (see `TaskbarUnitPlacement`). Under ③④ there is one `.fixed` unit per screen.
    let unitPlacement: TaskbarUnitPlacement
    /// Private Space host for the resident panels (one per process, owned by the orchestration layer). nil = switch off / symbol missing,
    /// and the panels keep the old `.canJoinAllSpaces` behavior. See `OverlaySpaceHost`.
    let overlaySpaceHost: OverlaySpaceHost?
    /// Surface identity of this unit's strip within the shared `DragController` (see `DragController.activeStripSurfaceID`).
    let stripSurfaceID = "strip-" + UUID().uuidString
    let displayTopologyStore: DisplayTopologyStore
    /// The fixed unit under ③④ knows which screen it is; the follow unit under ①② is nil (the per-screen filtering under ④ does not apply to it).
    var fixedUnitDisplayUUID: String? {
        if case .fixed(let uuid) = unitPlacement { return uuid }
        return nil
    }

    init(placement: TaskbarUnitPlacement,
         dragController: DragController,
         overlaySpaceHost: OverlaySpaceHost?,
         runtime: AppRuntime,
         drawerStore: DrawerStore,
         messagingStore: MessagingAppStore,
         badgeStore: BadgeStore,
         stripOrderStore: StripOrderStore,
         drawerOrderStore: DrawerOrderStore,
         settingsStore: AppSettingsStore,
         pinnedFolderStore: PinnedFolderStore,
         folderCoverStore: PinnedFolderCoverStore,
         shelfStore: ShelfStore,
         keptAppStore: KeptAppStore,
         runningApplicationStore: RunningApplicationStore,
         appMembershipController: AppMembershipController,
         displayTopologyStore: DisplayTopologyStore) {
        self.unitPlacement = placement
        self.dragController = dragController
        self.overlaySpaceHost = overlaySpaceHost
        self.runtime = runtime
        self.drawerStore = drawerStore
        self.messagingStore = messagingStore
        self.badgeStore = badgeStore
        self.stripOrderStore = stripOrderStore
        self.drawerOrderStore = drawerOrderStore
        self.settingsStore = settingsStore
        self.pinnedFolderStore = pinnedFolderStore
        self.folderCoverStore = folderCoverStore
        self.shelfStore = shelfStore
        self.keptAppStore = keptAppStore
        self.runningApplicationStore = runningApplicationStore
        self.appMembershipController = appMembershipController
        self.displayTopologyStore = displayTopologyStore
        super.init()
    }

    func start() {
        setupDockPanel()
        setupCapsulePanel()
        presentInitialPanels()
        pinResidentPanelsIfNeeded()
        prewarmDrawerHost()
        prepareSparePopupPanel()
        subscribeSnapshotWidth()
        subscribeDrawerStoreWidth()
        subscribeMessagingStoreWidth()
        subscribeKeptAppStore()
        subscribeRunningApplicationStore()
        subscribeDragSpringLoad()
        subscribeDragInhibitor()
        subscribeStripSlotCollapse()
        subscribeSettings()
        subscribePinnedFolderStore()
        setupFullscreenMonitor()
        if Self.hoverVerboseLogging { logScreenMap() }
        // Screen-parameter changes, the mouse monitor, and the fullscreen intent tap are all owned and forwarded by the orchestration layer (shared by the multiple units under ③④).
    }

    deinit {
        fullscreenReconcileTimer?.invalidate()
        fullscreenIntentTimeoutTimer?.invalidate()
        fullscreenSpaceHoldTimer?.invalidate()
        overlayWindowWatchTimer?.invalidate()
        fullscreenSpaceIntentTimer?.invalidate()
        fullscreenSpaceIntentVerdictTimer?.invalidate()
        MainActor.assumeIsolated {
            dismissWindowTitleTooltip()
            tearDownTaskbarGlassBackground()
        }
        hoverSwitchTimer?.invalidate()
        edgeIdleHideTimer?.invalidate()
        edgeWakeTimer?.invalidate()
        springOpenTimer?.invalidate()
        springCloseTimer?.invalidate()
        folderPopupFrameTimer?.invalidate()
        workspaceObserverTokens.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    func toggleDrawer() {
        if drawerWantsOpen { closeDrawer() } else { openDrawer() }
    }

    /// When permission is lost, tears down the whole panel set cleanly and hands over ownership (the caller then simply nils its reference). Idempotent.
    ///
    /// This deliberately does **not** take the "hand-maintain a list of monitors to remove" approach, since the risk of omissions is too high:
    /// `DockStripView` installs its own force-click / middle-click monitors inside its `NSViewRepresentable`,
    /// which are removed via `dismantleNSView` only when the view tree is really torn down; and `deinit` already covers
    /// the hover monitor and a whole row of timers, so that list would have to be maintained along with every new resource.
    /// So: tear down the view tree -> close the panels -> let the caller release this object so `deinit` runs.
    ///
    /// There is no symmetric resume: after permission is restored the whole process restarts, so there is no "resume running" path.
    ///
    /// Under ③④, unplugging a screen also comes through here to tear down that screen's unit (called by the orchestration layer). The shared drag controller / carrier panel
    /// are **not cleaned up here**: they are one per process and the orchestration layer cleans them once when it actually suspends.
    func tearDown() {
        guard !isSuspendedForPermissionLoss else { return }
        isSuspendedForPermissionLoss = true
        cancelInteractiveResize()
        tearDownResizeCursor()
        fullscreenIntentRoutingEnabled = false
        if let transaction = fullscreenIntentTransaction {
            cancelFullscreenIntent(generation: transaction.generation, reason: "teardown")
        }
        fullscreenIntentTimeoutTimer?.invalidate()
        fullscreenIntentTimeoutTimer = nil
        fullscreenSpaceHoldTimer?.invalidate()
        fullscreenSpaceHoldTimer = nil
        fullscreenSpaceHold = nil
        endOverlayWindowWatch()
        clearFullscreenSpaceArrowIntent()

        closeDrawer()
        closeFolderPopup(immediately: true)
        dismissWindowTitleTooltip()
        cancelHoverSwitch()
        cancelEdgeWake()
        edgeIdleHideTimer?.invalidate()
        edgeIdleHideTimer = nil

        // Replacing contentView triggers SwiftUI to tear down its tree; a separately strong-held host must be nil'd first.
        dockContentHost = nil
        capsuleContentHost = nil
        drawerContentHost = nil
        drawerHosting = nil
        drawerHostedLimits = nil
        stopDrawerArrowFollow()
        windowTitleTooltipHosting = nil
        windowTitleTooltipHost = nil
        tearDownTaskbarGlassBackground()
        for panel in [dockPanel, capsulePanel, drawerPanel, windowTitleTooltipPanel] + folderPopupPanels {
            guard let panel else { continue }
            panel.contentView = NSView()
            panel.orderOut(nil)
            panel.close()
        }
        dockPanel = nil
        capsulePanel = nil
        drawerPanel = nil
        folderPopupPanels = []
        sparePopupPanel?.close()
        sparePopupPanel = nil
        windowTitleTooltipPanel = nil
        // With all panels torn down, the "last committed target" is invalidated too; leaving it would make the first layout after rebuild be misjudged as
        // "target unchanged" and skipped, leaving the bar stuck at the old geometry.
        lastCommittedFrames = []
    }

    /// Which screen this unit's taskbar currently sits on (derived back from the panel coordinates). nil when the panel isn't built.
    var currentScreen: NSScreen? {
        dockPanel.map { panelCurrentScreen(panel: $0) }
    }

    /// Logical visibility (used for badge gating / orchestration-layer merging).
    var isLogicallyVisible: Bool { panelsAreVisible }

    /// Maximize avoidance only obtains context when NeoBar is resident and actually visible; it returns the complete geometry in one shot to avoid torn reads when switching screens.
    func windowLiftAvoidanceContext() -> WindowLiftAvoidanceContext? {
        guard !settingsStore.edgeAutoHideEnabled,
              visibilityState.isVisible,
              panelsAreVisible,
              let panel = dockPanel else {
            return nil
        }

        let screen = panelCurrentScreen(panel: panel)
        let primaryScreenHeight = Self.quartzPrimaryScreenHeight
        let geometry = WindowLiftAvoidance.Geometry(
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            // Visibility guards above stay live (a hidden or unplugged bar leaves the set);
            // only the height is frozen during a drag, see `liftContextPanelHeightOverride`.
            taskbarTop: screen.frame.minY
                + layoutMetrics.bottomGap
                + (liftContextPanelHeightOverride ?? layoutMetrics.panelHeight)
        )
        return WindowLiftAvoidanceContext(
            geometry: geometry,
            screenCGFrame: Self.toCGRect(screen),
            visibleCGFrame: WindowLiftAvoidance.quartzFrame(
                fromAppKit: screen.visibleFrame,
                primaryScreenHeight: primaryScreenHeight
            ),
            primaryScreenHeight: primaryScreenHeight
        )
    }

    // MARK: - Drag Controller (dragging a card into the drawer, route C) -- the controller is created and injected by the orchestration layer; only the geometry is provided here

    /// Drop candidate areas (screen coordinates), split by drag source:
    /// - `.strip` / `.messaging` (a taskbar card / messaging chip looking for a stash target) = capsule visible content area + 8pt tolerance (the capsule frame includes
    ///   a transparent 20pt shadowPadding border; subtracting 20 gives a 52x52 visible area, then expanding 8 for tolerance; it cannot be wider -- the capsule sits right next to the taskbar, and too wide would make
    ///   "dragging nearby gets it grabbed"); when the drawer is open, the drawer's visible content area is added. The taskbar itself is not a drop zone for them.
    /// - `.drawer` (a drawer icon looking for a move-back target) = the taskbar dock panel's visible content area (minus shadowPadding).
    /// Visible frame of the capsule (screen coordinates, target frame preferred). Used as the end point for `DragController`'s "suck into capsule" flight.
    var capsuleVisibleFrame: CGRect? {
        let frame = lastCapsuleTargetFrame != .zero ? lastCapsuleTargetFrame : capsulePanel?.frame
        return frame?.insetBy(dx: Self.shadowPadding, dy: Self.shadowPadding)
    }

    // MARK: - Window title tooltip

    /// Leave grace period: after `.exit` it does not collapse immediately but waits this long. **This is the key to feeling "hand-following".**
    /// When sweeping across a section divider the pointer briefly isn't over any card, and an immediate orderOut would flicker; a neighboring
    /// `.update` takes over and the grace period is naturally voided.
    ///
    /// **The companion "cold-start delay" has been removed; do not add it back.** It once kept a 0.05s debounce,
    /// intended to avoid flashing on every item when sweeping across a row, but it actually backfired: 0.05s coincides exactly with the dwell time of a steady sweep over a single icon
    /// (center spacing 42pt, only tens of milliseconds per cell at normal swipe speed), so most cells were already
    /// left before the timer fired. The native Dock has no such delay at all. Once the panel is kept alive, switching chips doesn't flicker anyway.
    static let windowTitleTooltipLingerDelay: TimeInterval = 0.09

    // MARK: - Target-frame-driven layout
    //
    // Codex second-review root cause: after an animation, if "reading the live frame of the previous panel that is still animating to position the next one", it reads the stale value from the animation start
    // -> the capsule is positioned against the old taskbar, the drawer against the old capsule -> after the taskbar widens they are misaligned and the drawer overlaps the taskbar. Fix: compute all three **target**
    // frames at once (pure function, none reads a live frame), and the three panels each slide toward their targets in the **same animation group**.

    static let layoutAnimationDuration: TimeInterval = DrawerAnimation.duration

    // MARK: - Membership repair for "stay on all desktops" (issue #19)

    /// Panels that must be present on every desktop. The drawer / folder popup / hover bubble are transient panels: the next time they pop up,
    /// `orderFrontRegardless` naturally lands them on the current desktop, and users never wait for them on other desktops, so they don't take part in the repair.
    var allSpacesPanels: [NSPanel] {
        [dockGlassBackgroundPanel, dockPanel, capsulePanel].compactMap { $0 }
    }

    func panelCurrentScreen(panel: NSPanel) -> NSScreen {
        // Use the center of the visible content area (inset by shadowPadding) so the 12pt shadow
        // bleed below screen.frame.minY doesn't cause first(where:intersects) to return the wrong
        // adjacent screen in multi-monitor setups (e.g. vertically stacked 3-screen layouts).
        let visualCenter = CGPoint(
            x: panel.frame.midX,
            y: panel.frame.minY + Self.shadowPadding + panelHeight / 2
        )
        return NSScreen.screens.first(where: { $0.frame.contains(visualCenter) })
            ?? NSScreen.screens.first(where: { $0.frame.intersects(panel.frame) })
            ?? NSScreen.main ?? NSScreen.screens[0]
    }

    // AppKit frame (bottom-left origin) → CG/Quartz frame (top-left origin of primary screen)
    static func toCGRect(_ screen: NSScreen) -> CGRect {
        let f = screen.frame
        return CGRect(
            x: f.minX,
            y: quartzPrimaryScreenHeight - f.maxY,
            width: f.width,
            height: f.height
        )
    }

    /// `NSScreen.main` follows the key window and may be a secondary display. Quartz global
    /// coordinates are anchored to the menu-bar display, which is always the first screen.
    private static var quartzPrimaryScreenHeight: CGFloat {
        NSScreen.screens.first?.frame.maxY ?? NSScreen.main?.frame.maxY ?? 0
    }

    /// `DOCK_FULLSCREEN_SLS_VERDICT=0` -> `.notOnThisScreen` is treated as `.windowed` using the old criterion.
    static let slsVerdictEnabled = DebugSwitch.fullscreenSlsVerdict.isEnabled(in: ProcessInfo.processInfo.environment)

    // MARK: - HoverSwitch Diagnostics

    let hoverLogger = Logger(subsystem: "app.neobar.NeoBar", category: "HoverSwitch")
    static let hoverHotZone: CGFloat = 4.0
    static let hoverSwitchDwell: TimeInterval = 0.35   // Switch only after the cursor dwells in the hot zone for >= 350ms; passing through doesn't count
    static let hoverVerboseLogging = false
    /// Reproduction diagnostics for bottom-edge wake / auto-hide (owner 2026-07-16 issue #2 investigation). Off by default; this uses plain print()
    /// rather than Logger/os_log, because the sandbox environment can't read `log show`/`log stream`, and only print() redirected into a file
    /// can be read back directly. AppDelegate already line-buffers stdout (`setvbuf(stdout, nil, _IOLBF, 0)`),
    /// so no extra buffering handling is needed here.
    static let edgeHoverTraceEnabled = DebugSwitch.edgehoverTrace.isEnabled(in: ProcessInfo.processInfo.environment)
    var hoverLastScreenIndex: Int? = nil
    var hoverLastInHotZone: Bool? = nil
    var hoverSwitchTimer: Timer?
    var hoverSwitchTargetScreen: NSScreen? = nil

    /// Taskbar display position: hover screen-switching (dwelling at the bottom edge to move the dock) only takes effect in the "follow mouse" mode.
    /// Units whose screen is assigned by the orchestration layer (③④) never switch screens: every screen has a bar, so there is nothing to move.
    var hoverScreenSwitchingEnabled: Bool {
        switch unitPlacement {
        case .followSettings: return settingsStore.taskbarScreenPlacement.allowsHoverScreenSwitching
        case .fixed: return false
        }
    }

    /// Display UUID of the screen this unit should land on: `.fixed` uses the one given by the orchestration layer; `.followSettings` uses the fixed screen from Settings;
    /// nil in follow-mouse mode.
    var fixedDisplayUUID: String? {
        switch unitPlacement {
        case .fixed(let uuid): return uuid
        case .followSettings: return settingsStore.taskbarScreenPlacement.pinnedSelection?.uuid
        }
    }

    // MARK: - Frame Helpers

    // These two do not scale with the tier and stay as static constants.
    private static let outerMargin: CGFloat = PanelLayoutMetrics.neoBar.outerMargin
    private static let capsuleGap: CGFloat = PanelLayoutMetrics.neoBar.capsuleGap

}
