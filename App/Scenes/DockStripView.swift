import AppKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers

struct DockStripView: View {
    @Environment(\.isPanelHeightResizing) var isPanelHeightResizing
    @EnvironmentObject var runtime: AppRuntime
    @EnvironmentObject var drawerStore: DrawerStore
    @EnvironmentObject var messagingStore: MessagingAppStore
    @EnvironmentObject var badgeStore: BadgeStore
    @EnvironmentObject var stripOrderStore: StripOrderStore
    @EnvironmentObject var pinnedFolderStore: PinnedFolderStore
    @EnvironmentObject var folderCoverStore: PinnedFolderCoverStore
    @EnvironmentObject var shelfStore: ShelfStore
    @ObservedObject var trashStore = TrashStateStore.shared
    @EnvironmentObject var settingsStore: AppSettingsStore
    @EnvironmentObject var displayTopologyStore: DisplayTopologyStore

    /// Whether this taskbar's backing is native Liquid Glass. Fixed once by `PanelCoordinator` when the panel is built
    /// (true only if the backdrop window was built successfully), **passed in explicitly with no default value**: like `scale` / `hoverStyle`,
    /// forgetting to pass it is a compile error. Do not go back to reading a global static — SwiftUI cannot observe it, and after the panel is torn down it would read a stale value.
    let usesLiquidGlass: Bool
    /// This taskbar's surface identity in `DragController` (under multi-display ③④ there is one per display with identical content, see
    /// `DragController.activeStripSurfaceID`). **Passed in explicitly, no default value**: forgetting it means both write the drop target back at the same time.
    let stripSurfaceID: String
    /// The display this taskbar is on (pinned units for ③④ pass the display UUID; following units for ①② pass nil). Under multi-display ④ only the window cards belonging to
    /// this display are drawn. **Passed in explicitly, no default value**: forgetting it means every display draws all windows, and ④ silently degrades into ③.
    /// Switching ③↔④ does not rebuild units (the key list is the same), so whether to filter depends on `settingsStore.taskbarScreenPlacement`.
    let displayUUID: String?
    /// This unit's open-popup look for folder chips. A long-lived root view does not see
    /// environment changes, so it is observed here; no default.
    @ObservedObject var folderPopupPresence: FolderPopupPresence

    /// Whether this taskbar is the active surface of the current drag. When nobody has claimed it (a drawer drag has not been promoted yet) everyone may move — whichever bar's frame contains the pointer gets promoted and claims it.
    var ownsActiveDrag: Bool {
        guard let active = dragController.activeStripSurfaceID else { return true }
        return active == stripSurfaceID
    }

    /// Panel geometry and scale factor derived from the current size tier. **Do not write raw size numbers inside the bar** — every value that scales
    /// with the taskbar is multiplied by `dockScale`; hairlines (separator width, strokes) stay at 1pt and do not scale.
    private var metrics: PanelLayoutMetrics { settingsStore.dockPanelHeight.metrics }
    var dockScale: CGFloat { settingsStore.dockPanelHeight.scale }
    /// Taskbar corner radius. **The same value for glass and frosted-glass states** — geometry has a single source, `DockPanelHeight.metrics` /
    /// `DockShape`, and changing the backing material does not change dimensions (otherwise height scaling breaks; `scale` is defined
    /// as `panelHeight / 54`).
    private var taskbarCornerRadius: CGFloat { Style.cornerRadius * dockScale }
    /// Hover effect tier. Every chip in the bar receives it explicitly (like `dockScale`, forgetting it is a compile error);
    /// the drawer panel and the drawer entry capsule are intentionally unaffected by it (owner 2026-08-02).
    var hoverStyle: HoverStyle { settingsStore.hoverStyle }
    @EnvironmentObject var keptAppStore: KeptAppStore
    @EnvironmentObject var runningApplicationStore: RunningApplicationStore
    @EnvironmentObject var appMembershipController: AppMembershipController

    /// The two sets of light / dark visual values (see `DockThemeTokens`). The dark column is frozen historical values; to tune the look, only touch the light column.
    @Environment(\.colorScheme) private var colorScheme
    private var theme: DockThemeTokens { .resolved(for: colorScheme) }

    /// Folder chip click → popup toggle (path + chip visible rect · screen coordinates). Injected by PanelCoordinator.
    var onFolderPopupToggle: (String, CGRect, FolderPopupOrigin) -> Void = { _, _, _ in }
    /// A folder chip whose popup is open starts to drag: the popup closes at once, so the chip
    /// and its carrier go back to the cover before the carrier is drawn.
    var onFolderDragWillBegin: () -> Void = {}
    /// Shelf cell click → shelf popup toggle (chip visible rect · screen coordinates). Injected by PanelCoordinator.
    var onShelfPopupToggle: (CGRect) -> Void = { _ in }
    /// Trash click → Trash popup toggle (chip visible rect · screen coordinates). Injected by PanelCoordinator.
    var onTrashPopupToggle: (CGRect) -> Void = { _ in }
    /// Unified entry for "Add Folder…" (NSOpenPanel is managed by AppDelegate).
    var onAddFolder: () -> Void = {}
    /// After an external file hits a pinned-folder chip, bubbled up to the composition layer to perform the move in the background.
    var onMoveExternalFiles: ([URL], String) -> Void = { _, _ in }
    /// The **only** exit for the hover name bubble (the whole bar has just this one sender, see `bubbleRequest`).
    /// PanelCoordinator is responsible for presenting and tearing down that separate panel.
    var onWindowTitleTooltipEvent: (WindowTitleTooltipEvent) -> Void = { _ in }
    /// Right-click the taskbar backing → pop up the NeoBar menu (`StatusMenuController` owns that menu).
    var onRequestTaskbarMenu: (NSEvent, NSView) -> Void = { _, _ in }
    /// Drag-to-resize on the bar's grip zones (the divider gaps; the end insets only when the
    /// bar has no divider — `StripContextMenuZone.gripClaims`). `PanelCoordinator` injects both; the defaults are the
    /// correct omission for a strip with no panel behind it (the drag-carrier snapshot).
    var onInteractiveResize: (StripResizeGripEvent) -> Void = { _ in }
    var resizeGripController: StripResizeGripController? = nil
    /// In the SwiftUI update round where a label grows or shrinks, notify the panel to start its follow window, attaching the **starting width** of every label box that starts moving
    /// (`[chipID: old label box width]`, pt); after that the live width of each frame is reported by `onLabelBoxWidthTick`, from which the panel computes the total content width
    /// (`PanelCoordinator.beginLabelWidthFollow(starting:)`). The default empty implementation has the correct omission semantics: a bar not attached to a panel
    /// (the drag carrier snapshot) has no backing to follow.
    var onLabelWidthChange: ([String: CGFloat]) -> Void = { _ in }
    /// The live width of the label box every frame (reported by `LabelBoxWidthDriver` via an environment value), forwarded to the panel to set the frame frame by frame.
    var onLabelBoxWidthTick: (String, CGFloat) -> Void = { _, _ in }
    /// The app make-way gap appeared or went away: the content width changed while the panel
    /// still has the old one, so the panel must re-measure (an app drag grows and re-centres the
    /// bar, like the native Dock). No default — omitted, the gap would widen the content inside
    /// a panel that never moves.
    let onAppGapPresenceChange: () -> Void
    /// Cross-panel drag authority (drag a card into the drawer, route C): drag start → beginDrag; read draggingItem to hide the in-place card,
    /// read isOverDropZone to stop in-bar reordering when entering the drop zone. The carrier panel / monitor / wrap-up all live inside it, and this view does not touch them.
    @EnvironmentObject var dragController: DragController

    /// All reported geometry — chip / hover / folder / messaging frames, shelf, trash, the content
    /// area's screen rect — in one **reference box**. Writing it never re-evaluates the body; the
    /// accessors below keep every read site unchanged. Rationale on `StripFrameBox`.
    @State var frames = StripFrameBox()
    /// Live chip frames by id in the `"strip"` space (on-screen positions after the scroll offset), collected via
    /// preference — feeds the grab offset at drag start and the full-frame landing hit-test.
    /// `.background` GeometryReader (not overlay) so it never steals chip clicks.
    var chipFrames: [String: CGRect] { frames.chipFrames }
    /// Per-chip pulse count triggered by gesture preview (+1 when a heavy click / middle click activates a Finder window, giving a ~200ms reverse lookup an instant "got clicked").
    @State var chipPulseNonces: [String: Int] = [:]

    /// Folder chip frames (popup anchor + pin drop routing for external drags). **A separate dictionary, never mixed into chipFrames** —
    /// that is the input for live window-area drag reordering and drawer-drag-back drops; mixing it in would make window drags hit the folder area and the drop a no-op (review P1).
    var folderChipFrames: [String: CGRect] { frames.folderChipFrames }

    /// Messaging-area chip frames (bundleID → frame in the "strip" space). **A separate dictionary, never mixed into chipFrames, for the same reason as folder chips** —
    /// it feeds messaging-area reorder hit-testing + the "messaging area extent" release decision for drawer drag-outs.
    var messagingChipFrames: [String: CGRect] { frames.messagingChipFrames }
    /// Which messaging-area icon the carrier is currently drawing (de-duplicates image swaps on the release-to-messaging-area path). See `syncReleasedMessagingCarrier`.
    @State private var carriedMessagingChipID: String?
    // The `stripSlotCollapsed` seen by the previous body pass lives in `frames.renderedCollapsed` (updated one pass later in `.onChange`).
    // If the two differ in body, this `layoutKeys` change is the slot collapsing / reopening, and the in-bar animation must follow **the same curve and the same
    // duration** as the panel window animation — a spring (0.28s) layered on AppKit easeInEaseOut (0.22s) makes icons drift ahead of and behind the backing, which is the owner's
    // "not natively silky" moment in the 2026-09-03 screen recording.
    /// The label table rendered in the previous pass: used to compute how much this label change altered the total content width (counting only cards that actually draw a title, form `.multi`).
    @State private var renderedLabelTitles: [String: String] = [:]

    /// Shelf cell frame ("strip" space). **Reported separately, not stuffed into folderChipFrames** (review: that dictionary is exclusive to
    /// folder chips and also feeds folder reorder hit-testing, so no sentinel may be mixed in). Feeds the shelf popup anchor + drop routing.
    var shelfFrame: CGRect { frames.shelfFrame }
    var trashFrame: CGRect { frames.trashFrame }

    /// Live drop target of an external file drag (for hover highlight; nil = no external drag hovering).
    @State var externalDropTarget: StripDropRouting.Target?

    /// The yield gap while dragging an app from Finder into the bar (nil = no yielding). The projection layer inserts an `.externalDropGhost` per it.
    /// **Write only when the anchor really changed** (the gate in `updateExternalDropGhost`) — any change recomputes the whole bar.
    @State var externalDropGhost: StripDropGhost?

    /// Fallback cleanup of the gap during landing: after `performDrop` the gap must stay until the real icon enters the projection (otherwise you would see the
    /// "gap closes → icon pops out" flash); this Timer guarantees it never lingers on any abnormal path.
    @State var externalDropGhostTimeout: Timer?

    /// The bar width frozen during an external-drag hover (nil = not hovering, follows natural width).
    ///
    /// **This is a break point in a closed loop, not an optimization** (measured 2026-09-08): the bar is horizontally centered
    /// (`PanelGeometry.dockTargetFrame`), and as soon as the yield gap is inserted the content grows one card wider → panel relayout →
    /// the whole bar re-centers → the drop zone moves out from under the **stationary** cursor → `dropExited` → the gap and highlight are cleared →
    /// content narrows → centering returns → `dropEntered` → insert again. Measured 77 rounds of in/out in one drag, period ≈33ms,
    /// which shows up as the plus sign, the bar edge, and the gap all flickering together. Freeze the width → `fittingSize` unchanged → no relayout →
    /// the drop zone does not move → the loop breaks. The width of the card the gap yields is absorbed by content overflow (clipped by the `ScrollView`),
    /// the same long-standing approach as "window cards overflow instead of changing the panel width during promotion".
    ///
    /// Not frozen for an app the landing surely adds (`appDropMayWidenOnHover`): the bar grows and
    /// re-centres like the native Dock. That cannot reopen the loop — the insertion index is "between
    /// which two adjacent card centres the pointer sits", and the gap pushes everything left of it
    /// left and everything right of it right, so a still pointer stays between the same pair; the
    /// bar only grows while hovering, so it never slides out from under it.
    @State var frozenStripWidth: CGFloat?

    /// The "drag-end watchdog" + "lighting gate" for the external-drag highlight. SwiftUI file drop has two abnormal endings:
    /// ① the drag gives no performDrop/dropExited wrap-up callback after the last dropUpdated → the highlight is left behind on .pin;
    /// ② ~330ms after a successful drop an orphan dropUpdated is re-sent and relights the highlight.
    /// Gate: the highlight can only be lit by dropEntered (hoverActive); orphan dropUpdated after settling/leaving is always ignored (cures ② flash-back).
    /// Watchdog: a cancellable .common Timer; if the drag hover stops updating and times out, the leftover highlight is cleared (cures ① permanent white edge); the generation prevents an old timer from clearing by mistake.
    /// Logic: see externalDropHoverBegan/Moved/Ended + setExternalDropTarget.
    @State var externalDropWatchdog: Timer?
    @State var externalDropGeneration = 0
    @State var externalDropHoverActive = false

    /// The frame of the taskbar content area ("strip" space) in the screen coordinate system (bottom-left). Used by drawer-drag-back-to-taskbar precise landing to map the
    /// global mouse position back to the "strip" space to hit-test cards, and to decide entering/leaving the taskbar area (hysteresis). Attached to the same view as the "strip" namespace.
    var stripRootScreenRect: CGRect { frames.stripRootScreenRect }

    /// Hover hit frames (`StripEntry.id` → frame in the "strip" space). **Yet another separate dictionary**, for the same reason as the three above:
    /// each has its own purpose (reorder / popup anchor / release decision), and none can substitute for another. This one is
    /// the sole basis for "who the pointer is on", so **cards from all four zones are collected into it**, reported in one place by `stripEntryView`.
    var stripHoverFrames: [String: CGRect] { frames.stripHoverFrames }

    /// Which card the pointer is currently over. **The single source of hover truth for the whole bar** — hover visuals and the name bubble both read it.
    /// Each card no longer attaches its own `.onHover`; the cause and measurements are in `StripHoverResolution`.
    @State var hoveredEntryID: String?
    /// The hovered card's frame in screen coordinates — the bubble's anchor, and the **only**
    /// rendering input derived from the reported geometry. Written by `refreshHoveredEntry` only
    /// when the hovered card's screen frame really moved, so a resting pointer on a card that is
    /// making way re-anchors the bubble, while geometry churn under no hover re-evaluates nothing.
    @State var hoveredAnchor: CGRect?

    /// The last pointer position (screen coordinates). **Deliberately kept in a reference box rather than as an `@State` value**:
    /// writing `@State` on every pointer move would recompute the whole body at the pointer's frequency, while the only moment that truly needs a recompute
    /// is when "the owner changed" — and what gets written at that moment is `hoveredEntryID` above.
    @State var pointerBox = PointerBox()

    /// The chip currently holding the bubble panel. Used only to report the correct id when dismissing the bubble (`.exit` takes effect only if it matches).
    @State private var bubbleOwnerID: String?

    /// Records the IDs of pinned-area elements that have already played their entrance animation (avoids replaying, and supports animating newly added elements).
    @State private var animatedEntryIDs: Set<String> = []

    /// Cards an app drop from Finder just added; they grow in (`DroppedAppLandingGrow`) instead of
    /// taking the strip's usual transition. Written in the same main-thread turn that clears the gap,
    /// so the card's first render already carries the mark; `markLandingEntries` removes it.
    @State var landingEntryIDs: Set<String> = []

    var body: some View {
        let projectionStart = HoverTrace.now()
        let projection = makeProjection()
        let _ = HoverTrace.span("makeProjection", since: projectionStart)
        // "How many times one click recomputed the whole bar" — `DockStripView` subscribes to the whole `AppRuntime`,
        // and any `@Published` change knocks over the whole bar. Off by default; only logged with `DOCK_HOVER_TRACE=1`.
        let _ = HoverTrace.stripBody(items: projection.entries.count, surface: stripSurfaceID)
        return ZStack {
            // On macOS 26 Liquid Glass is taken over by the unified backing; off by default, so older systems and when the switch is off are still the original frosted glass.
            DockPanelBackdrop(theme: theme,
                              cornerRadius: taskbarCornerRadius,
                              usesLiquidGlass: usesLiquidGlass,
                              matchesDockRefraction: true)

            // Glass thickness feel: above the material, below the content. **Off by default**, only on with `DOCK_PANEL_THICKNESS=1`
            // (unaccepted effects are always opt-in, see DockEffectSwitches). In dark mode both layers of insurance draw nothing,
            // the whole layer stays out of the view tree, guaranteeing dark mode is frozen pixel for pixel.
            // Native glass has real edge treatment, so layering this "fake thickness" on top is meaningless; never drawn in glass state.
            if theme.drawsEffectiveThickness && !usesLiquidGlass {
                theme.panelThicknessLayer(cornerRadius: taskbarCornerRadius)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .center, spacing: Style.chipSpacing * dockScale) {
                    ForEach(projection.entries) { entry in
                        chipWithReorder(entry, projection: projection)
                            .transition(landingEntryIDs.contains(entry.id)
                                        ? Self.droppedAppLandingTransition
                                        : Self.entryTransition)
                    }
                }
                .padding(.horizontal, Style.chipContentInset * dockScale)
                .frame(height: metrics.panelHeight)
                // An app gap opening / moving / closing takes the panel's curve too: the bar grows and
                // re-centres with it (`onAppGapPresenceChange`).
                .animation(frames.renderedCollapsed != dragController.stripSlotCollapsed
                               || frames.renderedAppGhost != appDropGhost
                               ? .easeInOut(duration: DrawerAnimation.duration)          // Collapse / reopen: follows the panel
                               : .spring(response: 0.28, dampingFraction: 0.82),         // Yield: the signed-off spring
                           value: projection.layoutKeys)
                // The width animation for a label growing or shrinking lives on the box of `ChipView.titleLabel` (`LabelBoxWidthDriver` changes
                // the real layout width frame by frame, and neighboring cards reflow accordingly); this layer is only responsible for notifying the panel to start following frame by frame, plus a start probe.
                // Start the panel in the same update round (see `onLabelWidthChange` for the reason). The probe line stays: compare it against the timestamp of the panel side's
                // `relayout`, and the difference is how far apart the content and the backing start (`DOCK_HOVER_TRACE=1`).
                .onChange(of: projection.labelTitleByChipID) { newTitles in
                    HoverTrace.action("labelChange", phase: "swiftui")
                    let titled = Set(projection.layoutKeys.filter { $0.form == .multi }.map(\.id))
                    var starting: [String: CGFloat] = [:]
                    for id in titled {
                        guard let new = newTitles[id], let old = renderedLabelTitles[id], new != old else { continue }
                        let from = ChipPillMetrics.labelWidth(title: old, scale: dockScale)
                        if from != ChipPillMetrics.labelWidth(title: new, scale: dockScale) { starting[id] = from }
                    }
                    renderedLabelTitles = newTitles
                    if !starting.isEmpty { onLabelWidthChange(starting) }
                }
                .onAppear { renderedLabelTitles = projection.labelTitleByChipID }
                .environment(\.labelBoxWidthTick, onLabelBoxWidthTick)
                .environment(\.chipPillUsesGlass, usesLiquidGlass)
            }
            .clipShape(RoundedRectangle(cornerRadius: taskbarCornerRadius, style: .continuous))
            .compatLeadingScrollAnchor()
            .mask(alignment: .center) {
                HStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                        .frame(width: Style.edgeFadeWidth * dockScale)
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: Style.edgeFadeWidth * dockScale)
                }
            }
            .overlay(alignment: .topLeading) {
                WheelScrollInterceptorRepresentable()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // Right-click the taskbar backing to pop up the NeoBar menu.
            //
            // **Must be attached as `.overlay`, not `.background`**: behind a SwiftUI ScrollView is a real
            // `NSScrollView`, which catches hit-testing itself, so a host placed beneath it never receives events
            // (measured: right-clicking the blank space at both ends did nothing). Placing it above is safe because `shouldClaim` claims only
            // "the blank ends + separators" and returns nil for everything else so events pass through; chips / folders / the shelf cell
            // keep their own menus on right-click. The range decision is in the pure `StripContextMenuZone` (the 8pt
            // gap between chips is deliberately not claimed, see that type for the reason).
            //
            // overlay, like background, does not affect parent view size — the taskbar width is measured via `fittingSize`;
            // never change it to a sibling node in a ZStack, which would widen the bar.
            // Drag-to-resize grip: the right-click host's zones kept clear of the chips
            // (`StripContextMenuZone.gripClaims`), claims only a plain left mouse-down there;
            // same `.overlay` reasoning as the menu host. Mounted beneath it so the menu host
            // stays topmost, though order is moot — each returns `nil` from `hitTest` for the
            // other's event types.
            .overlay(StripResizeGripHost(
                shouldClaim: { resizeGripZoneClaims(atScreen: $0) },
                onEvent: onInteractiveResize,
                controller: resizeGripController
            ))
            .overlay(NativeMenuHost(
                popUpHandler: onRequestTaskbarMenu,
                shouldClaim: { taskbarMenuZoneClaims(atScreen: $0) }
            ))
        }
        // The rim never changes during a drag: every drag-in (drawer icon, app, folder) is answered
        // by the icons making way, and a rim that follows hover state is the surface that flickers.
        .dockPanelRim(
            cornerRadius: taskbarCornerRadius,
            style: theme.panelRimStyle(highlighted: false),
            lineWidth: theme.panelRimLineWidth(highlighted: false),
            usesLiquidGlass: usesLiquidGlass
        )
        // Freeze the bar width during an external-drag hover (see `frozenStripWidth` for the reason). **Must come before the
        // `.coordinateSpace(name: "strip")` below**: so the width of the coordinate-space view stays constant throughout the hover,
        // `chipFrames` and the `onDrop` drop point still share one source, and the attachment layer is untouched.
        // When `nil`, no frame is applied — normally it follows the natural width entirely, with zero impact on non-drag paths.
        .frame(width: frozenStripWidth)
        // After going cross-panel, the dragged card is drawn by DragController's full-screen carrier panel (no longer drawn on the taskbar overlay —
        // the taskbar window is only 92pt tall, and a self-drawn overlay would be clipped and could not float out). Only the in-place hiding that "yields the slot" remains here.
        .coordinateSpace(name: "strip")
        // External file drag-in (system drop destination): **must be attached to the same layer that defines the "strip" coordinateSpace** —
        // the DropDelegate location must share a source with folderChipFrames/shelfFrame; attached after .padding(shadowPadding)
        // the coordinates would be off (settled in review). Routing is the pure function StripDropRouting.route; for the drop target see handleExternalDrop.
        .onDrop(of: [UTType.fileURL], delegate: StripFileDropDelegate(
            // When the shelf cell is turned off, pass nil directly: ShelfFramePreferenceKey.reduce deliberately ignores .zero,
            // so the old frame would not be cleared, and looking at the frame alone a drop at the old position would still be misjudged as staging.
            // Read at routing time, never copied here: the body no longer re-runs when the frames
            // move (`StripFrameBox`), so a value captured now would route a later drop by stale geometry.
            shelfFrame: { [frames, showShelf = settingsStore.showShelf] in showShelf ? frames.shelfFrame : nil },
            trashFrame: { [frames, showTrash = settingsStore.showTrash] in showTrash ? frames.trashFrame : nil },
            folderFrames: { [frames] in frames.folderChipFrames },
            orderedPaths: pinnedFolderStore.folderPaths,
            // Chip spacing scales with the tier, so the "insert at the very front" slack must scale too, otherwise at small tiers it is relatively wider
            // and would eat into the move-into zone on the left half of the first folder.
            headSlack: StripDropRouting.defaultHeadSlack * dockScale,
            openFolderGap: externalDropGhost.flatMap { ghost in
                guard ghost.zone == .folder else { return nil }
                return StripDropRouting.OpenFolderGap(
                    insertIndex: ghost.insertIndex,
                    width: (ChipPillMetrics.cardWidth + Style.chipSpacing) * dockScale)
            },
            onHoverBegan: { externalDropHoverBegan($0) },
            onHoverMoved: { externalDropHoverMoved($0) },
            onHoverEnded: { isLanding in externalDropHoverEnded(isLanding: isLanding) },
            onCommit: { target, urls in handleExternalDrop(target, urls: urls) },
            onCommitApplications: { urls, location in
                handleExternalApplicationDrop(urls, atX: location.x)
            },
            onGhostMoved: { target, bundleID, pinsFolder, location in
                updateExternalDropGhost(target: target, bundleID: bundleID,
                                        pinsFolder: pinsFolder, atX: location.x)
            },
            currentGhostIndex: { externalDropGhost?.insertIndex },
            currentFrozenWidth: { frozenStripWidth },
            currentStripRect: { stripRootScreenRect }
        ))
        // No cursor badge over the Trash, a folder's pin slot or an app drag. **Must be an `.overlay` directly after `.onDrop`**: AppKit
        // gives the drag to the topmost registered view, and `.background` here lands below SwiftUI's.
        .overlay(StripDropBadgeOverlay())
        // Same view as the "strip" namespace → the screen frame is the origin of the "strip" space, used by drawer-drag-back-to-taskbar for coordinate mapping + enter/leave decisions.
        // **When the panel moves itself, the drop anchors must be re-reported too**: all anchors are converted with `stripFrameToScreen` using this rect.
        // On release `teardown` clears `conversion` → the bar width unfreezes → the whole bar re-centers, and the messaging area (at the far left)
        // shifts left as a whole over 0.22s; without this hook the homing flight keeps flying toward the position from **before** the panel moved.
        .background(ScreenRectReader { rect in
            HoverTrace.stripInput("stripRect", surface: stripSurfaceID, changed: rect != frames.stripRootScreenRect)
            guard rect != frames.stripRootScreenRect else { return }
            frames.stripRootScreenRect = rect
            refreshHoveredEntry(frames: stripHoverFrames, origin: rect)
            updateLandingAnchor()
        })
        // **One tracking region for the whole bar**: every pointer move reports the screen coordinates once, and who it lands on is computed by the pure decision
        // `StripHoverResolution`. The old approach of each card attaching its own `.onHover` left gaps and was direction-dependent;
        // see that type's comments for the cause and measurements.
        .background(StripPointerTracker { pointer in
            pointerBox.value = pointer
            refreshHoveredEntry(frames: stripHoverFrames, origin: stripRootScreenRect)
            // Grip-zone hover for the ▲▼ glyph; rides the same ≤60Hz poll, `nil` on leave or while a press is held.
            onInteractiveResize(.hover(pointer.flatMap { resizeGripHoverClaims(atScreen: $0) ? $0 : nil }))
            HoverTrace.pointer(x: pointer?.x ?? -1, chip: hoveredEntryID)
        })
        // Heavy click (trackpad) / middle click (mouse) → content preview: local event monitor → hit reverse lookup (handleGesturePreview).
        .background(GestureMonitorInstaller(onGesture: { handleGesturePreview(atScreen: $0) }))
        // The drop shadow lives in the window's 20pt transparent margin, and the glass state goes through this too — we once tried drawing it on the layer of the backdrop window instead,
        // but that window's frame is exactly equal to the backing, so a shadow drawn outside the window would be clipped away entirely.
        .dockShadow(theme.stripShadow,
                    visible: DockLiquidGlassConfiguration.stripShadowVisible(
                        usesLiquidGlass: usesLiquidGlass,
                        usesSystemVariant: DockGlassPresentation.usesSystemVariant))
        .padding(PanelCoordinator.shadowPadding)
        // Drawer icon dragged onto the taskbar: entering the taskbar area promotes it into a window card, yielding space in real time as a whole block following the cursor (mirrors DrawerView's global-mouse drive).
        // Messaging-area reorder/release is likewise driven by the global mouse — reordering moves the dragged chip, SwiftUI cancels the original gesture,
        // so we cannot rely on the chip's own .onChanged (same lesson as the drawer, owner 2026-06-22 / Codex review P1-4).
        // **`onReceive` rather than `onChange(of: globalLocation)`**: the latter requires that value to be `@Published`,
        // which is exactly the source of "moving the mouse knocks over the whole taskbar" (measured: 46 whole-bar recomputes in a 1.2-second drag).
        // `onReceive` still runs the closure but creates no dependency for this view — it redraws only if the side effects below actually change something.
        .onReceive(dragController.pointerMoves) { _ in
            updateStripPresence()                 // Enter/leave the bar: yield restore / collapse, claim handover — must be decided before the gate
            guard ownsActiveDrag else { return }   // The bar on another display is being dragged: this bar writes nothing back
            updateDrawerToMessagingRelease(projection: projection)
            updateDrawerToStripConvert(projection: projection)
            updateStripBlockReorder(projection: projection)
            updateLiveReorder(projection: projection)
            updateMessagingReorder(messagingIDs: projection.messagingIDs)
            updateFolderReorder()
            syncConvertedCarrier(projection: projection)
            syncReleasedMessagingCarrier(projection: projection)
            updateFolderDragZone()
            updateLandingAnchor()
        }
        // A tap on the icon during the homing flight = a tap on this card (owner 2026-08-19: "tapping it before it lands does nothing").
        // Dispatch by entry, mirroring verbatim the tap of each branch in `stripEntryContent`; use the projection as of **now**, not the one in the payload from drag start.
        .onReceive(dragController.carrierClicks) { payload in
            guard ownsActiveDrag else { return }
            performCarrierClick(payload, projection: freshProjection())
        }

        // At the instant of promotion, the projection held by the closure above is still the **old** one (the app is still in the drawer), so neither the representative card nor the yielding card can be computed.
        // Relying on mouse-driving alone means "cursor stopped at the boundary = double ghost forever". Recompute once when the store changes to fill in that frame.
        .onChange(of: projection.liveOrderIDs) { _ in
            guard ownsActiveDrag else { return }
            syncConvertedCarrier(projection: freshProjection())
        }
        // Same as above, for the messaging-area side: at the instant of release, the projection in hand does not yet contain this chip.
        .onChange(of: projection.messagingIDs) { _ in
            guard ownsActiveDrag else { return }
            syncReleasedMessagingCarrier(projection: freshProjection())
        }
        // Re-decide once when the hover-suppression switch flips: clear the old hover at the instant the drag starts and hides the card; when the landing press-hold ends (the pointer moved)
        // fill the hover in from the current pointer position. **Do not re-decide at the instant "hand is empty"** — that is the source of the
        // growth-by-a-notch as soon as the landing settles (see `refreshHoveredEntry`).
        .onChange(of: dragController.stripSlotCollapsed) { frames.renderedCollapsed = $0 }
        .onChange(of: externalDropGhost) { _ in appDropGhostDidChange() }
        .onChange(of: dragController.hoverGate) { _ in
            refreshHoveredEntry(frames: stripHoverFrames, origin: stripRootScreenRect)
        }
        .onChange(of: isPanelHeightResizing) { _ in
            refreshHoveredEntry(frames: stripHoverFrames, origin: stripRootScreenRect)
        }
        // A messaging chip's app disappearing from the messaging area during a drag (quit / external unmark / snapshot lost) → cancel the drag, so the empty slot does not get stuck.
        // The collapse preview (messagingToDrawer) is not misjudged: after conversion the payload source is already .drawer (Codex review P2-5).
        .onChange(of: projection.messagingIDs) { ids in
            if let p = dragController.draggingPayload, p.source == .messaging, !ids.contains(p.bundleID) {
                dragController.cancelDrag()
            }
        }
        // Converge the remembered live order with the current snapshot (drop closed, append
        // new) as a side-effect — never during body eval. The `.onAppear` seed mirrors the old
        // `initial: true` so the very first render's reconcile (empty → current) is a no-op.
        // The **sole** driver of the name bubble. Who the pointer is on, where the anchor is, and what text to write are all derived in one place by `bubbleRequest`,
        // so anchor drift / app name changes / tier changes are all picked up automatically — the old scheme where each card re-issued
        // `.refresh` itself, together with the guard of "who is entitled to hold this panel", is gone:
        // now only one party can send a request, so there is nothing to fight over.
        .onChange(of: bubbleRequest(projection: projection)) { request in
            if let request {
                onWindowTitleTooltipEvent(.update(request))
            } else if let previous = bubbleOwnerID {
                onWindowTitleTooltipEvent(.exit(chipID: previous))
            }
            bubbleOwnerID = request?.chipID
        }
        .onDisappear {
            if let previous = bubbleOwnerID { onWindowTitleTooltipEvent(.exit(chipID: previous)) }
            bubbleOwnerID = nil
        }
        .onChange(of: projection.liveOrderIDs) { _ in reconcileLiveOrder(freshProjection()) }
        .onChange(of: keptAppStore.bundleIDs) { _ in reconcileLiveOrder(freshProjection()) }
        .onChange(of: messagingStore.bundleIDs) { _ in reconcileLiveOrder(freshProjection()) }
        .onAppear { reconcileLiveOrder(projection) }
        // Re-report the drop anchors when card frames change. **Driving by `globalLocation` alone is not enough**: after release the pointer has no more events,
        // while the yield spring is still running and the slot takes another one or two hundred milliseconds to settle. The mid-flight correction of the homing flight relies on this.
        .onPreferenceChange(ChipFramePreferenceKey.self) { frames in
            HoverTrace.stripInput("chipFrames", surface: stripSurfaceID, changed: frames != self.frames.chipFrames)
            self.frames.chipFrames = frames
            updateLandingAnchor()
        }
        // When the bar reorders / changes tier the pointer did not move, but the card under it changed — re-decide in the same place.
        .onPreferenceChange(StripHoverFramePreferenceKey.self) { frames in
            HoverTrace.stripInput("hoverFrames", surface: stripSurfaceID, changed: frames != self.frames.stripHoverFrames)
            self.frames.stripHoverFrames = frames
            refreshHoveredEntry(frames: frames, origin: stripRootScreenRect)
        }
        // The frames of these two are likewise an input source for the drop anchors (`.folder` / `.messaging` payloads each take one),
        // so changes must be reported back — same reason as `ChipFramePreferenceKey` above.
        .onPreferenceChange(FolderChipFramePreferenceKey.self) { frames in
            HoverTrace.stripInput("folderFrames", surface: stripSurfaceID, changed: frames != self.frames.folderChipFrames)
            self.frames.folderChipFrames = frames
            updateLandingAnchor()
        }
        .onPreferenceChange(MessagingChipFramePreferenceKey.self) { frames in
            HoverTrace.stripInput("messagingFrames", surface: stripSurfaceID, changed: frames != self.frames.messagingChipFrames)
            self.frames.messagingChipFrames = frames
            updateLandingAnchor()
        }
        .onPreferenceChange(ShelfFramePreferenceKey.self) {
            HoverTrace.stripInput("shelfFrame", surface: stripSurfaceID, changed: $0 != frames.shelfFrame)
            frames.shelfFrame = $0
        }
        .onPreferenceChange(TrashFramePreferenceKey.self) {
            HoverTrace.stripInput("trashFrame", surface: stripSurfaceID, changed: $0 != frames.trashFrame)
            frames.trashFrame = $0
        }
        .onChange(of: pinnedFolderStore.folderPaths) { currentPaths in
            let validIDs = Set(["shelf", "trash"] + currentPaths.map { "folder-\($0)" })
            animatedEntryIDs.formIntersection(validIDs)
        }
        // Toggling the shelf cell changes the drop geometry of the whole pinned area: collapse any in-progress external-drag hover immediately, leaving no highlight.
        // The entrance animation removes only the id "shelf" — clearing the whole set would make all folder chips replay their entrance together when it is re-checked.
        .onChange(of: settingsStore.showShelf) { visible in
            if !visible { animatedEntryIDs.remove("shelf") }
            externalDropHoverEnded(isLanding: false)
        }
        .onChange(of: settingsStore.showTrash) { visible in
            if !visible { animatedEntryIDs.remove("trash") }
            externalDropHoverEnded(isLanding: false)
        }
        // No .frame(maxWidth: .infinity) here — lets NSHostingView.fittingSize reflect
        // the natural content width so AppDelegate can read it for panel sizing.
    }

    /// The pinned-folder chip path being dragged (nil = none). While dragging, the in-place chip is hidden into an empty slot, and the copy is drawn by the carrier panel.
    private var draggingFolderPath: String? {
        guard ownsActiveDrag else { return nil }
        if let p = dragController.hiddenSlotPayload, p.source == .folder { return p.id }
        return nil
    }

    /// In-area folder reorder: hit the full frame of another folder chip, and land by left/right half of the drop point (mirrors the live-area reorderTarget,
    /// hit-test only consults folderChipFrames — never chipFrames).
    private func folderReorderTarget(at point: CGPoint, dragging path: String) {
        let draggedID = "folder-" + path
        guard let hit = folderChipFrames.first(where: { kv in
            kv.key != draggedID && kv.value.contains(point)
        }) else { return }
        let targetPath = String(hit.key.dropFirst("folder-".count))
        pinnedFolderStore.reorder(draggedPath: path, relativeTo: targetPath,
                                  after: point.x > hit.value.midX)
    }

    /// Left boundary of the pinned-folder area ("strip" local coordinates): the left edge of the leftmost folder chip.
    /// The dragged chip's own position is unaffected by hiding (opacity does not change layout), so its frame is reported as usual and need not be excluded;
    /// once the placeholder collapses after dragging outside the bar its frame disappears; for the boundary then see `FolderChipDropZone.zoneMinX`.
    ///
    /// nil = the boundary cannot be computed (first frame not yet measured). **Do not treat nil as 0 or as "no pinned area"**: when dragging a folder
    /// the pinned area necessarily exists, a missing boundary only means it has not been measured yet, and if it were judged as the window area then releasing in place would wrongly delete the pin and open Finder.
    /// When the caller meets nil it simply does not install the geometry.
    private var folderZoneMinX: CGFloat? {
        FolderChipDropZone.zoneMinX(
            folderMinX: folderChipFrames.values.map(\.minX).min(),
            draggedSlotCollapsed: ownsActiveDrag && dragController.stripSlotCollapsed,
            trashMinX: settingsStore.showTrash && trashFrame != .zero ? trashFrame.minX : nil,
            stripWidth: stripRootScreenRect.width)
    }

    /// Real-time drop-target classification during a folder chip drag, written into DragController for the carrier view (across SwiftUI trees) to read for fading out.
    /// The final landing reuses the same screen-coordinate geometry, committed by the mouseUp/polling fallback path of DragController.endDrag.
    private func updateFolderDragZone() {
        guard let p = dragController.draggingPayload, p.source == .folder,
              stripRootScreenRect != .zero,
              // If the boundary was not measured, do not install geometry: DragController falls back to .folderZone for nil geometry (no action in place),
              // which is the only safe default here.
              let folderZoneMinX else {
            dragController.setFolderDragZone(nil)
            dragController.setFolderDropGeometry(nil)
            return
        }
        let geometry = FolderChipDropGeometry(stripScreenRect: stripRootScreenRect,
                                              folderZoneMinX: folderZoneMinX)
        dragController.setFolderDropGeometry(geometry)
        dragController.setFolderDragZone(geometry.classify(screenPoint: dragController.globalLocation))
    }

    /// Converge the remembered live order with the current snapshot (drop closed, append new).
    /// Called on every `liveOrderIDs` change **and** once on appear (the latter mirrors the old
    /// `onChange(of:initial:)` seed that pre-macOS-14 `onChange` doesn't provide).
    func reconcileLiveOrder(_ projection: StripProjection) {
        let current = projection.liveOrderIDs
        let appKeys = projection.appKeyByChipID
        // The diagnostic payload contains the entire appKey dictionary — **do not construct it when logging is off** (same as the isEnabled gate in AppTracker).
        let sample: InventoryOrderProjectionSample? = stripOrderStore.isInventoryLogEnabled
            ? InventoryOrderProjectionSample(
                currentLiveIDs: current,
                absorbedMessagingMainIDs: projection.messaging.compactMap { entry in
                    guard case let .messagingApp(_, mainWindow) = entry else { return nil }
                    return mainWindow?.id
                },
                visibleMessagingBundleIDs: projection.messaging.compactMap { entry in
                    guard case let .messagingApp(bundleID, _) = entry else { return nil }
                    return bundleID
                },
                drawerBundleIDs: drawerStore.bundleIDs,
                appKeyByChipID: appKeys
              )
            : nil
        if HoverTrace.isEnabled, let p = dragController.carriedPayload {
            HoverTrace.orderSync(count: current.count,
                                 carriedID: p.bundleID,
                                 hasCarried: current.contains("app-\(p.bundleID)"))
        }
        stripOrderStore.sync(current: current, appKeyOf: appKeys,
                             headPreferred: Set(messagingStore.bundleIDs),
                             projectionSample: sample)
        // The dragged window disappearing during a drag → cancel the drag, so the empty slot does not get stuck. (The no-callback-on-release case is covered by DragController's polling fallback.)
        if let p = dragController.draggingPayload, p.source == .strip, !current.contains(p.id) {
            dragController.cancelDrag()
        }
    }

    /// Live-zone reorder during a drag: find the chip whose **full frame** the finger is over
    /// (excluding the dragged chip itself), and place the dragged chip on the half the finger is
    /// in. Drives the existing `stripLayoutKeys` spring so the others slide aside as the gap moves.
    /// Full-frame hit (not just x): as the finger lifts toward the capsule/drawer, y has already left the in-bar row, contains does not hit → the order is not changed by mistake (Codex second review).
    private func reorderTarget(at point: CGPoint, dragging id: String, current: [String]) {
        guard let hit = chipFrames.first(where: { kv in
            kv.key != id && kv.value.contains(point)
        }) else { return }
        stripOrderStore.reorder(draggedID: id, relativeTo: hit.key,
                                after: point.x > hit.value.midX, current: current)
    }

    /// The **sole** driver of live-area (window cards / keep placeholders) reordering: the pointer position, not the chip's own gesture
    /// (same rule as the messaging area / drawer / promoted block since 2026-08-19). A drag that is re-grabbed during the homing flight
    /// has no SwiftUI gesture (`DragController.regrabLanding`), and this is the only way for it to reorder.
    /// No reorder while over the drop zone (capsule / drawer) — as the finger lifts toward the capsule, y has already left the in-bar row,
    /// and `contains` would not hit either (both gates from item 4 of the Codex second review are kept).
    private func updateLiveReorder(projection: StripProjection) {
        let dc = dragController
        guard let p = dc.draggingPayload, p.source == .strip, !dc.isOverDropZone,
              let pt = stripPoint(from: dc.globalLocation) else { return }
        reorderTarget(at: pt, dragging: p.id, current: projection.liveOrderIDs)
    }

    /// The sole driver of in-area folder reordering, same as above.
    private func updateFolderReorder() {
        let dc = dragController
        guard let p = dc.draggingPayload, p.source == .folder,
              let pt = stripPoint(from: dc.globalLocation) else { return }
        folderReorderTarget(at: pt, dragging: p.id)
    }

    // MARK: - Drawer icon dragged back to the taskbar · precise drop (running apps, global-mouse driven, mirrors DrawerView)

    /// Drawer drag-out mode (the decision is the pure function `DragConversionPlan.drawerDragOutMode`, covered by unit tests; this only feeds the current facts).
    private func currentDrawerDragOutMode(_ bid: String, projection: StripProjection) -> DrawerDragOutMode {
        DragConversionPlan.drawerDragOutMode(
            bundleID: bid,
            isMessagingMember: messagingStore.contains(bid),
            isInSnapshot: projection.snapshotBundleIDs.contains(bid),
            // Same source as messaging-area visibility (NSWorkspace process projection), **not** the window list — see `drawerDragOutMode` for the reason.
            isRunningProcess: runningApplicationStore.isRunning(bid),
            hasRealWindow: projection.hasRealWindow(bundleID: bid),
            isKept: keptAppStore.contains(bid)
        )
    }

    /// After promotion two **different** things are synced, so two values are computed (see `DragController.convertedChipID` for why they are separate):
    ///
    /// - `rep`: which card the carrier switches to drawing. Must be a real window card; if there is none it stays nil, and the carrier keeps drawing the small drawer icon.
    /// - `chipID`: which card on the bar to hide to yield the slot. **Includes the `.keptApp` placeholder and the app-level fallback card** —
    ///   the `keepPlacement` path materializes exactly these two, and missing them is the "two shadows" the owner reported on 2026-08-18.
    ///
    /// Driven by two places, `onChange(globalLocation)` and `onChange(liveOrderIDs)`. The latter cannot be dropped:
    /// promotion runs in the same closure as this and uses the **previous frame's** projection (the app was still in the drawer then),
    /// and with mouse-driving alone, a cursor stopped at the boundary would double-ghost forever.
    func syncConvertedCarrier(projection: StripProjection) {
        let dc = dragController
        guard dc.isConvertedToStrip, let p = dc.draggingPayload, p.source == .drawer else { return }
        let rep = projection.liveChipIDs(bundleID: p.bundleID).first
            .flatMap { projection.liveOrderIDs.contains($0) ? projection.item(forID: $0) : nil }
        let chipID = projection.liveEntryIDs(bundleID: p.bundleID).first
        // **Judge change by chip id, not by representative card**: the `keepPlacement` path materializes a `.keptApp` placeholder or
        // an app-level fallback card, where the representative card is always nil, so judging by it would be "unchanged" forever — and that path would carry a 0.7x
        // small drawer icon the whole way between 54pt cards, never turning into a card (owner 2026-08-20).
        let changed = dc.convertedChipID != chipID
        dc.setConvertedRepresentative(rep, chipID: chipID)
        guard changed else { return }
        // The carrier switches to drawing the card on the bar (same as an in-bar drag); `chipID` back to nil = rollback, passing nil makes the carrier switch back to the image from drag start.
        let entry = chipID.flatMap { id in projection.entries.first { $0.id == id } }
        dc.setCarrierSnapshot(entry.flatMap { carrierSnapshot(for: $0, projection: projection) },
                              reanchor: true)
    }

    /// What the card tapped during the flight should do: **exactly the same** as being tapped on the bar.
    /// Window card → switch to that window; kept app / messaging app without a main window → raise the main window if running, launch if not running, do nothing while launching.
    /// Folder chips do nothing (the popup is anchored on a still-empty cell, and the icon only arrives half a second later); an entry that cannot be found (no longer on the bar) does nothing.
    private func performCarrierClick(_ payload: DragPayload, projection: StripProjection) {
        guard let entryID = carriedStripEntryID(for: payload),
              let entry = projection.entries.first(where: { $0.id == entryID }) else { return }
        switch entry {
        case let .window(item):
            runtime.toggle(windowID: item.actionWindowID)
        case let .messagingApp(bid, main):
            if let main {
                runtime.toggle(windowID: main.actionWindowID)
            } else {
                launcherTap(bid, hasRealWindow: projection.hasRealWindow(bundleID: bid))
            }
        case let .keptApp(bid):
            launcherTap(bid, hasRealWindow: false)   // The keep placeholder exists only when there is no real window
        case .pinnedFolder, .shelf, .trash, .divider, .externalDropGhost:
            return   // The gap cannot be dragged, so no in-flight payload can point at it
        }
    }

    /// Payload → the entry id of that card on the bar. `nil` = this payload does not belong to the taskbar (drawer icon / folder chip).
    /// **Shared by two places**: a tap in flight must find it to act on it, and a hover in flight must exempt it — both sides must use the same algorithm.
    /// Same as above, but first recognizes the card that "was promoted into the taskbar". The source of a promoted payload is **always `.drawer`**
    /// (`convertDrawerToStrip` deliberately does not flip the source), and the static one returns nil for `.drawer` —
    /// so at the instant of landing the hover exemption fails, the pointer is right on the card that just appeared, and the quiet tier magnifies it to 1.10 on the spot,
    /// which is the form on this path of the "landing jitter" that was cured back then (owner 2026-08-20).
    func carriedStripEntryID(for payload: DragPayload) -> String? {
        if payload.source == .drawer, let cid = dragController.convertedChipID { return cid }
        return Self.stripEntryID(for: payload)
    }

    static func stripEntryID(for payload: DragPayload) -> String? {
        switch payload.source {
        case .strip: return payload.id                       // Window card = chip token; keep placeholder = "app-<bid>"
        case .messaging: return "msg-app-\(payload.bundleID)"
        case .drawer, .folder: return nil
        }
    }

    /// The two tap paths of `LauncherChip` on the bar (`onTap: reopen` / `onLaunch`), plus its own "do nothing while launching" gate.
    private func launcherTap(_ bid: String, hasRealWindow: Bool) {
        guard !runtime.launchingBundleIDs.contains(bid) else { return }
        if runningApplicationStore.isRunning(bid) {
            Self.messagingFallbackTap(bundleID: bid, hasRealWindow: hasRealWindow)
        } else {
            _ = runtime.beginLaunch(bid)
        }
    }

    /// Which cell the floating copy should fly back to on release (screen coordinates). **Written on every cursor update, including writing nil** —
    /// the drawer side also writes its own copy, and the owner tag keeps them from overwriting each other; without writing nil, after a drawer icon is promoted into the taskbar,
    /// the stale anchor left by the drawer would make the icon fly into the already-closed drawer (see `DragController.setLandingAnchor`).
    ///
    /// In-bar reorder / messaging-area reorder can give an accurate drop point: the yielding already happens in real time during the drag, so at the instant of release
    /// this card's frame **is** its final slot. The branch promoted into the taskbar gives nil — release would unfreeze the bar width,
    /// the whole bar re-centers, and the drop point would still drift during the flight.
    private func updateLandingAnchor() {
        guard ownsActiveDrag else { return }
        let anchor: CGRect? = {
            // `carriedPayload`: keep reporting during the flight too, so that `DragController` can correct the deviation once the slot settles.
            guard let p = dragController.carriedPayload, stripRootScreenRect != .zero else { return nil }
            // Already promoted into the taskbar: the anchor is the card on the bar (`convertedChipID` covers both real window cards and
            // the `app-<bid>` placeholder materialized by `keepPlacement`, and both report into `chipFrames`).
            // **Before 2026-08-20 this returned nil, so a drawer drag into the taskbar had no homing flight at all**, and the icon
            // teleported from the cursor to the slot — the reason then was "release would unfreeze the bar width, the whole bar re-centers, and the drop point would drift during the flight",
            // but that drift no longer exists: the bar width is no longer clamped (after drag-out-collapses, the bar width always follows the rendered content).
            // Use `convertedChipID` rather than `isConvertedToStrip`: the latter reads `conversion`,
            // and `conversion` is cleared at `teardown`, so the anchor would be lost during the flight and the deviation could not be corrected.
            if let cid = dragController.convertedChipID {
                return chipFrames[cid].map(stripFrameToScreen)
            }
            switch p.source {
            case .strip:  return chipFrames[p.id].map(stripFrameToScreen)
            case .folder: return folderChipFrames[p.id].map(stripFrameToScreen)
            case .messaging: return messagingChipFrames[p.bundleID].map(stripFrameToScreen)
            case .drawer: return nil   // Not promoted yet → the drop point is in the drawer, and the drawer side writes it itself
            }
        }()
        dragController.setLandingAnchor(anchor, owner: .strip)
    }

    /// Capture a carrier bitmap. **What is drawn is exactly the one from `stripEntryContent`** — rendering the slot and rendering the carrier are
    /// the same function with the same parameters, only passing "hover" and "entrance animation" as false. So "the carrier is the same as the slot"
    /// holds by construction, not by a cross-reference table that has to be maintained by hand (this repo has missed such a table twice:
    /// `ChipView.scale` silently rendered at the mid tier, and the messaging area had no name bubble at all).
    ///
    /// Environment objects must be re-injected here: `ChipView` has five `@EnvironmentObject`s, and missing one crashes.
    private func carrierSnapshot(for entry: StripEntry, projection: StripProjection) -> CarrierSnapshot? {
        ChipSnapshotter.snapshot(
            of: stripEntryContent(entry, projection: projection, hovered: false, entrance: false)
                .environmentObject(runtime)
                .environmentObject(drawerStore)
                .environmentObject(messagingStore)
                .environmentObject(keptAppStore)
                .environmentObject(runningApplicationStore)
                .environmentObject(appMembershipController)
                .environmentObject(settingsStore)
                .environmentObject(badgeStore)
                .environmentObject(pinnedFolderStore)
                .environmentObject(folderCoverStore),
            screenPoint: CGPoint(x: stripRootScreenRect.midX, y: stripRootScreenRect.midY)
        )
    }

    /// The slot's pose **right now**: hover magnification (quiet tier bottom-anchored 1.10, same as folder chips) × press 0.93 (center).
    /// Only if the carrier's first frame is placed per it does it coincide with the slot pixel for pixel — see `DragCarrierGeometry.pickUpPose` for the derivation and numbers.
    /// The hover magnification factor is computed with the **same** `ChipPillMetrics.quietHoverScale(forCardWidth:scale:)` used by the rendered card,
    /// with the card width taken as the measured frame width (so the cap rule for wide-title cards lines up).
    private func pickUpPose(for entry: StripEntry, slot: CGRect?) -> DragCarrierGeometry.PickUpPose {
        let hovered = hoveredEntryID == entry.id
        let height = slot?.height ?? ChipPillMetrics.chipHeight * dockScale
        switch entry {
        case .window, .messagingApp, .keptApp:
            let width = slot?.width ?? ChipPillMetrics.cardWidth * dockScale
            let hoverScale: CGFloat? = hoverStyle.showsQuietHoverFeedback(isHovering: hovered)
                ? ChipPillMetrics.quietHoverScale(forCardWidth: width, scale: dockScale)
                : nil
            return DragCarrierGeometry.pickUpPose(
                chipHeight: height,
                pressedScale: ChipPressSwitches.pressDownEnabled ? ChipPressDecision.pressedScale : nil,
                hoverScale: hoverScale)
        case .pinnedFolder:
            // Folder chips hover like icon cards (quiet tier only) but have no press feedback.
            let width = slot?.width ?? ChipPillMetrics.cardWidth * dockScale
            let hoverScale: CGFloat? = hoverStyle.showsQuietHoverFeedback(isHovering: hovered)
                ? ChipPillMetrics.quietHoverScale(forCardWidth: width, scale: dockScale)
                : nil
            return DragCarrierGeometry.pickUpPose(chipHeight: height, pressedScale: nil,
                                                  hoverScale: hoverScale)
        case .shelf, .trash, .divider, .externalDropGhost:
            return .resting
        }
    }

    /// At the instant of press, prepare a candidate for `DragController` (bitmap + slot frame). If the frame is not measured yet, nothing is prepared,
    /// and drag start falls back to the "press on the card and wait two display frames" path.
    private func prepareDragCandidate(_ entry: StripEntry, id: String, slot: CGRect?,
                                      projection: StripProjection) {
        guard let slot, stripRootScreenRect != .zero else { return }
        dragController.prepareCandidate(payloadID: id,
                                        sourceScreenRect: stripFrameToScreen(slot),
                                        snapshot: carrierSnapshot(for: entry, projection: projection))
    }

    /// Screen coordinates (bottom-left) → point in the "strip" space (top-left, y-down).
    func stripPoint(from global: CGPoint) -> CGPoint? {
        guard stripRootScreenRect != .zero else { return nil }
        return CGPoint(x: global.x - stripRootScreenRect.minX,
                       y: stripRootScreenRect.maxY - global.y)
    }

    /// Whole-block drop for the drawer: **look at x only, and can always give an answer**. For the criterion and rationale (and why the whole-frame `contains` cannot be used)
    /// see the pure type `StripBlockLanding` — in short, the promotion hit box deliberately extends 16pt above the top edge of the bar,
    /// where a whole-frame hit always fails there, so the first drop point degraded 100% to the end.
    func blockTarget(atX x: CGFloat, excluding block: Set<String>) -> (id: String, after: Bool)? {
        StripBlockLanding.target(pointerX: x,
                                 frames: chipFrames.filter { !block.contains($0.key) })
    }

    /// A payload dragged from the bar (window card / placeholder / messaging chip / folder chip) entering/leaving this bar's hit box → tell the controller:
    /// enter = yield restore (`.strip` also claims the handover — cross-display window drag ③④: the empty slot opens here, reordering lands here, and the drop anchor is reported from here);
    /// clearly leaving = the slot collapses and the bar shortens (owner 2026-09-03, matching the native Dock). The hit box is the same as for drawer promotion
    /// (`StripPointerBox`). Runs before the owner gate: both the handover and "leaving" must be decidable by the bar that does not claim.
    private func updateStripPresence() {
        let dc = dragController
        guard let p = dc.draggingPayload, p.source != .drawer, dc.conversion == nil,
              stripRootScreenRect != .zero else { return }
        // Claiming for a cross-display window drag (③④) goes by **the display the pointer is on**, not the bar's hit box (owner 2026-09-03: "drag to display B and it lands on
        // bar B, drag to display A and it lands on bar A"; before, you had to press into the other bar's box to hand over, and releasing in the empty area of display B would fly back to A).
        // The claim decides which bar opens the empty slot, who reports the drop anchor, and whether release moves the window; the hit box only handles slot collapse / reopen.
        if p.source == .strip, let displayUUID,
           let screen = NSScreen.screens.first(where: { $0.frame.contains(dc.globalLocation) }),
           DisplayIdentity.uuidString(for: screen) == displayUUID {
            dc.claimStripSurface(stripSurfaceID, displayUUID: displayUUID)
        }
        // Over the capsule the slot keeps whatever state it has: the box reaches over the capsule,
        // so a card lifted off the bar would reopen its slot there, and the regrown bar shifts the
        // capsule out from under the pointer.
        guard !dc.isOverStashZone else { return }
        let box = StripPointerBox.classify(pointer: dc.globalLocation, stripRect: stripRootScreenRect,
                                           rightReach: metrics.capsuleGap + metrics.capsuleWidth,
                                           profile: .stripPresence)
        if box.enter {
            dc.noteStripEntered(surfaceID: stripSurfaceID, displayUUID: displayUUID)
        } else if box.clearlyOut {
            dc.noteStripLeft(surfaceID: stripSurfaceID)
        }
    }

    /// Entering/leaving the taskbar area drives promotion/revert (hysteresis prevents jitter at the boundary).
    /// unstash path: enter → convertDrawerToStrip + stage the drop point; leave → cancelExternalBlock + revertDrawerToStrip.
    /// keepPlacement path: with no real window, land using the existing app fallback / kept placeholder; kept is never modified throughout.
    func updateDrawerToStripConvert(projection: StripProjection) {
        let dc = dragController
        guard let p = dc.draggingPayload, p.source == .drawer, p.canExternalDrop,
              stripRootScreenRect != .zero else { return }
        let bid = p.bundleID
        let g = dc.globalLocation
        let r = stripRootScreenRect
        // The reason the right-hand tolerance extends to the outer edge of the capsule is in `StripPointerBox` (for a drawer-sourced payload the capsule has no other meaning,
        // its drop zone is only the taskbar panel, so merging it in does not conflict with collapsing).
        let box = StripPointerBox.classify(pointer: g, stripRect: r,
                                           rightReach: metrics.capsuleGap + metrics.capsuleWidth,
                                           profile: .drawerConversion)
        let enter = box.enter, clearlyOut = box.clearlyOut
        if HoverTrace.isEnabled {
            HoverTrace.drawerToStrip(x: g.x, y: g.y, strip: r, enter: enter, clearlyOut: clearlyOut,
                                     mode: "\(currentDrawerDragOutMode(bid, projection: projection))",
                                     converted: dc.isConvertedToStrip)
        }
        if !dc.isConvertedToStrip {
            guard enter else { return }
            let mode = currentDrawerDragOutMode(bid, projection: projection)
            // reject stays in the drawer; releaseToMessaging is handled by updateDrawerToMessagingRelease by the messaging-area extent.
            guard mode == .unstash || mode == .keepPlacement else { return }
            // At this moment this group's window cards have not appeared in the live area yet, so the hit target is searched only among the **existing** cards (an empty exclude set is enough).
            let target = stripPoint(from: g).flatMap { blockTarget(atX: $0.x, excluding: []) }
            dc.claimStripSurface(stripSurfaceID)   // The promoted bar has exclusive write-back from now on, until landing / promotion is revoked
            dc.convertDrawerToStrip()
            stripOrderStore.stageExternalBlock(bundleID: bid, relativeTo: target?.id, after: target?.after ?? false)
            HoverTrace.drawerToStripStage(bundleID: bid, target: target?.id, after: target?.after ?? false)
        } else if clearlyOut {
            stripOrderStore.cancelExternalBlock()
            dc.revertDrawerToStrip()
        }
    }

    // MARK: - Messaging-area drag (in-area reorder + release/rollback of drawer messaging apps, global-mouse driven)

    /// The bundleID of the messaging-area chip being dragged (nil = none). After drag start the in-place chip is hidden with opacity and the layout slot is kept
    /// (the slot is the drop feedback). During the collapse preview the payload source flips to .drawer, and this value automatically becomes nil — the chip has vanished from the area by then.
    private var draggingMessagingBundleID: String? {
        guard ownsActiveDrag else { return nil }
        if let p = dragController.hiddenSlotPayload, p.source == .messaging { return p.bundleID }
        return nil
    }

    /// The bundleIDs of the currently visible messaging-area chips (in-area display order). Feeds the reorder traversal + cleanup of disappearance during a drag.
    /// Messaging-area extent ("strip" space): the union of existing messaging chip frames; when the area is empty it degrades to a short segment at the head of the bar
    /// (the messaging area materializes at the head after release). The release decision for drawer messaging apps uses it, not "leaving the drawer body" (Codex review P1-3).
    private func messagingReleaseZone(messagingIDs: [String]) -> CGRect? {
        let frames = messagingIDs.compactMap { messagingChipFrames[$0] }
        if let first = frames.first {
            return frames.dropFirst().reduce(first) { $0.union($1) }
        }
        guard stripRootScreenRect != .zero else { return nil }
        return CGRect(x: 0, y: 0, width: 56, height: stripRootScreenRect.height)
    }

    /// In-area messaging reorder: hit the frame of another messaging chip (expanded by 6pt to cover gaps between cells), land by left/right half.
    /// Traverse in in-area display order and take the leftmost (dict order is undefined, and after expansion adjacent frames overlap — same as the drawer). No reorder while over the drop zone (capsule/drawer).
    private func updateMessagingReorder(messagingIDs: [String]) {
        let dc = dragController
        guard let p = dc.draggingPayload, p.source == .messaging,
              !dc.isOverDropZone,
              let pt = stripPoint(from: dc.globalLocation) else { return }
        for bid in messagingIDs where bid != p.bundleID {
            guard let f = messagingChipFrames[bid], f.insetBy(dx: -6, dy: -6).contains(pt) else { continue }
            messagingStore.reorder(draggedID: p.bundleID, relativeTo: bid, after: pt.x > f.midX)
            return
        }
    }

    /// **A running messaging app** in the drawer dragged into the messaging-area extent → temporarily released back to the messaging area; leaving the extent (or entering the capsule/drawer drop zone) →
    /// rolled back to the drawer. 8pt in / 24pt out hysteresis prevents boundary jitter. After release the payload source is .messaging, and in-area reorder takes over for the exact landing automatically;
    /// release on mouse-up settles it (see DragConversionPlan.endAction for the endDrag decision). Desktop / folder area / live area never trigger release.
    private func updateDrawerToMessagingRelease(projection: StripProjection) {
        let dc = dragController
        if dc.isReleasedToMessaging {
            guard let pt = stripPoint(from: dc.globalLocation),
                  let zone = messagingReleaseZone(messagingIDs: projection.messagingIDs),
                  zone.insetBy(dx: -24, dy: -24).contains(pt),
                  !dc.isOverDropZone else {
                dc.revertDrawerToMessaging()
                return
            }
            return
        }
        // This path used to have not a single log, so "nothing happened at all when dragged over" had no way to be root-caused (compare: the unstash path
        // logs `d2s` every tick, which is what nailed the cause in one go last round). Each guard logs where it got stuck.
        guard let p = dc.draggingPayload, p.source == .drawer, p.canExternalDrop else { return }
        // Log only for messaging members: logging for ordinary apps every tick would flood the log (they should take unstash anyway, which has `d2s`).
        let isMessagingMember = messagingStore.contains(p.bundleID)
        func trace(_ stop: String, pt: CGPoint? = nil, zone: CGRect? = nil,
                   fallback: Bool = false, mode: String = "-", inZone: Bool = false) {
            HoverTrace.drawerToMessaging(
                bid: p.bundleID, x: pt?.x ?? -1, y: pt?.y ?? -1, zone: zone,
                fallback: fallback, mode: mode,
                inSnapshot: projection.snapshotBundleIDs.contains(p.bundleID),
                running: runningApplicationStore.isRunning(p.bundleID),
                inZone: inZone, released: false, stop: stop)
        }
        guard !dc.isConvertedToStrip else {
            if isMessagingMember { trace("convertedToStrip") }
            return
        }
        let mode = currentDrawerDragOutMode(p.bundleID, projection: projection)
        guard mode == .releaseToMessaging else {
            if isMessagingMember { trace("mode", mode: "\(mode)") }
            return
        }
        guard let pt = stripPoint(from: dc.globalLocation) else { return trace("noStripRect", mode: "\(mode)") }
        let fallback = projection.messagingIDs.compactMap { messagingChipFrames[$0] }.isEmpty
        guard let zone = messagingReleaseZone(messagingIDs: projection.messagingIDs) else {
            return trace("noZone", pt: pt, mode: "\(mode)")
        }
        let inZone = zone.insetBy(dx: -8, dy: -8).contains(pt)
        guard inZone else {
            return trace("outsideZone", pt: pt, zone: zone, fallback: fallback, mode: "\(mode)")
        }
        HoverTrace.drawerToMessaging(
            bid: p.bundleID, x: pt.x, y: pt.y, zone: zone, fallback: fallback, mode: "\(mode)",
            inSnapshot: projection.snapshotBundleIDs.contains(p.bundleID),
            running: runningApplicationStore.isRunning(p.bundleID),
            inZone: true, released: true, stop: "ok")
        // After release into this bar's messaging area, this bar has exclusive write-back until landing / revoking the release (`revertDrawerToMessaging` lets go).
        // Same sentence as `updateDrawerToStripConvert`: under ③④ both strips run this block, and if neither claims, the other bar
        // would judge "released but not in the area" by its own messaging area every tick → revoke, the two flip each other, and who the drop lands on depends on subscription order.
        dc.claimStripSurface(stripSurfaceID)
        dc.convertDrawerToMessaging()
    }

    /// After release back to the messaging area, swap the carrier from the small drawer icon to **the messaging-area icon**, same as the promotion-into-taskbar path.
    ///
    /// Symptom of missing this step: the carrier holds the 30.8pt small drawer icon the whole way, and at the handoff instant on release a 44pt messaging-area icon pops up on the bar,
    /// with no transition in between — "suddenly grows from very small, the size transition is abrupt" (owner 2026-08-20, WeChat).
    ///
    /// **It cannot be swapped in the same round as `convertDrawerToMessaging()`**: at that moment the chip has not yet materialized into the projection (what is in hand is the previous frame's),
    /// so like `syncConvertedCarrier` it hooks two drivers (pointer + `messagingIDs` changes).
    private func syncReleasedMessagingCarrier(projection: StripProjection) {
        let dc = dragController
        let entry: StripEntry? = {
            guard dc.isReleasedToMessaging, let p = dc.draggingPayload, p.source == .messaging else { return nil }
            return projection.messaging.first { $0.id == "msg-app-\(p.bundleID)" }
        }()
        guard entry?.id != carriedMessagingChipID else { return }
        carriedMessagingChipID = entry?.id
        // entry back to nil = rollback to the drawer, passing nil makes the carrier switch back to the drawer image from drag start.
        dc.setCarrierSnapshot(entry.flatMap { carrierSnapshot(for: $0, projection: projection) },
                              reanchor: true)
    }

    /// After promotion, continuous whole-block reorder: acts only once this group's window cards are all in the live area (materialized); the initial drop point is completed by staging inside sync.
    /// The keepPlacement path has no window card, and does single-element block reorder with the placeholder id "app-\(bid)".
    private func updateStripBlockReorder(projection: StripProjection) {
        let dc = dragController
        guard dc.isConvertedToStrip, let p = dc.draggingPayload, p.source == .drawer else { return }
        let ids = projection.liveChipIDs(bundleID: p.bundleID)
        let blockIDs = ids.isEmpty ? ["app-\(p.bundleID)"] : ids
        guard !blockIDs.isEmpty, blockIDs.allSatisfy(projection.liveOrderIDs.contains) else {
            HoverTrace.stripBlockReorder(target: nil, after: false, why: "notMaterialized")
            return
        }
        guard let pt = stripPoint(from: dc.globalLocation) else {
            HoverTrace.stripBlockReorder(target: nil, after: false, why: "noStripRect")
            return
        }
        guard let target = blockTarget(atX: pt.x, excluding: Set(blockIDs)) else {
            HoverTrace.stripBlockReorder(target: nil, after: false, why: "liveZoneEmpty")
            return
        }
        HoverTrace.stripBlockReorder(target: target.id, after: target.after, why: "ok")
        stripOrderStore.reorderBlock(ids: blockIDs, relativeTo: target.id, after: target.after)
    }

    /// Wraps a chip with in-app drag-reorder for the **live zone only** (route A, self-drawn drag).
    /// Pinned messaging chips don't participate (no gesture → can't land in that zone; dragging happens within the zone).
    ///
    /// Native-Dock feel: while dragging, the in-place chip is hidden (`opacity 0`) so its slot
    /// becomes the landing **gap**; what you carry is the self-rendered `floatingDragCopy` (fully
    /// ours → zero afterimage on release, unlike the old system `.onDrag` image that faded in place). Pointer over a
    /// target's left/right half → land left/right. A plain tap (< minimumDistance) still falls
    /// through to the chip's `onTapGesture`; right-click still opens the menu; horizontal scroll
    /// is wheel/trackpad so it never fights this click-drag.
    @ViewBuilder
    private func chipWithReorder(_ entry: StripEntry, projection: StripProjection) -> some View {
        switch entry {
        case let .window(item):
            stripEntryView(entry, projection: projection)
                .opacity(projection.draggingID == item.id ? 0 : 1)
                // Frame in the shared `"strip"` space via a **background** GeometryReader — doesn't
                // affect layout and doesn't steal clicks (an overlay with a hittable Color.clear
                // intercepts taps — the original slice-3 bug). Feeds both the floating copy's
                // position and the left/right-half landing decision.
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: ChipFramePreferenceKey.self,
                                               value: [item.id: geo.frame(in: .named("strip"))])
                    }
                )
                // simultaneousGesture so the chip's own onTapGesture / contextMenu stay intact.
                // minimumDistance: 8 → a click never starts a drag (no misfire).
                // Hand drag start to DragController (the carrier panel + monitor take over following / drop point / wrap-up throughout); this gesture only handles
                // **starting the drag once** (computing grabOffset, taking the screen-coordinate start point). In-bar reordering has also been pointer-driven since 2026-08-19
                // (`updateLiveReorder`, same as the messaging area / drawer / promoted block): a drag re-grabbed during the homing flight has no gesture.
                // onEnded is an idempotent fallback besides the monitor's mouseUp.
                // **Prepare on press** (`DragController.prepareCandidate`): at the instant of mouse-down, attach this card's bitmap to the carrier layer to warm up the texture,
                // so that on the drag-start round "light up + hide the card" can happen in the same frame. If the release happens without a drag start, it is withdrawn.
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named("strip"))
                        .onChanged { _ in
                            prepareDragCandidate(entry, id: item.id, slot: chipFrames[item.id], projection: projection)
                        }
                        .onEnded { _ in dragController.clearCandidate(payloadID: item.id) }
                )
                .simultaneousGesture(
                    DragGesture(minimumDistance: 8, coordinateSpace: .named("strip"))
                        .onChanged { value in
                            if dragController.draggingPayload == nil {
                                let slot = chipFrames[item.id]
                                let grab: CGSize = slot.map {
                                    CGSize(width: $0.midX - value.startLocation.x,
                                           height: $0.midY - value.startLocation.y)
                                } ?? .zero
                                let payload = DragPayload(source: .strip, id: item.id,
                                                          bundleID: item.bundleIdentifier ?? "",
                                                          item: item, visualKind: .stripChip,
                                                          canExternalDrop: DragController.canStash(item))
                                dragController.beginDrag(payload: payload, stripSurfaceID: stripSurfaceID,
                                                         startScreenLocation: NSEvent.mouseLocation,
                                                         grabOffset: grab,
                                                         sourceScreenRect: slot.map(stripFrameToScreen) ?? .zero,
                                                         pose: pickUpPose(for: entry, slot: slot),
                                                         snapshot: carrierSnapshot(for: entry, projection: projection))
                            }
                            // In-bar reordering is **not here**: it is done uniformly by `updateLiveReorder` (pointer-driven) —
                            // a drag re-grabbed during the homing flight has no such gesture (see `DragController.regrabLanding`).
                        }
                        .onEnded { _ in dragController.endDrag() }
                )
        case let .messagingApp(bid, _):
            // Messaging-area chips are draggable: in-area reorder + drag into the drawer to stow (owner 2026-07-11). Frames are reported into the **separate**
            // MessagingChipFramePreferenceKey (never mixed into chipFrames, same isolation reason as folder chips).
            // The gesture **only handles starting the drag once**: reordering moves this chip and SwiftUI then cancels the gesture → in-area reorder is driven by
            // updateMessagingReorder() from the global mouse (same lesson as the drawer, Codex review P1-4).
            stripEntryView(entry, projection: projection)
                .opacity(draggingMessagingBundleID == bid ? 0 : 1)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: MessagingChipFramePreferenceKey.self,
                                               value: [bid: geo.frame(in: .named("strip"))])
                    }
                )
                // **Prepare on press** (`DragController.prepareCandidate`): at the instant of mouse-down, attach this card's bitmap to the carrier layer to warm up the texture,
                // so that on the drag-start round "light up + hide the card" can happen in the same frame. If the release happens without a drag start, it is withdrawn.
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named("strip"))
                        .onChanged { _ in
                            prepareDragCandidate(entry, id: bid, slot: messagingChipFrames[bid], projection: projection)
                        }
                        .onEnded { _ in dragController.clearCandidate(payloadID: bid) }
                )
                .simultaneousGesture(
                    DragGesture(minimumDistance: 8, coordinateSpace: .named("strip"))
                        .onChanged { value in
                            guard dragController.draggingPayload == nil else { return }
                            let slot = messagingChipFrames[bid]
                            let grab: CGSize = slot.map {
                                CGSize(width: $0.midX - value.startLocation.x,
                                       height: $0.midY - value.startLocation.y)
                            } ?? .zero
                            let payload = DragPayload(source: .messaging, id: bid,
                                                      bundleID: bid, item: nil,
                                                      visualKind: .messagingIcon,
                                                      canExternalDrop: true)
                            dragController.beginDrag(payload: payload, stripSurfaceID: stripSurfaceID,
                                                     startScreenLocation: NSEvent.mouseLocation,
                                                     grabOffset: grab,
                                                     sourceScreenRect: slot.map(stripFrameToScreen) ?? .zero,
                                                     pose: pickUpPose(for: entry, slot: slot),
                                                     snapshot: carrierSnapshot(for: entry, projection: projection))
                        }
                        .onEnded { _ in dragController.endDrag() }
                )
        case let .keptApp(bid):
            // Keep-app placeholder is draggable: mirrors the drag-reorder of .window cards + can be dragged into the drawer (canExternalDrop=true).
            let chipID = "app-\(bid)"
            stripEntryView(entry, projection: projection)
                .opacity(projection.draggingID == chipID ? 0 : 1)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: ChipFramePreferenceKey.self,
                                               value: [chipID: geo.frame(in: .named("strip"))])
                    }
                )
                // **Prepare on press** (`DragController.prepareCandidate`): at the instant of mouse-down, attach this card's bitmap to the carrier layer to warm up the texture,
                // so that on the drag-start round "light up + hide the card" can happen in the same frame. If the release happens without a drag start, it is withdrawn.
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named("strip"))
                        .onChanged { _ in
                            prepareDragCandidate(entry, id: chipID, slot: chipFrames[chipID], projection: projection)
                        }
                        .onEnded { _ in dragController.clearCandidate(payloadID: chipID) }
                )
                .simultaneousGesture(
                    DragGesture(minimumDistance: 8, coordinateSpace: .named("strip"))
                        .onChanged { value in
                            if dragController.draggingPayload == nil {
                                let slot = chipFrames[chipID]
                                let grab: CGSize = slot.map {
                                    CGSize(width: $0.midX - value.startLocation.x,
                                           height: $0.midY - value.startLocation.y)
                                } ?? .zero
                                let payload = DragPayload(source: .strip, id: chipID,
                                                          bundleID: bid, item: nil,
                                                          visualKind: .keptAppIcon,
                                                          canExternalDrop: true)
                                dragController.beginDrag(payload: payload, stripSurfaceID: stripSurfaceID,
                                                         startScreenLocation: NSEvent.mouseLocation,
                                                         grabOffset: grab,
                                                         sourceScreenRect: slot.map(stripFrameToScreen) ?? .zero,
                                                         pose: pickUpPose(for: entry, slot: slot),
                                                         snapshot: carrierSnapshot(for: entry, projection: projection))
                            }
                            // In-bar reorder: see `updateLiveReorder` (pointer-driven, same as the .window branch).
                        }
                        .onEnded { _ in dragController.endDrag() }
                )
        case let .pinnedFolder(path):
            // Folder chip: in-area drag reorder + drag out to remove + drag back to the window area to open (owner 2026-07-06 feedback landed).
            // Frames are reported into the **separate** FolderChipFramePreferenceKey (popup anchor + external pin routing + this area's reorder
            // hit-test), never mixed into the live reorder's chipFrames (review P1). The gesture mirrors the .window card: drag start is handed to
            // DragController (.folder source, isolated from strip/drawer stow semantics); in-area reorder and
            // FolderChipDropGeometry are pointer-driven; final remove/open is triggered by the fallback wrap-up of DragController.endDrag.
            stripEntryView(entry, projection: projection)
                .opacity(draggingFolderPath == path ? 0 : 1)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: FolderChipFramePreferenceKey.self,
                                               value: [entry.id: geo.frame(in: .named("strip"))])
                    }
                )
                // **Prepare on press** (`DragController.prepareCandidate`): at the instant of mouse-down, attach this card's bitmap to the carrier layer to warm up the texture,
                // so that on the drag-start round "light up + hide the card" can happen in the same frame. If the release happens without a drag start, it is withdrawn.
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named("strip"))
                        .onChanged { _ in
                            prepareDragCandidate(entry, id: path, slot: folderChipFrames[entry.id], projection: projection)
                        }
                        .onEnded { _ in dragController.clearCandidate(payloadID: path) }
                )
                .simultaneousGesture(
                    DragGesture(minimumDistance: 8, coordinateSpace: .named("strip"))
                        .onChanged { value in
                            if dragController.draggingPayload == nil {
                                let slot = folderChipFrames[entry.id]
                                if folderPopupPresence.isOpen(path) {
                                    onFolderDragWillBegin()
                                    // The bitmap prepared on mouse-down shows the open look.
                                    prepareDragCandidate(entry, id: path, slot: slot, projection: projection)
                                }
                                let grab: CGSize = slot.map {
                                    CGSize(width: $0.midX - value.startLocation.x,
                                           height: $0.midY - value.startLocation.y)
                                } ?? .zero
                                let payload = DragPayload(source: .folder, id: path,
                                                          bundleID: "", item: nil,
                                                          visualKind: .folderChip,
                                                          canExternalDrop: false)
                                dragController.beginDrag(payload: payload, stripSurfaceID: stripSurfaceID,
                                                         startScreenLocation: NSEvent.mouseLocation,
                                                         grabOffset: grab,
                                                         sourceScreenRect: slot.map(stripFrameToScreen) ?? .zero,
                                                         pose: pickUpPose(for: entry, slot: slot),
                                                         snapshot: carrierSnapshot(for: entry, projection: projection))
                            }
                            // In-area reorder + drop classification are both pointer-driven (`updateFolderReorder` / `updateFolderDragZone`
                            // in `.onReceive(pointerMoves)`) — a re-grabbed drag has no such gesture.
                        }
                        .onEnded { _ in dragController.endDrag() }
                )
        case .shelf:
            // The shelf cell is pinned at the head and not draggable. Frames go through the separate ShelfFramePreferenceKey (review: no sentinel mixing).
            stripEntryView(entry, projection: projection)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: ShelfFramePreferenceKey.self,
                                               value: geo.frame(in: .named("strip")))
                    }
                )
        case .trash:
            stripEntryView(entry, projection: projection)
                .background(GeometryReader { geo in
                    Color.clear.preference(key: TrashFramePreferenceKey.self,
                                           value: geo.frame(in: .named("strip")))
                })
        case .divider:
            stripEntryView(entry, projection: projection)
        case .externalDropGhost:
            // Yield gap: **deliberately not routed through `stripEntryView`**. That function is the sole reporting point for hover frames,
            // while the gap can neither report hover frames (no bubble popup) nor, even more so, report `ChipFramePreferenceKey`
            // — `chipFrames` is the input of the drop decision `StripBlockLanding` itself, and a gap entering it would
            // self-anchor: the computed drop point would point at the gap itself, and jitter whenever the pointer moves. Here it only occupies one card width.
            //
            // ⚠️ **The base color must be one that really draws; it cannot be `Color.clear`** (measured over five rounds on 2026-09-08).
            // A fully transparent view does not take part in the hit region of `.onDrop`, and `.contentShape` cannot save it: once the gap opens
            // under the cursor, the cursor falls into the hole → `dropExited` → the gap is cleared → the card returns under the cursor →
            // `dropEntered`, an endless loop at about 30 times/second, showing up as the plus sign on the cursor and the bar edge flickering together.
            // Quantified (the number of enter/exit per drag): 77 → gap plus `.contentShape` **69, ineffective** →
            // `.contentShape` on the layer hosting `onDrop` **56, ineffective** → switched to the nearly invisible
            // but genuinely drawn color below **10**. `.contentShape` is kept to pin the hit shape to the whole rectangle,
            // but it cannot work alone — what works is "this view really draws something".
            Color.black.opacity(0.001)
                .frame(width: ChipPillMetrics.cardWidth * dockScale,
                       height: ChipPillMetrics.chipHeight * dockScale)
                .contentShape(Rectangle())
        }
    }

    /// Hover hit frames are reported in **one place** here (`StripHoverFramePreferenceKey`), so none of the four zones can miss it
    /// — the pit that `ChipView.onWindowTitleTooltipEvent` fell into back then, "some call site forgot to pass it and it still compiled",
    /// will not recur on this path. Separators report too: they occupy those 5pt, and when the pointer is over them nobody owns the bubble,
    /// so a wide gap naturally means "pop up nothing", and the cards on both sides do not fight across it.
    @ViewBuilder
    private func stripEntryView(_ entry: StripEntry, projection: StripProjection) -> some View {
        stripEntryContent(entry, projection: projection,
                          hovered: hoveredEntryID == entry.id, entrance: true)
            .modifier(DroppedAppLandingGrow(active: landingEntryIDs.contains(entry.id)))
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: StripHoverFramePreferenceKey.self,
                                           value: [entry.id: geo.frame(in: .named("strip"))])
                }
            )
    }

    /// The sole rendering funnel of the four zones. **The carrier bitmap also comes out of here** (`carrierSnapshot(for:projection:)`),
    /// so "what the carrier draws must be the same view as the slot" holds by construction, with no need to maintain a separate cross-reference table.
    ///
    /// - Parameters:
    ///   - hovered: whether the pointer is on this card. It used to read `hoveredEntryID` here; it is now passed in explicitly,
    ///     so that the snapshot path can pass `false` (the carrier is not hit-testable, and what it draws must be the non-hover state).
    ///   - entrance: whether to run the entrance animation (`stripEntrance`). **Snapshots must pass `false`**:
    ///     that modifier's `@State` starts from `opacity 0 / offset 8` and only flips to its final value in `onAppear`,
    ///     while the snapshot is taken synchronously — what comes out would be a semi-transparent image shifted up 8pt.
    @ViewBuilder
    private func stripEntryContent(_ entry: StripEntry, projection: StripProjection,
                                   hovered: Bool, entrance: Bool) -> some View {
        switch entry {
        case let .window(item):
            // Badges follow the app (2026-08-23): `badgesByBundleID` has already been scoped by messaging-app identity,
            // here we only pick "the leftmost card of that app".
            let windowBadge: String? = item.bundleIdentifier.flatMap { bid in
                projection.badgeEntryIDByBundle[bid] == item.id ? badgeStore.badgesByBundleID[bid] : nil
            }
            ChipView(item: item,
                     labelTitle: projection.labelTitleByChipID[item.id] ?? item.title,
                     scale: dockScale,
                     hoverStyle: hoverStyle,
                     isHovered: hovered,
                     // Only app-* fallback cards (pinned Finder / keep fallback) represent the whole app; ordinary window cards are not listed.
                     showsWindowListInMenu: item.isAppLevelFallback,
                     isFrontWindow: projection.frontWindowChipIDs.contains(item.id),
                     showRunningDot: true,
                     pulseNonce: chipPulseNonces[item.id] ?? 0,
                     badgeText: windowBadge,
                     slotHidden: projection.draggingID == item.id)
        case .divider:
            Rectangle()
                .fill(theme.zoneDivider.color)
                // Width is a hairline, always 1pt without scaling; only the height follows the tier.
                .frame(width: 1, height: Style.dividerHeight * dockScale)
                .padding(.horizontal, Style.dividerSidePadding * dockScale)
        case let .pinnedFolder(path):
            let index = 1 + (pinnedFolderStore.folderPaths.firstIndex(of: path) ?? 0)
            let delay = Double(min(index, 6)) * 0.018
            PinnedFolderChip(
                path: path,
                cover: folderCoverStore.covers[path],
                sortOrder: pinnedFolderStore.sortOrder(for: path),
                displayMode: pinnedFolderStore.displayMode(for: path),
                viewMode: pinnedFolderStore.viewMode(for: path),
                onTap: { folderPrimaryTap(path) },
                onPreview: { folderShowPreview(path) },
                onOpenInFinder: { openFolderInFinder(path) },
                onAddFolder: onAddFolder,
                onRemove: { pinnedFolderStore.remove(path) },
                onSetSortOrder: { pinnedFolderStore.setSortOrder($0, for: path) },
                onSetDisplayMode: { pinnedFolderStore.setDisplayMode($0, for: path) },
                onSetViewMode: { pinnedFolderStore.setViewMode($0, for: path) },
                isDropTarget: externalDropTarget == .moveInto(path: path),
                openStyle: folderPopupPresence.style(for: path),
                scale: dockScale,
                hoverStyle: hoverStyle,
                isHovered: hovered
            )
            .stripEntrance(id: entrance ? entry.id : nil, delay: delay,
                           animatedEntryIDs: $animatedEntryIDs)
        case .trash:
            trashChip(hovered: hovered)
                .stripEntrance(id: entrance ? entry.id : nil, delay: 0,
                               animatedEntryIDs: $animatedEntryIDs)
        case .shelf:
            ShelfChip(
                itemCount: shelfStore.itemPaths.count,
                isDropTargeted: externalDropTarget == .stash,
                scale: dockScale,
                hoverStyle: hoverStyle,
                isHovered: hovered,
                onTap: { shelfChipTapped() },
                onClear: { shelfStore.clear() },
                onAddFolder: onAddFolder
            )
            .stripEntrance(id: entrance ? entry.id : nil, delay: 0,
                           animatedEntryIDs: $animatedEntryIDs)
        case let .messagingApp(bid, main):
            // The unread badge is handed to the chip to draw itself (`badgeText:`), no longer layered on by wrapping a ZStack here.
            // When layered outside it lands **outside** the chip's scaling: on hover magnify / press shrink, the red dot does not budge
            // (owner 2026-08-17 measured both frames at 16×15pt). See `ChipBadgeView`.
            let badge = badgeStore.badgesByBundleID[bid]
            Group {
                if let main {
                    // Running with a main window → the app chip is the main window card: standard toggle + full window menu. iconOnly keeps the messaging area's
                    // fixed-width icon row, and the running dot marks it as an app entry.
                    // This one in the messaging area is always `iconOnly` with no text, so the label can just be the raw title (`.help` still uses `fullTitle`).
                    ChipView(item: main, labelTitle: main.title,
                             scale: dockScale, hoverStyle: hoverStyle,
                             isHovered: hovered,
                             // The messaging-area icon always represents the whole app (even when the main window is open), so list all windows.
                             showsWindowListInMenu: true,
                             isFrontWindow: projection.frontWindowChipIDs.contains(main.id),
                             iconOnly: true, showRunningDot: true,
                             badgeText: badge,
                             slotHidden: draggingMessagingBundleID == bid)
                } else {
                    // Two states without a main window: running (window closed / pinned) → click reopens the main window; not running (no running dot under the icon) → click launches.
                    // Under the unified model messaging apps also have the "Keep in Dock" check (coexisting with "Unmark"), decided by the pure projection.
                    let running = runningApplicationStore.isRunning(bid)
                    LauncherChip(bundleID: bid,
                                 isRunning: running,
                                 isHidden: running && projection.hiddenBundleIDs.contains(bid),
                                 finderHasRealWindow: false,   // Finder cannot enter the messaging area

                                 isLaunching: runtime.launchingBundleIDs.contains(bid),
                                 scale: dockScale,
                                 layout: .bar,
                                 hoverStyle: hoverStyle,
                                 hoverInput: .resolved(hovered),
                                 windowEntriesProvider: {
                                     WindowListMenuPlan.entries(
                                         snapshot: runtime.snapshot,
                                         bundleID: bid,
                                         fallbackTitle: AppDisplayNameResolver.displayName(for: bid)
                                     )
                                 },
                                 onActivateWindow: { runtime.activate(windowID: $0) },
                                 membershipItems: LauncherMembershipItem.items(
                                    surface: .strip,
                                    bundleID: bid,
                                    isKept: keptAppStore.contains(bid),
                                    isMessaging: true,
                                    controller: appMembershipController
                                 ),
                                 badgeText: badge,
                                 slotHidden: draggingMessagingBundleID == bid,
                                 onTap: running
                                    ? { Self.messagingFallbackTap(bundleID: bid,
                                                                  hasRealWindow: projection.hasRealWindow(bundleID: bid)) }
                                    : nil,
                                 onLaunch: { runtime.beginLaunch(bid) })
                }
            }
        case let .keptApp(bid):
            let isRunning = runningApplicationStore.isRunning(bid)
            let hasRealWindow = projection.hasRealWindow(bundleID: bid)
            let reopen: (() -> Void)? = isRunning && !hasRealWindow
                ? { Self.reopenMainWindow(bundleID: bid) }
                : nil
            LauncherChip(
                bundleID: bid,
                isRunning: isRunning,
                isHidden: runningApplicationStore.isHidden(bid),
                finderHasRealWindow: false,   // Finder intentionally does not go through the .keptApp projection

                isLaunching: runtime.launchingBundleIDs.contains(bid),
                scale: dockScale,
                layout: .bar,
                hoverStyle: hoverStyle,
                hoverInput: .resolved(hovered),
                windowEntriesProvider: {
                    WindowListMenuPlan.entries(
                        snapshot: runtime.snapshot,
                        bundleID: bid,
                        fallbackTitle: AppDisplayNameResolver.displayName(for: bid)
                    )
                },
                onActivateWindow: { runtime.activate(windowID: $0) },
                membershipItems: keptAppMembershipItems(bundleID: bid),
                badgeText: projection.badgeEntryIDByBundle[bid] == entry.id
                    ? badgeStore.badgesByBundleID[bid] : nil,
                slotHidden: projection.draggingID == "app-\(bid)",
                onTap: reopen,
                onLaunch: { runtime.beginLaunch(bid) }
            )
        case .externalDropGhost:
            // Unreachable: the gap branch of `chipWithReorder` does not go through `stripEntryView` (see there for the reason),
            // and the carrier snapshot would not capture something undraggable either. Left empty so as not to add a `default` to this switch.
            EmptyView()
        }
    }

}

// MARK: - Visual Constants (hand-tune these)

private enum Style {
    // Shape — the corner radius shares one definition with the other 4 panels (this enum is private, other files cannot read it).
    static let cornerRadius: CGFloat   = DockShape.taskbarCornerRadius

    // Content layout
    // The icon's transparent artwork margin is equal on both axes and cancels out here.
    static let chipContentInset: CGFloat = DebugSwitch.stripBalancedInsets.isEnabled()
        ? (ChipPillMetrics.chipHeight - ChipPillMetrics.cardWidth) / 2
        : 20
    // Keep the resting end icons outside the scroll fade when the padding is reduced.
    static let edgeFadeWidth: CGFloat = min(16, chipContentInset)
    // The real definition is in `ChipPillMetrics.chipSpacing` (the bubble's neighborhood decision also needs the center spacing, and this enum is
    // private, other files cannot read it). Changing it must be accompanied by changing `StripContextMenuZone.defaultMinimumGapWidth`,
    // for the reason see the comment there.
    static let chipSpacing: CGFloat      = ChipPillMetrics.chipSpacing
    static let dividerHeight: CGFloat    = 20  // zone divider height (pt)
    /// Each side of the hairline. With `chipSpacing` the divider gap is `StripContextMenuZone.dividerGapWidth`.
    static let dividerSidePadding: CGFloat = (StripContextMenuZone.dividerGapWidth - 1) / 2 - chipSpacing

    // The "strong top, weak bottom" highlight of the stroke has been formally taken over by DockThemeTokens.panelRimTop / panelRimBottom
    // (the two constants that used to be here were dead code with zero references; what was actually drawn was a uniform ring of white 0.15).
}
