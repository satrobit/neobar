import AppKit
import ApplicationServices
import Combine
import QuartzCore
import SwiftUI
import os

// PanelCoordinator · Drawer: open/close, host reuse, drag drop-zone geometry, spring-loaded folder auto-open.
// Split out of PanelCoordinator.swift as an extension on 2026-09-05; moved only, not changed.
extension PanelCoordinator {
    func openDrawer() {
        guard let mainPanel = dockPanel, capsulePanel != nil else { return }
        onAccessoryWillOpen?(self, .drawer)
        drawerActionCloseToken += 1  // the delayed close queued by an old click captured the old token; if it doesn't match, discard it
        drawerWantsOpen = true
        setAutoHideInhibitor(.drawerOpen, active: true)
        drawerSpringOpened = false   // default is manual open; the spring path sets it to true again in springOpenDrawer
        setDrawerRaised(false)       // a reopen mid-fade may still hold the outside drag's level

        let screen = panelCurrentScreen(panel: mainPanel)
        let (capsuleRef, limits) = drawerAnchor(on: screen)

        // The host is built only once; afterwards, opening swaps rootView only if the available height changed.
        // Each stage is marked with `HoverTrace.action("drawerOpen")`: only this can tell which segment contributes to the main-thread stall of this open.
        HoverTrace.action("drawerOpen", phase: "begin")
        guard let host = ensureDrawerHost(limits: limits) else { return }
        let (panel, hosting) = host
        HoverTrace.action("drawerOpen", phase: "host")
        // Before the first measurement: that render captures the count the columns hold to.
        drawerShowing.begin(plateOnScreen: panel.isVisible)

        // First frame in place (one of the main causes of the owner's 2026-07-06 "not smooth"): measure the real size synchronously **before** orderFront,
        // so the first frame is already the final size, no longer "pops up at the old size -> instantly corrected". If no reasonable value can be measured, fall back to lastDrawerSize;
        // the later double-defer re-measure is still there as a fallback correction.
        panel.layoutIfNeeded()
        HoverTrace.action("drawerOpen", phase: "layout")
        let sync = hosting.fittingSize
        HoverTrace.action("drawerOpen", phase: "fitting")
        if Self.isPlausibleDrawerSize(sync) {
            lastDrawerSize = sync
        }
        let initialFrame = drawerTargetFrame(forCapsule: capsuleRef, size: lastDrawerSize, on: screen)
        lastDrawerTargetFrame = initialFrame

        panel.setFrame(initialFrame, display: false)
        syncDrawerArrow(after: .instant)
        // The arrow's position was only known with the frame: lay it out before the first show.
        hosting.layoutSubtreeIfNeeded()
        // Opening has no animation (owner 2026-09-04; reasons in `DrawerView` and `Docs/27`): go on screen directly at alpha 1.
        // Reopening mid-fade-out also goes straight back to 1; the `closeDrawer` completion has a `!drawerWantsOpen` guard and won't orderOut it.
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        HoverTrace.action("drawerOpen", phase: "ordered")
        pinOverlappingPanelIfNeeded(panel)
        HoverTrace.action("drawerOpen", phase: "shown")
        // After popping up, re-measure fittingSize and re-layout (instant, no sliding right after popup): a fallback correction when the synchronous measurement is off.
        DispatchQueue.main.async { [weak self] in
            HoverTrace.action("drawerOpen", phase: "turn1")
            DispatchQueue.main.async { [weak self] in
                HoverTrace.action("drawerOpen", phase: "turn2")
                self?.relayout(animated: false)
            }
        }

        drawerLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.dismissDrawerIfOutside()
            return event
        }
        drawerGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            self?.dismissDrawerIfOutside()
        }
    }

    /// Drawer positioning inputs: the capsule **target** frame (doesn't read live: the user may trigger the spring-open drawer during the taskbar width animation, Codex second review P1)
    /// and the grid's row/column limits = how many fit between above the capsule and the screen's top edge. Overflow scrolls inside the grid's base plate,
    /// and is never squeezed in by pressing the bottom edge down (otherwise pressing into the capsule/taskbar = overlap, Codex second review point 4).
    /// The top limit still avoids the menu bar / notch; the bottom anchor doesn't avoid the native Dock, so Command+Option+D or a side Dock doesn't push the drawer.
    private func drawerAnchor(on screen: NSScreen) -> (capsuleRef: NSRect, limits: StackGridLayout.Limits) {
        let screenGeometry = Self.screenGeometry(screen)
        let capsuleRef = lastCapsuleTargetFrame == .zero ? (capsulePanel?.frame ?? .zero) : lastCapsuleTargetFrame
        return (capsuleRef, PanelGeometry.drawerGridLimits(forCapsule: capsuleRef, on: screenGeometry, metrics: layoutMetrics))
    }

    /// Smaller than any plate means the host has not laid out yet, never a real size.
    static func isPlausibleDrawerSize(_ size: CGSize) -> Bool { size.width >= 160 && size.height >= 100 }

    /// The drawer's visible part for a window frame: plate plus arrow strip, without the 40pt
    /// transparent border.
    static func drawerPlateFrame(_ panelFrame: NSRect) -> CGRect {
        PanelGeometry.folderPopupPlateFrame(panelFrame: panelFrame)
    }

    // MARK: - Arrow

    /// The single writer of the drawer arrow's offset, keyed on what `setFrames` actually did
    /// with the drawer's frame — never on "layout ran" or the `animated` it was asked for:
    /// - `.animated`: sync from the two panels' live frames now and keep following every tick
    ///   until the animation's end (`animatedFramesUntil`), then land on the target. A plate
    ///   clamped at the screen edge moves against its capsule for the whole animation; writing
    ///   the end value at once takes the arrow up to ~64pt off the capsule.
    /// - `.unchanged`: nothing. Same targets does not mean the running animation is over.
    /// - `.instant`: stop following, write the target.
    /// Live frames here only draw the arrow; no panel is ever positioned from them.
    func syncDrawerArrow(after commit: FrameCommit) {
        switch commit {
        case .unchanged:
            return
        case .instant:
            stopDrawerArrowFollow()
            writeDrawerArrow(live: false)
        case .animated:
            writeDrawerArrow(live: true)
            guard drawerArrowFollowTimer == nil else { return }   // one timer; the deadline is read per tick
            let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.drawerArrowFollowTimer != nil else { return }
                    if CACurrentMediaTime() >= self.animatedFramesUntil {
                        self.stopDrawerArrowFollow()
                        self.writeDrawerArrow(live: false)
                    } else {
                        self.writeDrawerArrow(live: true)
                    }
                }
            }
            drawerArrowFollowTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func stopDrawerArrowFollow() {
        drawerArrowFollowTimer?.invalidate()
        drawerArrowFollowTimer = nil
    }

    private func writeDrawerArrow(live: Bool) {
        let capsule = live ? capsulePanel?.frame : lastCapsuleTargetFrame
        let drawer = live ? drawerPanel?.frame : lastDrawerTargetFrame
        guard let capsule, let drawer, capsule != .zero, drawer != .zero else { return }
        let offset = capsule.midX - drawer.midX   // the capsule's visible rect is inset symmetrically
        if drawerArrow.offsetFromCenter != offset { drawerArrow.offsetFromCenter = offset }
    }

    private func makeDrawerRootView(limits: StackGridLayout.Limits) -> DrawerRootView {
        DrawerRootView(limits: limits,
                       arrow: drawerArrow,
                       showing: drawerShowing,
                       // Next main-loop turn: `fittingSize` reads zero inside the SwiftUI update
                       // that reports the new size; `layoutPanels` measures it outside.
                       onPanelSizeChange: { [weak self] _ in
                           DispatchQueue.main.async { [weak self] in
                               guard let self, self.drawerWantsOpen else { return }
                               self.relayout(animated: true)
                           }
                       },
                       usesLiquidGlass: usesLiquidGlass,
                       isDrawerOpen: { [weak self] in self?.drawerPanel?.isVisible == true },
                       onPrimaryAction: { [weak self] in self?.closeDrawerAfterAction() },
                       onExternalDragHover: { [weak self] over in self?.externalDragHover(.drawer, over) },
                       onDropApplications: { [weak self] urls, placement in
                           self?.stashDroppedApplications(urls, placement: placement)
                       },
                       onDropApplicationIDs: { [weak self] ids, placement in
                           self?.stashDroppedApplicationIDs(ids, placement: placement)
                       },
                       runtime: runtime, drawerStore: drawerStore, messagingStore: messagingStore,
                       drawerOrderStore: drawerOrderStore, dragController: dragController,
                       keptAppStore: keptAppStore, runningApplicationStore: runningApplicationStore,
                       appMembershipController: appMembershipController)
    }

    /// The drawer panel + SwiftUI host, **built only once**; afterwards rootView is swapped only when the row/column limits change.
    /// Before 2026-09-04 a whole view tree was built fresh on every open, and the main-thread stall of 55-135ms landed on the start of the fade-in (the main cause of dropped frames on pop-open).
    private func ensureDrawerHost(limits: StackGridLayout.Limits) -> (NSPanel, NSHostingView<DrawerRootView>)? {
        if drawerPanel == nil {
            let panel = makeFloatingPanel(
                contentRect: NSRect(origin: .zero, size: lastDrawerSize),
                usesLiquidGlass: usesLiquidGlass
            )
            configurePanel(panel, backgroundColor: NSColor(white: 1.0, alpha: 0.0), appliesLevelOverride: false)
            drawerPanel = panel
        }
        guard let panel = drawerPanel else { return nil }

        if let hosting = drawerHosting {
            if drawerHostedLimits != limits {
                hosting.rootView = makeDrawerRootView(limits: limits)
                drawerHostedLimits = limits
            }
            return (panel, hosting)
        }

        let hosting = NSHostingView(rootView: makeDrawerRootView(limits: limits))
        drawerHostedLimits = limits
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.0).cgColor

        // Key point: use an ordinary NSView as the contentView, with the hosting view as an adaptive-fill subview; **don't make NSHostingView the contentView directly**.
        // Otherwise, when the content grows taller, macOS resizes the window by content size **anchored at the top edge, growing downward** (measured in logs: cur(y=24 h=194), top constant = 218),
        // and our layout only then corrects it to bottom-anchored growing upward (y=68); that back-and-forth fight = the real cause of what the owner saw as "first expands downward, then moves up"
        // (2026-06-22). An ordinary NSView doesn't pass subview content size to the window, so the window height is controlled only by layoutPanels/setFrames;
        // fittingSize reads the hosting view instead (stored in drawerContentHost).
        let container = NSView(frame: NSRect(origin: .zero, size: lastDrawerSize))
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        panel.contentView = container
        drawerContentHost = hosting
        drawerHosting = hosting
        return (panel, hosting)
    }

    /// After launch, warm up the drawer host (without orderFront and without touching any open/close state), so even the **first** open of this session needn't build it on the spot.
    /// Scheduled 1 second after the launch first-frame transaction, so it doesn't touch it. A closed drawer view staying alive is not new state (it already is under (3)(4)); drag callbacks all ask `isDrawerOpen()` first.
    func prewarmDrawerHost() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, !self.isSuspendedForPermissionLoss, self.drawerHosting == nil,
                  let mainPanel = self.dockPanel, self.capsulePanel != nil else { return }
            let anchor = self.drawerAnchor(on: self.panelCurrentScreen(panel: mainPanel))
            guard let host = self.ensureDrawerHost(limits: anchor.limits) else { return }
            let (panel, hosting) = host
            panel.layoutIfNeeded()
            _ = hosting.fittingSize
        }
    }

    /// Delayed close after clicking an app's primary action inside the drawer. Captures a token; at fire time it closes only after a triple check:
    /// 1. the token matches (excludes the drawer being reopened during the delay); 2. the drawer is still logically open; 3. no drag is in progress.
    func closeDrawerAfterAction() {
        let token = drawerActionCloseToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self,
                  self.drawerActionCloseToken == token,
                  self.drawerWantsOpen,
                  self.dragController.draggingPayload == nil else { return }
            self.closeDrawer()
        }
    }

    /// Interruptible fade-out close: immediately remove monitors, animate alpha -> 0, and in the completion confirm it still needs closing before orderOut (if it was reopened mid-fade, don't close).
    func closeDrawer() {
        guard drawerWantsOpen else { return }
        drawerWantsOpen = false
        setAutoHideInhibitor(.drawerOpen, active: false)
        drawerSpringOpened = false
        if let m = drawerLocalMonitor  { NSEvent.removeMonitor(m); drawerLocalMonitor  = nil }
        if let m = drawerGlobalMonitor { NSEvent.removeMonitor(m); drawerGlobalMonitor = nil }
        stopDrawerArrowFollow()
        guard let panel = drawerPanel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = PopoverAnimation.closeDuration
            ctx.timingFunction = PopoverAnimation.curve()
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.drawerWantsOpen else { return }   // reopened mid-fade -> don't orderOut
                panel.orderOut(nil)
                self.setDrawerRaised(false)
                self.drawerArrow.scrollGeneration &+= 1   // next open starts at the grid's top
                self.drawerShowing.end()
            }
        })
    }

    /// Fullscreen input is already paused from delivery by the tap, so we can't wait for the fade-out animation; state and monitors are wrapped up as usual and it's moved out of the WindowServer immediately.
    func closeDrawerImmediately() {
        guard drawerWantsOpen || drawerPanel?.isVisible == true else { return }
        drawerWantsOpen = false
        setAutoHideInhibitor(.drawerOpen, active: false)
        drawerSpringOpened = false
        if let monitor = drawerLocalMonitor {
            NSEvent.removeMonitor(monitor)
            drawerLocalMonitor = nil
        }
        if let monitor = drawerGlobalMonitor {
            NSEvent.removeMonitor(monitor)
            drawerGlobalMonitor = nil
        }
        stopDrawerArrowFollow()
        drawerPanel?.alphaValue = 0
        drawerPanel?.orderOut(nil)
        setDrawerRaised(false)
        drawerArrow.scrollGeneration &+= 1
        drawerShowing.end()
    }

    private func dismissDrawerIfOutside() {
        guard dragController.draggingPayload == nil else { return }   // don't close by mistake during a drag
        guard let drawer = drawerPanel, drawer.isVisible,
              let dock   = dockPanel else { return }
        let mouse = NSEvent.mouseLocation
        // The plate, not the window: its 40pt transparent border dismisses like any outside click.
        guard !Self.drawerPlateFrame(drawer.frame).contains(mouse),
              !dock.frame.contains(mouse),
              !(capsulePanel?.frame.contains(mouse) ?? false) else { return }
        closeDrawer()
    }

    func dragDropZones(for source: DragSource) -> [CGRect] {
        // Read the **target** frame: the live frame mid-animation is an intermediate value and would briefly misalign with visuals/landing spots (Codex second review P2). Fall back to live if the target isn't initialized.
        func target(_ stored: NSRect, _ live: NSRect?) -> NSRect? { stored != .zero ? stored : live }
        switch source {
        case .strip, .messaging:
            var zones: [CGRect] = []
            if let c = target(lastCapsuleTargetFrame, capsulePanel?.frame) {
                let inset = Self.shadowPadding - DrawerAppDrop.capsuleTolerance
                zones.append(c.insetBy(dx: inset, dy: inset))
            }
            if let drawer = drawerPanel, drawer.isVisible, let d = target(lastDrawerTargetFrame, drawer.frame) {
                // The drawer only grows upward: the drop zone's **top edge is pulled to the screen top**, and only the fixed bottom edge + width count, not changing as the panel grows or shrinks.
                // Otherwise "drop-zone size -> whether to insert a blank -> panel grows -> drop-zone size" forms a feedback loop, the blank flickers, and the panel animation is interrupted at high frequency
                // and overshoots downward (the real cause of the owner's 2026-06-21 "first expands downward, then moves up").
                let inset = Self.drawerPlateFrame(d)   // bottom = arrow tip, 3pt above the bar's top
                // The drop zone extends upward to the same top limit as the drawer: avoids the menu bar/notch, but not the native Dock.
                let top = Self.screenGeometry(panelCurrentScreen(panel: drawer)).topUsableY
                zones.append(CGRect(x: inset.minX, y: inset.minY, width: inset.width, height: max(inset.height, top - inset.minY)))
            }
            return zones
        case .drawer:
            guard let d = target(lastDockTargetFrame, dockPanel?.frame) else { return [] }
            return [d.insetBy(dx: Self.shadowPadding, dy: Self.shadowPadding)]
        case .folder:
            // A folder chip has no drop zone (with canExternalDrop=false it is never queried anyway; in-zone reordering / drag-out removal / drag-back opening
            // are all decided in DockStripView with FolderChipDropZone). Isolated from the strip/drawer stash semantics (review decision).
            return []
        }
    }

    // MARK: - Spring-loaded folder: hovering a dragged card over the capsule auto-opens the drawer

    /// A strip card hovering over the capsule (with the drawer closed the drop zone is only the capsule) for about 0.4s -> the drawer auto-opens, after which moving into the drawer connects to precise positioning;
    /// without waiting for it to open, releasing directly on the capsule still means "stash at the end". Moving away / releasing cancels the timer.
    func subscribeDragSpringLoad() {
        // Subscribe to globalLocation (not isOverDropZone): moving the cursor back onto the taskbar doesn't change isOverDropZone,
        // so position must be used to retract the drawer in real time (owner 2026-06-21: drag back to the taskbar to close it, move back to the capsule to open it again).
        dragSpringSubscription = dragController.pointerMoves
            .combineLatest(dragController.$draggingPayload)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] location, payload in
                self?.updateSpringLoad(location: location, payload: payload)
            }
    }

    func subscribeDragInhibitor() {
        dragInhibitorSubscription = dragController.$draggingPayload
            .map { $0 != nil }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] dragging in
                if dragging { self?.dismissWindowTitleTooltip(suppressCurrentUntilExit: true) }
                self?.setAutoHideInhibitor(.dragging, active: dragging)
            }
    }

    /// Visible-region hit test: the target frame takes the visible content area + 6pt hysteresis (prevents flip-flopping at the capsule/taskbar boundary).
    func springZone(_ target: NSRect) -> CGRect {
        target.insetBy(dx: Self.shadowPadding - 6, dy: Self.shadowPadding - 6)
    }

    /// The drawer's spring zone: its plate (the window has a 40pt transparent border, not the
    /// 20pt `springZone` assumes) with the same 6pt hysteresis.
    private func drawerSpringZone() -> CGRect {
        Self.drawerPlateFrame(lastDrawerTargetFrame).insetBy(dx: -6, dy: -6)
    }

    private func updateSpringLoad(location: CGPoint, payload: DragPayload?) {
        // Any drag that starts from the taskbar enjoys the spring for its whole duration (the flag is still honored after promotion to .drawer). Message-area chips share it too:
        // auto-opening the drawer on capsule hover is what gives a precise stash landing spot.
        if let p = payload, p.source == .strip || p.source == .messaging {
            dragOriginatedFromStrip = true; springDragBundleID = p.bundleID
        }

        // Release fallback: if a spring-opened drawer didn't take the card into the drawer -> retract. (Real-time hover mostly handles this already; this is the fallback.)
        if payload == nil {
            cancelSpringTimers()
            if drawerSpringOpened, let bid = springDragBundleID, !drawerStore.contains(bid) {
                closeDrawer()
            }
            drawerSpringOpened = false
            springDragBundleID = nil
            dragOriginatedFromStrip = false
            return
        }
        // Not started from the taskbar (a pure in-drawer drag / drawer -> taskbar move back): no spring.
        guard dragOriginatedFromStrip else { cancelSpringTimers(); return }

        let inDrawer  = drawerWantsOpen && lastDrawerTargetFrame != .zero && drawerSpringZone().contains(location)
        let inCapsule = lastCapsuleTargetFrame != .zero && springZone(lastCapsuleTargetFrame).contains(location)

        if inDrawer || inCapsule {
            // On the drawer or capsule -> cancel the retract; closed and on the capsule -> start the open-drawer timer.
            springCloseTimer?.invalidate(); springCloseTimer = nil
            if !drawerWantsOpen {
                if inCapsule && springOpenTimer == nil { armSpringOpenTimer() }
            } else {
                springOpenTimer?.invalidate(); springOpenTimer = nil      // already open -> keep
            }
        } else {
            // Left drawer+capsule (on the taskbar or the gap) -> cancel the pending open; if open, **delay** the retract (owner 2026-06-22).
            springOpenTimer?.invalidate(); springOpenTimer = nil
            if drawerWantsOpen && springCloseTimer == nil { armSpringCloseTimer() }
        }
    }

    func cancelSpringTimers() {
        springOpenTimer?.invalidate(); springOpenTimer = nil
        springCloseTimer?.invalidate(); springCloseTimer = nil
    }

    private func armSpringOpenTimer() {
        // .common mode: during a drag the main run loop is in event-tracking mode, and scheduledTimer (default mode) doesn't fire during a drag.
        let timer = Timer(timeInterval: ExternalDragSpringLoad.openDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.springOpenDrawer() }
        }
        RunLoop.main.add(timer, forMode: .common)
        springOpenTimer = timer
    }

    /// Retract only about 0.35s after leaving drawer+capsule (briefly brushing the taskbar/gap doesn't retract). Close for real only if, at the deadline, still dragging, still open, still outside.
    private func armSpringCloseTimer() {
        let timer = Timer(timeInterval: ExternalDragSpringLoad.closeDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.springCloseDrawerIfStillOutside() }
        }
        RunLoop.main.add(timer, forMode: .common)
        springCloseTimer = timer
    }

    private func springCloseDrawerIfStillOutside() {
        springCloseTimer = nil
        guard dragOriginatedFromStrip, drawerWantsOpen else { return }
        let loc = dragController.globalLocation
        let inDrawer  = lastDrawerTargetFrame != .zero && drawerSpringZone().contains(loc)
        let inCapsule = lastCapsuleTargetFrame != .zero && springZone(lastCapsuleTargetFrame).contains(loc)
        guard !inDrawer, !inCapsule else { return }   // back in the drawer/capsule -> don't close
        closeDrawer()
    }

    private func springOpenDrawer() {
        springOpenTimer = nil
        // At the deadline, if still dragging, still hovering the capsule, and the drawer still closed -> pop open. Use dragOriginatedFromStrip + re-test the capsule hit (not
        // isOverDropZone: after promotion to .drawer it refers to the taskbar zone, and is false when hovering the capsule, which would wrongly block reopening. Owner 2026-06-22).
        let loc = dragController.globalLocation
        let inCapsule = lastCapsuleTargetFrame != .zero && springZone(lastCapsuleTargetFrame).contains(loc)
        guard dragController.draggingPayload != nil,
              dragOriginatedFromStrip,
              inCapsule,
              !drawerWantsOpen else { return }
        openDrawer()
        drawerSpringOpened = true   // openDrawer set it to false; mark here that this open was a spring open
        dragController.bringCarrierToFront()
    }
}
