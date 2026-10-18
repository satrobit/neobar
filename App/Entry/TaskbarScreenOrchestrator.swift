import AppKit
import Combine
import Foundation
import os

/// Multi-display task strip orchestration layer (multi-display routes 3/4, 2026-09-02).
///
/// **One `PanelCoordinator` = a complete task strip set on one display** (strip / backing plate / capsule / drawer / popups / bubble,
/// visibility state machine, edge auto-hide, fullscreen hold). Under routes 1/2 there is exactly one unit, following settings; under 3/4 each connected display gets
/// one `.fixed` unit -- its behavior is the already signed-off "pinned to a display" tier. This type holds only things that **go wrong if duplicated**:
/// the single fullscreen-intent tap, the single set of mouse-move monitors, the single drag controller, the merged badge gate,
/// and the lifecycle of building / tearing down units per display set.
///
/// It caches no screen coordinates (Docs/28: panels moving while the cache doesn't is the common shape of multi-display bugs) --
/// everything is derived afresh from the unit's panel coordinates each time.
@MainActor
final class TaskbarScreenOrchestrator: NSObject, WindowLiftAvoidanceHost {
    struct Unit {
        /// nil = the single unit that follows settings (routes 1/2); otherwise the display UUID this unit is pinned to (routes 3/4).
        let key: String?
        let coordinator: PanelCoordinator
    }

    private(set) var units: [Unit] = []
    let dragController: DragController
    /// Private space host for the always-resident panels: one per process (the two displays can share one space; measured, each panel only shows on its own display).
    let overlaySpaceHost = OverlaySpaceHost.make()

    private let runtime: AppRuntime
    private let drawerStore: DrawerStore
    private let messagingStore: MessagingAppStore
    private let badgeStore: BadgeStore
    private let stripOrderStore: StripOrderStore
    private let drawerOrderStore: DrawerOrderStore
    private let settingsStore: AppSettingsStore
    private let pinnedFolderStore: PinnedFolderStore
    private let folderCoverStore: PinnedFolderCoverStore
    private let shelfStore: ShelfStore
    private let keptAppStore: KeptAppStore
    private let runningApplicationStore: RunningApplicationStore
    private let appMembershipController: AppMembershipController
    private let displayTopologyStore: DisplayTopologyStore
    private let topologySnapshotProvider: @MainActor () -> ScreenTopologySnapshot
    private let seedRetryScheduler: TaskbarPerDisplaySeedController.ScheduleAfter
    private let logger = Logger(subsystem: "app.neobar.NeoBar", category: "taskbar-screens")

    var onAddFolder: () -> Void = {} {
        didSet { units.forEach { $0.coordinator.onAddFolder = onAddFolder } }
    }
    var onRequestTaskbarMenu: ((NSEvent, NSView) -> Void)? {
        didSet { units.forEach { $0.coordinator.onRequestTaskbarMenu = onRequestTaskbarMenu } }
    }

    private var started = false
    private var isSuspended = false
    private var placementSubscription: AnyCancellable?
    private var fullscreenIntentEnabledSubscription: AnyCancellable?
    private var fullscreenIntentMonitor: FullscreenIntentMonitor?
    private var perDisplaySeedController: TaskbarPerDisplaySeedController?

    // MARK: Mouse-move monitors (lifted up from PanelCoordinator, semantics preserved verbatim)
    private var hoverLocalMouseMonitor: Any?
    private var hoverGlobalMouseMonitor: Any?
    private var hoverPollThrottle = HoverPollThrottle(minInterval: 1.0 / 30.0)
    /// Menu tracking depth (submenus nest); 0 = no menu is currently tracking.
    private var menuTrackingDepth = 0
    /// Bottom-edge probing while a menu is open (owner 2026-09-02: after adjusting the slider in the status-bar menu without closing it, moving the mouse to the bottom edge couldn't wake the strip).
    /// The monitor is removed so menus don't feel sticky -- any global event monitor slows delivery in event-tracking mode; whereas
    /// a `.common`-mode Timer doesn't intercept events and keeps firing during menu tracking, so it runs `pollMousePosition` in place of the monitor.
    private var menuTrackingPollTimer: Timer?
    private static let menuHoverSuspensionEnabled = DebugSwitch.menuHoverSuspend.isEnabled(in: ProcessInfo.processInfo.environment)
    /// Monitor on demand + throttling (DOCK_HOVER_MONITOR_LEAN=0 falls back to always-resident + full processing on every event).
    private static let hoverMonitorLeanEnabled = DebugSwitch.hoverMonitorLean.isEnabled(in: ProcessInfo.processInfo.environment)

    init(runtime: AppRuntime,
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
         displayTopologyStore: DisplayTopologyStore,
         topologySnapshotProvider: @escaping @MainActor () -> ScreenTopologySnapshot = {
             DisplayIdentity.topologySnapshot()
         },
         seedRetryScheduler: @escaping TaskbarPerDisplaySeedController.ScheduleAfter = { delay, action in
             let item = DispatchWorkItem(block: action)
             DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
             return item
         }) {
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
        self.topologySnapshotProvider = topologySnapshotProvider
        self.seedRetryScheduler = seedRetryScheduler
        self.dragController = DragController(
            drawerStore: drawerStore,
            messagingStore: messagingStore,
            membershipController: appMembershipController,
            dropZonesProvider: { [weak dragHost] source in dragHost?.dragDropZones(for: source) ?? [] },
            // One carrier panel set per display (`DragController.CarrierSurface`), switched by the display the pointer is on --
            // under "Displays have separate Spaces" a window belongs to only one display, and spanning the union just fails to draw on the other display.
            screensProvider: { NSScreen.screens },
            // When released on the capsule to stash, the icon is sucked in here (the visible frame of the capsule of the unit on the pointer's display).
            stashTargetProvider: { [weak dragHost] in dragHost?.stashTargetFrame }
        )
        super.init()
        dragHost.owner = self
        wireDragController()
    }

    deinit {
        MainActor.assumeIsolated {
            perDisplaySeedController?.cancel()
            removeHoverMouseMonitorsOnly()
        }
        menuTrackingPollTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    /// `DragController` is created before `super.init()` and the closure can't capture self -- use a small proxy to forward.
    @MainActor
    private final class DragHost {
        weak var owner: TaskbarScreenOrchestrator?
        func dragDropZones(for source: DragSource) -> [CGRect] {
            owner?.units.flatMap { $0.coordinator.dragDropZones(for: source) } ?? []
        }
        var stashTargetFrame: CGRect? {
            guard let owner else { return nil }
            return (owner.unitContainingMouse() ?? owner.units.first)?.coordinator.capsuleVisibleFrame
        }
    }
    private let dragHost = DragHost()

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        let seedController = makePerDisplaySeedController()
        perDisplaySeedController = seedController
        let snapshot = seedController.prepareForTopologyChange()
        rebuildUnits(reason: "start", connectedKeys: snapshot.identifiedDisplayUUIDs)
        // Build the carrier panels ahead of time, so the user's first drag doesn't pay that 20ms + a 39ms main-thread stall
        // (rationale and measurements in `DragController.prewarmCarrier`). **Deferred to the next run-loop turn**:
        // launch is one big first-frame transaction, and extra SwiftUI layout must not be stuffed into it.
        DispatchQueue.main.async { [weak dragController] in
            dragController?.prewarmCarrier()
        }
        observeMenuTracking()
        reconcileHoverMouseMonitors()
        reconcileFullscreenIntentMonitor()
        placementSubscription = settingsStore.$taskbarScreenPlacement
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.rebuildUnits(
                    reason: "placement",
                    connectedKeys: self.displayTopologyStore.latestSnapshot.identifiedDisplayUUIDs
                )
                self.reconcileHoverMouseMonitors()
            }
        fullscreenIntentEnabledSubscription = settingsStore.$fullscreenIntentEnabled
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reconcileFullscreenIntentMonitor() }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    /// Permission lost: tear down all units and shared pieces. No symmetric resume (after permission is restored the whole process restarts).
    func suspendAndRelease() {
        guard !isSuspended else { return }
        isSuspended = true
        cancelInteractiveHeightResize()
        setSettingsHeightSessionActive(false)
        // Roll back the uncommitted cross-panel drag transaction first, then tear down the monitors; the resident carrier panels must also be explicitly dismissed.
        dragController.cancelDrag()
        dragController.closeCarrierSurfaces()
        removeHoverMouseMonitors()
        stopMenuTrackingPoll()
        fullscreenIntentMonitor?.stop()
        fullscreenIntentMonitor = nil
        for unit in units {
            unit.coordinator.setFullscreenIntentRouting(enabled: false)
            unit.coordinator.tearDown()
        }
        units = []
        perDisplaySeedController?.cancel()
        perDisplaySeedController = nil
        placementSubscription = nil
        fullscreenIntentEnabledSubscription = nil
        NotificationCenter.default.removeObserver(self)
    }

    func toggleDrawer() {
        (unitContainingMouse() ?? units.first)?.coordinator.toggleDrawer()
    }

    func setTaskbarMenuOpen(_ open: Bool) {
        units.forEach { $0.coordinator.setTaskbarMenuOpen(open) }
    }

    // MARK: - Unit collection

    /// Build / tear down units according to current settings and the display set. If the target key list is unchanged, do nothing (idempotent; may be called from any notification).
    private func rebuildUnits(reason: String, connectedKeys: [String]) {
        guard started, !isSuspended else { return }
        cancelInteractiveHeightResize()
        let desired = TaskbarDisplaySet.desiredUnitKeys(
            placement: settingsStore.taskbarScreenPlacement,
            connectedKeys: connectedKeys
        )
        let current = units.map(\.key)
        guard desired != current else { return }
        let desiredSet = Set(desired.map { $0 ?? "" })
        var survivors: [String?: Unit] = [:]
        for unit in units {
            if desiredSet.contains(unit.key ?? "") {
                survivors[unit.key] = unit
            } else {
                unit.coordinator.setFullscreenIntentRouting(enabled: false)
                unit.coordinator.tearDown()
            }
        }
        units = desired.map { key in survivors[key] ?? makeUnit(key: key) }
        logger.info("units rebuilt reason=\(reason, privacy: .public) count=\(self.units.count, privacy: .public)")
        pushPanelScreensToIntentMonitor()
        reconcileBadgeGate()
    }

    private func makeUnit(key: String?) -> Unit {
        let placement: TaskbarUnitPlacement = key.map { .fixed(displayUUID: $0) } ?? .followSettings
        let coordinator = PanelCoordinator(
            placement: placement,
            dragController: dragController,
            overlaySpaceHost: overlaySpaceHost,
            runtime: runtime,
            drawerStore: drawerStore,
            messagingStore: messagingStore,
            badgeStore: badgeStore,
            stripOrderStore: stripOrderStore,
            drawerOrderStore: drawerOrderStore,
            settingsStore: settingsStore,
            pinnedFolderStore: pinnedFolderStore,
            folderCoverStore: folderCoverStore,
            shelfStore: shelfStore,
            keptAppStore: keptAppStore,
            runningApplicationStore: runningApplicationStore,
            appMembershipController: appMembershipController,
            displayTopologyStore: displayTopologyStore
        )
        coordinator.onAddFolder = onAddFolder
        coordinator.onRequestTaskbarMenu = onRequestTaskbarMenu
        coordinator.onHoverMonitorsNeedReconcile = { [weak self] in self?.reconcileHoverMouseMonitors() }
        coordinator.onPanelScreenChanged = { [weak self] in self?.pushPanelScreensToIntentMonitor() }
        coordinator.onLogicalVisibilityChanged = { [weak self] _ in self?.reconcileBadgeGate() }
        coordinator.onAccessoryWillOpen = { [weak self] unit, kind in
            self?.closeAccessories(exceptFor: unit, opening: kind)
        }
        coordinator.onInteractiveHeightResizeSession = { [weak self, weak coordinator] active in
            guard let self else { return }
            self.heightResizeOrigin = active ? coordinator : nil
            self.units.forEach { $0.coordinator.setInteractiveHeightResizeActive(active) }
        }
        coordinator.start()
        coordinator.setFullscreenIntentRouting(enabled: fullscreenIntentMonitor != nil)
        // A unit created mid-drag (topology change is cancelled first, but a placement change
        // is not) joins the session instead of animating its way through every tick.
        if heightResizeOrigin != nil || settingsHeightSessionActive {
            coordinator.setInteractiveHeightResizeActive(true)
        }
        coordinator.onInteractiveHeightResizeUpdate = { [weak self] in
            self?.units.forEach { $0.coordinator.commitInteractivePanelHeight() }
        }
        return Unit(key: key, coordinator: coordinator)
    }

    // MARK: - Height-drag session

    /// The unit whose grip is being dragged; nil = no drag. Set from the unit's own callback so
    /// a topology change, unit rebuild or suspension can end the drag through that unit (which
    /// pops the grip's cursor) before the units are torn down.
    private weak var heightResizeOrigin: PanelCoordinator?

    private func cancelInteractiveHeightResize() {
        heightResizeOrigin?.cancelInteractiveResize()
        heightResizeOrigin = nil
    }

    /// The status menu's height slider is being dragged (`true`) or released (`false`).
    /// Every unit joins the same transaction as a grip drag — animations off, hover suppressed,
    /// one batched commit per tick — instead of tearing down and relaying out on every point.
    /// The wake inhibitor goes on the unit under the pointer only (the screen showing the
    /// menu): an inhibitor also wakes a hidden bar, and the other screens' bars
    /// still pick up the height through the batched commit without being woken.
    private var settingsHeightSessionActive = false
    private weak var settingsHeightSessionWakeUnit: PanelCoordinator?

    func setSettingsHeightSessionActive(_ active: Bool) {
        guard settingsHeightSessionActive != active else { return }
        if !active { commitSettingsPanelHeight() }
        settingsHeightSessionActive = active
        if active {
            cancelInteractiveHeightResize()
            let wakeUnit = (unitContainingMouse() ?? units.first)?.coordinator
            settingsHeightSessionWakeUnit = wakeUnit
            units.forEach { $0.coordinator.setInteractiveHeightResizeActive(true) }
            wakeUnit?.setAutoHideInhibitor(.interactiveResize, active: true)
        } else {
            settingsHeightSessionWakeUnit?.setAutoHideInhibitor(.interactiveResize, active: false)
            settingsHeightSessionWakeUnit = nil
            units.forEach { $0.coordinator.setInteractiveHeightResizeActive(false) }
        }
    }

    func commitSettingsPanelHeight() {
        guard settingsHeightSessionActive, heightResizeOrigin == nil else { return }
        units.forEach { $0.coordinator.commitInteractivePanelHeight() }
    }

    private func unitContainingMouse() -> Unit? {
        let mouse = NSEvent.mouseLocation
        return units.first { $0.coordinator.currentScreen?.frame.contains(mouse) == true }
    }

    private func unit(forDisplayUUID uuid: String) -> Unit? {
        if let unit = units.first(where: { $0.key == uuid }) { return unit }
        // The single unit of routes 1/2 has a nil key: match by the display it is on right now.
        return units.first { unit in
            unit.coordinator.currentScreen.flatMap { DisplayIdentity.uuidString(for: $0) } == uuid
        }
    }

    @objc private func screenParametersChanged() {
        dragController.cancelDrag()   // Display switch / resolution change -> cancel any in-progress cross-panel drag, so the carrier doesn't stay at old-display coordinates
        cancelInteractiveHeightResize()   // same for a height drag: its start point is in old screen coordinates
        // One ordered snapshot feeds the shared display table, the seed decision and the unit set in
        // turn — never re-read NSScreen in between.
        // With no seed controller the screen handling still runs to completion: the controller owns
        // only the one-shot first-run seed, while rebuilding units, re-homing each unit, pushing panel
        // screen frames and reconciling hover monitors are core multi-display work that must not hang
        // off its lifetime.
        let snapshot: ScreenTopologySnapshot
        if let seedController = perDisplaySeedController {
            snapshot = seedController.prepareForTopologyChange()
        } else {
            snapshot = topologySnapshotProvider()
            displayTopologyStore.apply(snapshot)
        }
        rebuildUnits(reason: "screens", connectedKeys: snapshot.identifiedDisplayUUIDs)
        units.forEach { $0.coordinator.screenParametersChanged() }
        pushPanelScreensToIntentMonitor()
        reconcileHoverMouseMonitors()  // The display count changed: re-evaluate whether the monitors are still needed when switching between single and multiple displays
    }

    private func makePerDisplaySeedController() -> TaskbarPerDisplaySeedController {
        TaskbarPerDisplaySeedController(
            snapshotProvider: topologySnapshotProvider,
            isSeedPending: { [weak settingsStore] in
                settingsStore?.taskbarPerDisplaySeedPending ?? false
            },
            hasStoredPlacementChoice: { [weak settingsStore] in
                settingsStore?.hasStoredTaskbarScreenChoice ?? true
            },
            applySnapshot: { [weak displayTopologyStore] snapshot in
                displayTopologyStore?.apply(snapshot)
            },
            applySeed: { [weak self, weak settingsStore] in
                settingsStore?.applyTaskbarPerDisplaySeed()
                self?.logger.info("seeded allScreensPerDisplay for first multi-display topology")
            },
            consumeWithoutSeeding: { [weak settingsStore] in
                settingsStore?.consumeTaskbarPerDisplaySeedIfPresent()
            },
            onRetrySeeded: { [weak self] snapshot in
                self?.rebuildUnits(
                    reason: "seed-retry",
                    connectedKeys: snapshot.identifiedDisplayUUIDs
                )
            },
            scheduleAfter: seedRetryScheduler
        )
    }

    /// Only one drawer / popup / bubble open at a time: when a unit wants to open one, close the other units'.
    /// Drawers and popups are mutually exclusive (attached panels at the same level); bubbles exclude only bubbles (hover shouldn't dismiss a drawer open on another display).
    private func closeAccessories(exceptFor unit: PanelCoordinator, opening kind: PanelCoordinator.AccessoryKind) {
        for other in units where other.coordinator !== unit {
            switch kind {
            case .drawer, .popup:
                other.coordinator.closeDrawer()
                other.coordinator.closeFolderPopup()
                other.coordinator.dismissWindowTitleTooltip(suppressCurrentUntilExit: true)
            case .tooltip:
                other.coordinator.dismissWindowTitleTooltip(suppressCurrentUntilExit: true)
            }
        }
    }

    /// Badge polling gate: visible as long as any unit is logically visible.
    private func reconcileBadgeGate() {
        badgeStore.setTaskbarVisible(units.contains { $0.coordinator.isLogicallyVisible })
    }

    // MARK: - Maximize-avoidance host

    /// One per resident, visible unit (under routes 3/4 each display avoids independently; if a display's strip is hidden, that display's windows aren't lifted).
    func windowLiftAvoidanceContexts() -> [WindowLiftAvoidanceContext] {
        units.compactMap { $0.coordinator.windowLiftAvoidanceContext() }
    }

    // MARK: - Drag controller wiring (store-level side effects)

    private func wireDragController() {
        // Folder chip drag settles: DockStripView writes the geometry into DragController, and the final mouseUp / polling fallback calls back here from
        // endDrag to run the side effects. Keeps .folder isolated from strip/drawer stash semantics.
        dragController.onFolderDragEnded = { [pinnedFolderStore] path, zone in
            switch zone {
            case .folderZone:
                break
            case .outsideStrip:
                pinnedFolderStore.remove(path)
            case .liveZone:
                pinnedFolderStore.remove(path)
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            }
        }
        // Drawer dragged back to the task strip, exact drop point: on a successful release-and-settle, clear the order layer's tracking of externally staged blocks (boundIDs are already normal members and stay on the task strip).
        dragController.onDrawerToStripCommitted = { [stripOrderStore] _ in
            stripOrderStore.commitExternalBlock()
        }
        // Drawer dragged back to the task strip, abnormal cancel (cancelDrag): roll back the order layer's externally staged blocks (delete boundIDs + clear absentSince + clear staging).
        dragController.onDrawerToStripCancelled = { [stripOrderStore] in
            stripOrderStore.cancelExternalBlock()
        }
        // Drawer icon lands in the task strip (triggered by both the exact drop point and the downgrade path) -> close the drawer (a no-op for units whose drawer is closed).
        dragController.onDrawerToStripCompleted = { [weak self] _ in
            self?.units.forEach { $0.coordinator.closeDrawerAfterAction() }
        }
        dragController.onCapsuleStashWillAdd = { [drawerOrderStore] bundleID in
            drawerOrderStore.moveToFront([bundleID])
        }
        // Cross-display drop (routes 3/4): a card released on another display's task strip -> the window moves to that display (moved only, not raised) / an icon without a window now lives on that display.
        // Carrier panels are one per display and always topmost; after the task strip is pinned into the private space, windows in the desktop space are pressed beneath it whatever their level,
        // so the carrier must be pinned into the same space (reason in `DragController.pinCarrierWindows`).
        dragController.pinCarrierWindows = { [weak self] numbers in
            guard let host = self?.overlaySpaceHost else { return }
            _ = host.pin(windowNumbers: numbers)
        }
        dragController.onCrossStripDrop = { [runtime] payload, displayUUID in
            runtime.handleCrossStripDrop(payload: payload, toDisplayUUID: displayUUID)
        }
    }

    // MARK: - Fullscreen-intent tap (the only one in the process)

    private func reconcileFullscreenIntentMonitor() {
        let enabled = FullscreenIntentDecision.isEnabled(
            settingEnabled: settingsStore.fullscreenIntentEnabled,
            environment: ProcessInfo.processInfo.environment
        )
        guard enabled, !isSuspended else {
            fullscreenIntentMonitor?.stop()
            fullscreenIntentMonitor = nil
            units.forEach { $0.coordinator.setFullscreenIntentRouting(enabled: false) }
            return
        }
        guard fullscreenIntentMonitor == nil else { return }
        let monitor = FullscreenIntentMonitor(
            // Broadcast: each unit decides whether to act with its own screenCGFrame guard -- when one display enters fullscreen, only that display's strip hides.
            onIntent: { [weak self] request in
                self?.units.forEach { $0.coordinator.beginFullscreenIntent(request) }
            },
            // Space switches happen per display: the tap has already located that display, so route to its unit; if not found, fall back to the display the mouse is on.
            onSpaceSwitchIntent: { [weak self] direction, displayUUID in
                guard let self else { return }
                let target = self.unit(forDisplayUUID: displayUUID) ?? self.unitContainingMouse() ?? self.units.first
                target?.coordinator.beginFullscreenSpaceIntent(direction: direction)
            },
            onContextChange: { [weak self] change in
                self?.units.forEach { $0.coordinator.handleFullscreenIntentContextChange(change) }
            }
        )
        fullscreenIntentMonitor = monitor
        monitor.updatePanelScreens(currentPanelScreenCGFrames)
        monitor.start()
        units.forEach { $0.coordinator.setFullscreenIntentRouting(enabled: true) }
    }

    /// **Do not change back to `Set<CGRect>`**: `CGRect`'s `Hashable` conformance is macOS 15+; the compiler only warns,
    /// and on macOS 14 and earlier there is no witness table at runtime, so the first insert segfaults -- 0.11.0-0.11.2
    /// crashing at launch on those systems was exactly this line (`AGENTS.md` iron rule). Displays are single-digit in number, so array dedupe is enough.
    private var currentPanelScreenCGFrames: [CGRect] {
        units.compactMap { $0.coordinator.currentPanelScreenCGFrame() }
            .reduce(into: [CGRect]()) { unique, frame in
                if !unique.contains(frame) { unique.append(frame) }
            }
    }

    private func pushPanelScreensToIntentMonitor() {
        fullscreenIntentMonitor?.updatePanelScreens(currentPanelScreenCGFrames)
    }

    // MARK: - Mouse-move monitors (one set per process, forwarded to each unit)

    /// The mouse-move monitor serves only two things: **multi-display hover switching** (no target with a single display; none either when pinned to one display / shown on all displays) and
    /// **edge auto-hide** (no timing target if it's off). When neither holds, don't install it at all -- the resident cost of "entering a callback on every pointer move"
    /// drops to zero; re-evaluated when the display count or settings change (the diagnostic switch DOCK_EDGEHOVER_TRACE=1 forces it resident).
    private var hoverMonitorsNeeded: Bool {
        guard Self.hoverMonitorLeanEnabled else { return true }
        return (NSScreen.screens.count > 1 && settingsStore.taskbarScreenPlacement.allowsHoverScreenSwitching)
            || settingsStore.edgeAutoHideEnabled
            || PanelCoordinator.edgeHoverTraceEnabled
    }

    private func reconcileHoverMouseMonitors() {
        guard started, !isSuspended else { return }
        guard menuTrackingDepth == 0 else { return }   // During menu tracking the suspend logic takes over
        if hoverMonitorsNeeded {
            installHoverMouseMonitors()
            pollAllUnits()
        } else {
            removeHoverMouseMonitors()
        }
    }

    /// Does two things uniformly whenever any NeoBar menu is open. Uses `NSMenu`'s app-level tracking notifications, one place covering all menus
    /// (icon / drawer / folder / capsule / status bar); submenus nest the notifications, so count by depth.
    ///
    /// 1. **Attach the "don't auto-hide" safeguard**. Menus pop up above the task strip, and as soon as the mouse reaches up for a menu item, edge auto-hide
    ///    counts it as leaving the strip, so the 0.2s idle timer runs and shrinks the strip; yet the menu hangs off the icon's view on the strip,
    ///    so when the strip goes the menu goes with it (issue #42: after right-clicking an icon, moving the mouse to "New Window" made the menu vanish, unclickable).
    ///    The safeguard itself existed since 2026-08-04, but back then it was wired only to the status-bar menu (`StatusMenuController`);
    ///    the icon menu was always left out.
    /// 2. **Remove the mouse-move monitor** (reported by the owner 2026-08-04: "swinging back and forth between two items in the menu feels sticky").
    ///    `addGlobalMonitorForEvents` is an event interceptor at the system level; when NeoBar pops up its own menu the main loop switches to event-tracking mode,
    ///    the interceptor's handler isn't serviced in that mode, and every mouse-move event waits until timeout before delivery -- menu highlight lags half a beat.
    ///
    /// **`DOCK_MENU_HOVER_SUSPEND=0` turns off only item 2** -- it is the kill switch for that feel optimization. The notification registration itself
    /// must happen unconditionally, otherwise turning off the feel optimization would also turn off the #42 safeguard.
    private func observeMenuTracking() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(menuTrackingDidBegin),
            name: NSMenu.didBeginTrackingNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(menuTrackingDidEnd),
            name: NSMenu.didEndTrackingNotification,
            object: nil
        )
    }

    @objc private func menuTrackingDidBegin() {
        menuTrackingDepth += 1
        guard menuTrackingDepth == 1 else { return }
        setTaskbarMenuOpen(true)
        guard Self.menuHoverSuspensionEnabled else { return }
        removeHoverMouseMonitorsOnly()
        startMenuTrackingPollIfNeeded()
    }

    @objc private func menuTrackingDidEnd() {
        menuTrackingDepth = max(0, menuTrackingDepth - 1)
        guard menuTrackingDepth == 0 else { return }
        setTaskbarMenuOpen(false)
        stopMenuTrackingPoll()
        // Put it back (if still needed) and immediately re-evaluate -- during the time it was removed the mouse may have crossed displays or left the hot zone.
        reconcileHoverMouseMonitors()
    }

    /// While a menu is open, use a `.common`-mode timer in place of the monitor for bottom-edge probing (<=30Hz, same rate as the monitor throttle).
    /// Runs only when the monitor should have been there anyway; stops as soon as the menu closes, and the monitor is reinstalled.
    private func startMenuTrackingPollIfNeeded() {
        guard menuTrackingPollTimer == nil, started, !isSuspended, hoverMonitorsNeeded else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollAllUnits() }
        }
        RunLoop.main.add(timer, forMode: .common)
        menuTrackingPollTimer = timer
    }

    private func stopMenuTrackingPoll() {
        menuTrackingPollTimer?.invalidate()
        menuTrackingPollTimer = nil
    }

    private func installHoverMouseMonitors() {
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        // The monitor callback is delivered on the installing thread (main thread); assumeIsolated saves one Task allocation per event.
        if hoverLocalMouseMonitor == nil {
            hoverLocalMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
                MainActor.assumeIsolated { self?.hoverPollEventArrived() }
                return event
            }
        }
        if hoverGlobalMouseMonitor == nil {
            hoverGlobalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] _ in
                MainActor.assumeIsolated { self?.hoverPollEventArrived() }
            }
        }
    }

    /// Every mouse-move event comes in here (up to hundreds of Hz while moving). Throttled to <=30Hz: hover switching needs a 350ms dwell,
    /// edge wake is insensitive to 33ms; the last position where the pointer stops within the window is re-evaluated by the trailing tail, so hot-zone entry/exit isn't lost.
    private func hoverPollEventArrived() {
        guard Self.hoverMonitorLeanEnabled else {
            // Old behavior as is: every event hops through one main-thread Task and is then fully processed.
            Task { @MainActor [weak self] in self?.pollAllUnits() }
            return
        }
        switch hoverPollThrottle.eventArrived(now: CACurrentMediaTime()) {
        case .run:
            pollAllUnits()
        case .scheduleTrailing(let after):
            DispatchQueue.main.asyncAfter(deadline: .now() + after) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.hoverPollThrottle.trailingFired(now: CACurrentMediaTime())
                    self.pollAllUnits()
                }
            }
        case .drop:
            break
        }
    }

    private func pollAllUnits() {
        units.forEach { $0.coordinator.pollMousePosition() }
    }

    /// Removes only the monitor and **does not touch** the wake / display-switch state -- those are handled by `removeHoverMouseMonitors` on real teardown.
    /// If `cancelEdgeWake()` were done too during the second or two the menu is open, opening the status-bar menu while hidden
    /// would incidentally cancel a bottom-edge wake that is being armed, which would be an extra behavior change.
    private func removeHoverMouseMonitorsOnly() {
        if let monitor = hoverLocalMouseMonitor {
            NSEvent.removeMonitor(monitor)
            hoverLocalMouseMonitor = nil
        }
        if let monitor = hoverGlobalMouseMonitor {
            NSEvent.removeMonitor(monitor)
            hoverGlobalMouseMonitor = nil
        }
    }

    private func removeHoverMouseMonitors() {
        removeHoverMouseMonitorsOnly()
        hoverPollThrottle.reset()
        for unit in units {
            unit.coordinator.cancelHoverSwitch()
            unit.coordinator.cancelEdgeWake()
        }
    }
}
