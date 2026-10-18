import AppKit

// PanelCoordinator · spring-loading the drawer for an app dragged from outside the app (Finder).
// The decision is the pure `ExternalDragSpringLoad`; this file turns its effects into the shared
// spring timer slots and the drawer's open / close.
extension PanelCoordinator {
    /// A drop receiver (`DrawerAppDropReceiver` on the capsule or the drawer plate) was entered or
    /// left by a drag carrying an app bundle.
    func externalDragHover(_ surface: ExternalDragSpringLoad.Surface, _ over: Bool) {
        // A card drag of our own never overlaps an AppKit session, but if the two ever meet the
        // bar's own spring-load keeps the drawer.
        guard dragController.draggingPayload == nil else { return }
        applyExternalSpring(.hover(surface, over))
    }

    /// Either receiver accepted the drop (`stashDroppedApplications` runs separately).
    func externalDragDropped() {
        applyExternalSpring(.dropped)
    }

    private func applyExternalSpring(_ event: ExternalDragSpringLoad.Event) {
        let effects = ExternalDragSpringLoad.reduce(&externalDragSpring, event, drawerOpen: drawerWantsOpen)
        for effect in effects {
            switch effect {
            case .armOpenTimer:
                springOpenTimer?.invalidate()
                springOpenTimer = armSpringTimer(after: ExternalDragSpringLoad.openDelay) { [weak self] in
                    self?.springOpenTimer = nil
                    self?.applyExternalSpring(.openTimerFired)
                }
            case .cancelOpenTimer:
                springOpenTimer?.invalidate(); springOpenTimer = nil
            case .armCloseTimer:
                springCloseTimer?.invalidate()
                springCloseTimer = armSpringTimer(after: ExternalDragSpringLoad.closeDelay) { [weak self] in
                    self?.springCloseTimer = nil
                    self?.applyExternalSpring(.closeTimerFired)
                }
            case .cancelCloseTimer:
                springCloseTimer?.invalidate(); springCloseTimer = nil
            case .openDrawer:
                HoverTrace.action("extspring", phase: "open")
                openDrawer()
                drawerSpringOpened = true   // `openDrawer` resets it; this open was the spring's
            case .closeDrawer:
                HoverTrace.action("extspring", phase: "close")
                closeDrawer()
            }
        }
        // Spring-opened or already open: the drag may come out of a system panel above
        // `.floating`. Held until the drawer closes, so the landing stays in sight after the drop.
        if externalDragSpring.isOver, drawerWantsOpen { setDrawerRaised(true) }
    }

    /// The drawer's only level writer: `PanelLevel.raisedDrawer` for a drag from outside,
    /// `.floating` otherwise (every open starts there, every close returns there).
    func setDrawerRaised(_ raised: Bool) {
        guard let panel = drawerPanel else { return }
        let level: NSWindow.Level = raised ? PanelLevel.raisedDrawer : .floating
        guard panel.level != level else { return }
        panel.level = level
        if panel.isVisible { pinOverlappingPanelIfNeeded(panel) }
    }

    /// `.common` mode: while a drag session runs, the main run loop is in event tracking and a
    /// default-mode timer never fires.
    private func armSpringTimer(after delay: TimeInterval, _ fire: @escaping () -> Void) -> Timer {
        let timer = Timer(timeInterval: delay, repeats: false) { _ in
            Task { @MainActor in fire() }
        }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}
