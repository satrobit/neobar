import AppKit
import ApplicationServices
import Combine
import QuartzCore
import SwiftUI
import os

// PanelCoordinator · Layout: content-width subscription, target-frame computation and commit, level switching, screen-parameter changes.
// Split out of PanelCoordinator.swift as an extension on 2026-09-05; moved only, not changed.
extension PanelCoordinator {
    // MARK: - Content Width via fittingSize

    func subscribeSnapshotWidth() {
        snapshotWidthSubscription = runtime.$snapshot
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshot in
                guard let self else { return }
                // The `receive(on:)` hop is already after the snapshot write, so `fittingSize` lays SwiftUI out synchronously against the new snapshot,
                // and there's no need to push another main-queue turn. Card additions/removals (the id set changed) still use the window animation; when only a label changed and the follow window is open,
                // no animation is started: the content width changes every frame during that time, the panel follows frame by frame via `labelFollowTick`, and what is measured here is only an intermediate value.
                let ids = Set(snapshot.orderedWindowIDs)
                let idsChanged = self.lastSnapshotWindowIDs != ids
                self.lastSnapshotWindowIDs = ids
                if idsChanged {
                    self.relayout(animated: true)   // layoutPanels includes drawer repositioning
                } else if !self.isLabelFollowActive {
                    self.relayout(animated: true)
                }
                // Follow window is open and only a label changed: do nothing; the panel is driven along the curve by `labelFollowTick`.
            }
    }

    func subscribeDrawerStoreWidth() {
        drawerStoreWidthSubscription = drawerStore.$bundleIDs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    self?.syncDrawerOrder()
                    self?.relayout(animated: true)
                }
            }
    }

    /// Collapse on drag-out (owner 2026-09-03): when the card on the strip leaves / returns to the taskbar, the projection layer culls / restores it, and the panel width
    /// has to follow with animation. The taskbar width is **no longer clamped** (the width-freeze mechanism from the two rounds of 2026-06-22 -> 08-20 was deleted with it):
    /// the strip width always equals the width of what is rendered right now, so on release to stash the strip is already narrow and the capsule / drawer no longer slide during the flight.
    /// Written like the store subscription (receive(on:) first, then one more async turn so SwiftUI lays out against the new projection first and `fittingSize` is the new width).
    func subscribeStripSlotCollapse() {
        stripSlotCollapseSubscription = dragController.$stripSlotCollapsed
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                // The level-switch transaction's cancelDrag() also gets here and queues an animated layout; swallow it with a generation counter,
                // otherwise it would animate once with the new metrics and then jump once more from the transaction's non-animated layout.
                let generation = self.panelHeightChangeGeneration
                DispatchQueue.main.async { [weak self] in
                    guard let self, generation == self.panelHeightChangeGeneration else { return }
                    self.relayout(animated: true)
                }
            }
    }

    /// Drawer order converges on the full placement set, not trimmed to the currently visible items. It syncs even if the drawer isn't open,
    /// so hidden members return to their original relative positions on the next launch.
    private func syncDrawerOrder() {
        let members = AppMembershipProjection.drawerMembers(drawerIDs: drawerStore.bundleIDs)
        drawerOrderStore.sync(members: members)
    }

    func subscribeMessagingStoreWidth() {
        messagingStoreWidthSubscription = messagingStore.$bundleIDs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    self?.relayout(animated: true)
                }
            }
    }

    func subscribeKeptAppStore() {
        keptAppStoreSubscription = keptAppStore.$bundleIDs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    self?.relayout(animated: true)
                }
            }
    }

    func subscribeRunningApplicationStore() {
        runningApplicationStoreSubscription = runningApplicationStore.$runningBundleIDs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { [weak self] in self?.relayout(animated: true) }
            }
    }

    func subscribeSettings() {
        edgeDelaySubscription = settingsStore.$edgeAutoHideDelay
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.reconcilePanelVisibility()
                self?.onHoverMonitorsNeedReconcile?()  // The edge-hide switch changed: whether the monitors still need to exist
            }
        // Display position changed: dwell is voided; switching to a fixed level immediately moves to the fixed screen; monitors and wake arming are re-evaluated for the new level.
        // dropFirst: the launch path setupDockPanel has already consumed the persisted level.
        taskbarScreenPlacementSubscription = settingsStore.$taskbarScreenPlacement
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.cancelHoverSwitch()
                if let home = self.resolvedPinnedScreen(), let panel = self.dockPanel,
                   self.panelCurrentScreen(panel: panel) != home {
                    self.layoutPanels(contentWidth: self.lastDesiredWidth, on: home, animated: false)
                }
                self.onHoverMonitorsNeedReconcile?()
                self.reconcilePanelVisibility()
                // (3)<->(4) don't rebuild cells and only swap the projection layer's filter set: after SwiftUI redraws no other path comes back here to measure the width
                // (owner 2026-09-02 first-round acceptance: after switching levels the strip length didn't change until the window was clicked again). Wait for this layout pass to finish before measuring.
                DispatchQueue.main.async { [weak self] in self?.relayout(animated: true) }
            }
        // The screen table changed (plug/unplug / main screen switch): under (4) the render set changes (other screens' cards fall back to the main screen), so the width must be re-measured as well.
        displayTopologySubscription = displayTopologyStore.$table
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { [weak self] in self?.relayout(animated: true) }
            }
        // Showing/hiding the relay shelf changes the taskbar content width: if only the chip disappears without reflow, the panel stays at the old width,
        // and the capsule and any open drawer stay at the old position too. relayout must wait for this SwiftUI layout pass to finish
        // (fittingSize is only the new value then), so push one more main-queue turn.
        showShelfSubscription = settingsStore.$showShelf
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                if self.folderPopupWantsOpen, self.openPopupContent == .shelf { self.closeFolderPopup() }
                DispatchQueue.main.async { [weak self] in self?.relayout(animated: true) }
            }
        showTrashSubscription = settingsStore.$showTrash
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                if self.folderPopupWantsOpen, self.openPopupContent == .trash { self.closeFolderPopup() }
                DispatchQueue.main.async { [weak self] in self?.relayout(animated: true) }
            }
        dockPanelHeightSubscription = heightResizePresentation
            .nonInteractiveHeightChanges(from: settingsStore.$dockPanelHeight)
            .sink { [weak self] _ in
                self?.beginPanelHeightChange()
            }
    }

    /// A height change is a **transaction**, not a content change: panel height, capsule width
    /// and every chip's size move together, and any animated layout in between puts the three
    /// panels on half-old, half-new geometry.
    ///
    /// Order matters:
    /// 1. Retire everything attached to the old geometry — the drag carrier (sized by the
    ///    height), the drawer (`maxContentHeight` is passed once when it opens; moving only the
    ///    frame clips the content), popups and the tooltip (anchors are stale), and the
    ///    label-width follow (its rest width was measured at the old scale).
    /// 2. `cancelDrag()` queues an **animated** relayout via `subscribeStripSlotCollapse`; the
    ///    generation gate swallows it.
    /// 3. Let SwiftUI lay out once at the new height (`fittingSize` is only then the new width),
    ///    then commit once with no animation. Height changes are instant, never animated.
    ///
    /// Window-lift avoidance needs nothing here: `taskbarTop` derives from `panelHeight` inside
    /// the Equatable `WindowLiftAvoidanceContext`, so the controller's existing restore → re-lift
    /// path runs on its own (frozen during a drag, see `liftContextPanelHeightOverride`).
    func beginPanelHeightChange() {
        tearDownForPanelHeightChange()
        let generation = panelHeightChangeGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, generation == self.panelHeightChangeGeneration else { return }
            self.relayout(animated: false)
        }
    }

    func tearDownForPanelHeightChange() {
        panelHeightChangeGeneration &+= 1
        cancelLabelWidthFollow()
        dragController.cancelDrag()
        dismissWindowTitleTooltip()
        closeFolderPopup(immediately: true)
        if drawerWantsOpen { closeDrawer() }
    }

    // MARK: - Interactive height resize

    /// Broadcast from the orchestrator to **every** unit when any unit's grip starts (`true`) or
    /// ends (`false`) a drag. Not the auto-hide inhibitor: that goes on the dragged unit only
    /// (`beginInteractiveResize`) because an inhibitor also clears an existing auto-hide and
    /// would wake bars other screens had hidden.
    func setInteractiveHeightResizeActive(_ active: Bool) {
        guard interactiveHeightResizeActive != active else { return }
        interactiveHeightResizeActive = active
        heightResizePresentation.isActive = active
        if active {
            liftContextPanelHeightOverride = layoutMetrics.panelHeight
            tearDownForPanelHeightChange()
            settleRunningFrameAnimation()
            relayout(animated: false, batched: true)
        } else {
            liftContextPanelHeightOverride = nil
            relayout(animated: false)
        }
    }

    /// Grip mouse-down on this unit's bar.
    func beginInteractiveResize(pointer: CGPoint) {
        guard interactiveResize == nil else { return }
        interactiveResize = DockHeightDragSession(startHeight: settingsStore.dockPanelHeight.points,
                                                  startPointerY: pointer.y)
        showResizeCursor(at: pointer)
        setAutoHideInhibitor(.interactiveResize, active: true)
        onInteractiveHeightResizeSession?(true)
        // No orchestrator (tests, tools): still behave as a one-unit session.
        if !interactiveHeightResizeActive { setInteractiveHeightResizeActive(true) }
    }

    /// One drag tick. The glyph follows every event; the height changes only on whole points.
    /// Explicit hosting layout makes the new scale measurable in this same event. Content and
    /// panel geometry are committed together, without an intermediate old-size hosting frame.
    func updateInteractiveResize(pointer: CGPoint) {
        guard let session = interactiveResize else { return }
        showResizeCursor(at: pointer)
        let target = session.height(forPointerY: pointer.y)
        guard target != settingsStore.dockPanelHeight else { return }
        settingsStore.setDockPanelHeight(target)
        if let onInteractiveHeightResizeUpdate {
            onInteractiveHeightResizeUpdate()
        } else {
            commitInteractivePanelHeight()
        }
    }

    func commitInteractivePanelHeight() {
        guard interactiveHeightResizeActive else { return }
        panelHeightChangeGeneration &+= 1
        relayout(animated: false, batched: true)
    }

    func endInteractiveResize() {
        guard interactiveResize != nil else { return }
        interactiveResize = nil
        setAutoHideInhibitor(.interactiveResize, active: false)
        onInteractiveHeightResizeSession?(false)
        if interactiveHeightResizeActive { setInteractiveHeightResizeActive(false) }
    }

    /// End a drag from outside the view tree (topology change, unit rebuild, suspension). Goes
    /// through the grip so the pushed cursor is popped and re-decided; falls back to ending the
    /// session directly when the grip is already gone.
    func cancelInteractiveResize() {
        guard interactiveResize != nil else { return }
        resizeGripController.cancel()
        endInteractiveResize()
    }

    /// Converge a frame animation that is still in flight when a drag begins, so a press that
    /// then holds still (or moves under 1pt, producing no tick) does not leave the old animation
    /// running to its target. Clears `lastCommittedFrames` first: an animation heading for the
    /// same target would otherwise hit `setFrames`' "target unchanged" short-circuit.
    func settleRunningFrameAnimation() {
        guard CACurrentMediaTime() < animatedFramesUntil else { return }
        lastCommittedFrames = []
        relayout(animated: false)
    }

    /// Bar target frame: content width, capped; bar + drawer capsule centered as one group.
    func dockTargetFrame(contentWidth: CGFloat, on screen: NSScreen) -> NSRect {
        PanelGeometry.dockTargetFrame(contentWidth: contentWidth, on: Self.screenGeometry(screen), metrics: layoutMetrics)
    }

    /// Capsule target frame (against the taskbar's right edge, vertically centered). Depends only on the dock **target** frame passed in.
    private func capsuleTargetFrame(forDock dockFrame: NSRect, on screen: NSScreen) -> NSRect {
        PanelGeometry.capsuleTargetFrame(forDock: dockFrame, on: Self.screenGeometry(screen), metrics: layoutMetrics)
    }

    /// Drawer target frame (right edge on the capsule's right edge, **bottom edge hard-anchored above the capsule, growing upward**). Depends only on the capsule **target** frame passed in + the drawer size.
    /// Key point: the bottom edge never moves down. If the space above is exceeded, **cap the height** (the content scrolls inside DrawerView),
    /// and never squeeze it in by "pressing the bottom edge down", which would press into the capsule/taskbar (owner 2026-06-21 screenshot report).
    func drawerTargetFrame(forCapsule capsuleFrame: NSRect, size: CGSize, on screen: NSScreen) -> NSRect {
        // Bottom/left/right positioning use screen.frame, cutting the coupling to the native Dock's visibleFrame;
        // the top height is still capped by topUsableY, avoiding the menu bar and the notch.
        PanelGeometry.drawerTargetFrame(forCapsule: capsuleFrame, size: size, on: Self.screenGeometry(screen), metrics: layoutMetrics)
    }

    /// Unified layout entry: compute all three target frames, store them (for the drop zone / opening the drawer to read), and animate the three panels to the targets as one group.
    /// On screen open / screen switch / multi-screen hover pass animated:false; content changes, stash/move-back, and drawer size changes pass animated:true.
    func layoutPanels(contentWidth: CGFloat, on screen: NSScreen, animated: Bool, batched: Bool = false) {
        guard let dock = dockPanel, let capsule = capsulePanel else { return }
        let panelScreenCGFrame = Self.toCGRect(screen)
        if let transaction = fullscreenIntentTransaction,
           transaction.screenCGFrame != panelScreenCGFrame {
            cancelFullscreenIntent(generation: transaction.generation, reason: "panel-screen-changed")
        }
        // First frame is instant (no slide from the initial position); so is every frame while a
        // height drag is active anywhere — the dozen `relayout(animated: true)` callers need no
        // per-site gate.
        let anim = animated && didInitialLayout && !interactiveHeightResizeActive
        didInitialLayout = true
        onPanelScreenChanged?()

        let dockT = dockTargetFrame(contentWidth: contentWidth, on: screen)
        // The capsule (along with the drawer positioned by it) **always** sits against the strip's current target frame, during a drag too: collapse-on-drag-out makes the strip shrink symmetrically,
        // and the capsule moves with it (the native Dock likewise re-centers the whole strip). On 2026-09-03 the capsule was once pinned to the old target frame during a drag,
        // and on multi-screen every cell got pinned, so strip B grew wide and pressed into the capsule while strip A narrowed and left a big gap (reported by the owner that day). Don't add the anchoring back.
        let capsuleT = capsuleTargetFrame(forDock: dockT, on: screen)
        // Close the popup as soon as the taskbar target frame changes (width / screen switch); don't chase an anchor mid-animation (consistent with the native Dock, keeping the target frame pure).
        if dockT != lastDockTargetFrame {
            if folderPopupWantsOpen { closeFolderPopup() }
            dismissWindowTitleTooltip(suppressCurrentUntilExit: true)
        }
        lastDockTargetFrame = dockT
        lastCapsuleTargetFrame = capsuleT

        var pairs: [(NSPanel, NSRect)] = []
        if let background = dockGlassBackgroundPanel {
            dockGlassBackgroundView?.apply(
                cornerRadius: taskbarPlateCornerRadius,
                configuration: DockGlassPresentation.configuration
            )
            // The background window sits against the visible base plate (the content window minus the 20pt transparent shadow margin).
            pairs.append((
                background,
                DockLiquidGlassPanelGeometry.backgroundFrame(
                    for: dockT,
                    shadowPadding: Self.shadowPadding
                )
            ))
        }
        pairs.append((dock, dockT))
        pairs.append((capsule, capsuleT))
        if let drawer = drawerPanel, drawer.isVisible, let hosting = drawerContentHost {
            // Smaller than any plate = not laid out yet, never a size: keep the last good one.
            let fitting = hosting.fittingSize
            if Self.isPlausibleDrawerSize(fitting) { lastDrawerSize = fitting }
            let drawerT = drawerTargetFrame(forCapsule: capsuleT, size: lastDrawerSize, on: screen)
            lastDrawerTargetFrame = drawerT
            pairs.append((drawer, drawerT))
        }
        let commit = setFrames(pairs, animated: anim, batched: batched)
        if drawerWantsOpen { syncDrawerArrow(after: commit) }
    }

    /// Lay out after measuring the current content width (the unified entry for content changes).
    func relayout(animated: Bool, batched: Bool = false) {
        guard let panel = dockPanel, let hosting = dockContentHost else { return }
        let spanStart = HoverTrace.now(); defer { HoverTrace.span("relayout", since: spanStart) }
        if interactiveHeightResizeActive {
            panel.disableScreenUpdatesUntilFlush()
            dockGlassBackgroundPanel?.disableScreenUpdatesUntilFlush()
            capsulePanel?.disableScreenUpdatesUntilFlush()
            hosting.layoutContent()
            capsuleContentHost?.layoutContent()
        }
        // `fittingSize` **lays out the whole taskbar synchronously on the main thread**; it isn't reading a cached value.
        // What the probe measures is it + whether the width actually changed (running an animation when it didn't is pure waste).
        let measureStart = CACurrentMediaTime()
        let measured = hosting.fittingSize.width - 2 * Self.shadowPadding
        HoverTrace.relayout(measureMs: CACurrentMediaTime() - measureStart,
                            width: measured,
                            changed: measured != lastDesiredWidth,
                            animated: animated,
                            timing: (isLabelFollowActive ? "follow" : "standard") + ":" + String(stripSurfaceID.suffix(4)))
        lastDesiredWidth = measured
        // Cross-panel promotion in progress -> the taskbar width is clamped to the value before the drag (window cards overflow / leave blanks rather than change the panel width, owner 2026-06-22);
        // after release / restore unclamps, the next relayout takes the taskbar to its final length using the real measured value.
        layoutPanels(contentWidth: measured, on: panelCurrentScreen(panel: panel), animated: animated,
                     batched: batched || interactiveHeightResizeActive)
        if interactiveHeightResizeActive {
            panel.layoutIfNeeded()
            capsulePanel?.layoutIfNeeded()
            hosting.layoutContent()
            capsuleContentHost?.layoutContent()
        }
    }

    /// The three panels commit in one animation group, sharing a single timeline (Codex second review P2: avoid each running its own timeline and jittering).
    ///
    /// **When the target frames are exactly the same as the current ones, return directly; run not a single frame.**
    /// Measured 2026-08-17 (`DOCK_HOVER_TRACE=1`): in the 6 seconds after launch there were 10 `relayout` calls, of which **8** had
    /// no width change at all yet were still `animated: true`, and 6 in a row were packed within 1.1ms. Each one starts a set of
    /// window-size animations, "animating" the three panels to exactly their present size, **and every frame of a window-size animation has to
    /// redraw the glass base plate and its outline**. The measurement itself is cheap (`fittingSize` 0.2ms); the expensive part is this empty animation.
    ///
    /// The criterion is **full equality of the final frame** rather than "width unchanged": switching screens, changing levels, and edge hiding all really move the panel
    /// without changing the width, and comparing width alone would swallow them too.
    /// `batched` (only the per-frame label-follow tick passes true): `display: false`, so the three panels' frame changes are held until the end of this main-loop turn
    /// and committed together with the SwiftUI content; `display: true` one by one would each flush immediately, putting the capsule, base plate, and content on different frames
    /// (screen burst capture 2026-09-13: while growing longer, the capsule stuck to the base plate's edge).
    /// What `setFrames` did with the frames it was handed.
    enum FrameCommit { case unchanged, instant, animated }

    @discardableResult
    func setFrames(_ pairs: [(NSPanel, NSRect)], animated: Bool, batched: Bool = false) -> FrameCommit {
        // **Compare against the previous target, not the panel's live frame.**
        // The live frame mid-animation is an interpolated intermediate value that never equals the target, so this short-circuit would never hit
        // (measured 0 times). AGENTS "Menus, Panels, And Screens" already said the same thing: relayout is driven by the target
        // frame; don't read the panel's live frame during an animation.
        let targets = pairs.map(\.1)
        guard targets != lastCommittedFrames else {
            HoverTrace.framesUnchanged()
            return .unchanged
        }
        lastCommittedFrames = targets
        guard animated else {
            if CACurrentMediaTime() < animatedFramesUntil {
                // An animator group is still flying: a direct `setFrame` gets overwritten by its
                // remaining frames. A zero-duration group replaces the running animation instead.
                animatedFramesUntil = 0
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0
                    for (p, f) in pairs { p.animator().setFrame(f, display: !batched) }
                }
            } else {
                for (p, f) in pairs { p.setFrame(f, display: !batched) }
            }
            if let dock = dockPanel { HoverTrace.width("panel:" + String(stripSurfaceID.suffix(4)), dock.frame.width) }
            return .instant
        }
        animatedFramesUntil = CACurrentMediaTime() + Self.layoutAnimationDuration
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Self.layoutAnimationDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            for (p, f) in pairs { p.animator().setFrame(f, display: true) }
        }
        return .animated
    }

    // MARK: - Label width follow

    var isLabelFollowActive: Bool { labelFollowTimer != nil }

    /// A label in the strip got longer or shorter (`DockStripView.onLabelWidthChange`, called synchronously inside SwiftUI's update pass).
    /// `starting` = the starting width of the label box that begins animating this time. When the follow window is already open, only the new box is registered, and the starting width isn't re-measured.
    func beginLabelWidthFollow(starting: [String: CGFloat]) {
        guard !interactiveHeightResizeActive else { return }   // the drag owns the panel frames
        let now = CACurrentMediaTime()
        if !isLabelFollowActive {
            labelFollowRestWidth = lastDesiredWidth
            labelBoxStart = [:]
            labelBoxLive = [:]
        }
        for (id, from) in starting where labelBoxStart[id] == nil {
            labelBoxStart[id] = from
            labelBoxLive[id] = from
        }
        labelFollowDeadline = now + LabelWidthAnimation.curve.duration + 0.1
        guard labelFollowTimer == nil else { return }
        // The timer only handles the wrap-up: after the deadline, measure the final value once and clear state. The per-frame frame is set by `labelBoxWidthDidTick`.
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            guard CACurrentMediaTime() >= self.labelFollowDeadline else { return }
            t.invalidate()
            self.labelFollowTimer = nil
            self.labelBoxStart = [:]
            self.labelBoxLive = [:]
            self.relayout(animated: false)   // wrap-up: measure the final value once, absorbing the fraction of a pt from the starting-width estimate
        }
        RunLoop.main.add(timer, forMode: .common)
        labelFollowTimer = timer
    }

    /// Drop a follow window in progress (height change): its rest width was measured at the old
    /// scale. The final measurement happens on the caller's instant relayout.
    func cancelLabelWidthFollow() {
        guard isLabelFollowActive else { return }
        labelFollowTimer?.invalidate()
        labelFollowTimer = nil
        labelBoxStart = [:]
        labelBoxLive = [:]
    }

    /// `LabelBoxWidthDriver` reports each frame: only boxes registered in the follow window are honored; it doesn't compete while the card add/remove window animation is still in flight.
    /// `batched`: the three panels use `display: false` and commit together with this frame's SwiftUI content.
    func labelBoxWidthDidTick(chipID: String, width: CGFloat) {
        guard !interactiveHeightResizeActive else { return }
        guard isLabelFollowActive, labelBoxStart[chipID] != nil, labelBoxLive[chipID] != width else { return }
        labelBoxLive[chipID] = width
        guard CACurrentMediaTime() >= animatedFramesUntil, let panel = dockPanel else { return }
        let delta = labelBoxStart.reduce(CGFloat(0)) { acc, entry in
            acc + ((labelBoxLive[entry.key] ?? entry.value) - entry.value)
        }
        layoutPanels(contentWidth: labelFollowRestWidth + delta,
                     on: panelCurrentScreen(panel: panel), animated: false, batched: true)
    }

    /// Forwarded by the orchestration layer on `didChangeScreenParametersNotification` (it first builds / tears down cells by the screen set, then forwards to the survivors).
    /// Cancelling a cross-panel drag and re-evaluating monitors are likewise done once by the orchestration layer and are not repeated here.
    func screenParametersChanged() {
        cancelHoverSwitch()
        closeFolderPopup()             // screen parameters changed, the old anchor coordinates are void
        dismissWindowTitleTooltip(suppressCurrentUntilExit: true)
        guard dockPanel != nil else { return }
        // Pinned to a screen: when the screen set changes, first restore the position (pinned screen unplugged -> fall back to the main screen; reconnected -> move back).
        // Must come before relayout: relayout uses panelCurrentScreen to infer the screen from the panel's coordinates.
        if let home = resolvedPinnedScreen(), let panel = dockPanel,
           panelCurrentScreen(panel: panel) != home {
            layoutPanels(contentWidth: lastDesiredWidth, on: home, animated: false)
        }
        relayout(animated: false)      // screen switch is instant, no sliding
        cancelFullscreenIntentIfContextChanged()
        reconcilePanelVisibility()
    }

    static func screenGeometry(_ screen: NSScreen) -> PanelScreenGeometry {
        PanelScreenGeometry(frame: screen.frame, visibleFrame: screen.visibleFrame, safeAreaTop: screen.safeAreaInsets.top)
    }
}
