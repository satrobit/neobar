import AppKit
import ApplicationServices
import Combine
import QuartzCore
import SwiftUI
import os

// PanelCoordinator · window-title tooltip: display / grace period / watchdog / mouse monitoring of the dedicated panel.
// Split out of PanelCoordinator.swift as an extension on 2026-09-05; moved only, not changed.
extension PanelCoordinator {
    func handleWindowTitleTooltipEvent(_ event: WindowTitleTooltipEvent) {
        switch event {
        case let .update(request):
            // **Ownership is no longer determined here.** Requests now have a single source: the tracking area covering the whole strip
            // computes them from the pointer position (`StripHoverResolution`), and when one is issued the pointer is necessarily on that card.
            // Guards were only needed back when each card issued its own request (a stuck `isHovering` would steal the panel);
            // the reasoning is kept in the comment on `WindowTitleTooltipRequest`.
            if windowTitleTooltipSuppressedChipID == request.chipID { return }
            windowTitleTooltipSuppressedChipID = nil
            windowTitleTooltipSuppressedRequest = nil
            cancelWindowTitleTooltipLinger()

            HoverTrace.hover(chipID: request.chipID, entered: true)
            windowTitleTooltipRequest = request
            installWindowTitleTooltipMouseMonitors()
            // Change text and position immediately: no debounce, no fade-in (see the comment on the constant above).
            presentWindowTitleTooltip(request)

        case let .exit(chipID):
            HoverTrace.hover(chipID: chipID, entered: false)
            if windowTitleTooltipSuppressedChipID == chipID {
                windowTitleTooltipSuppressedChipID = nil
                windowTitleTooltipSuppressedRequest = nil
            }
            guard windowTitleTooltipRequest?.chipID == chipID else { return }
            // `.exit` now has a crisp meaning: **the pointer is not on any card** -- the wide gap at the section divider,
            // the margins at both ends of the strip, or it has already left the strip. The narrow 2pt gap between cards never gets here:
            // the ownership logic bridges it (`StripHoverResolution`), so "A -> empty -> B" no longer exists at the source.
            //
            // A 90ms grace period is still kept: no flicker when crossing the divider, and the neighbor's `.update` takes over as soon as it arrives.
            // If the pointer is no longer on the strip, dismiss immediately rather than leaving a stale tooltip.
            if isPointInsideTaskbarPanels(NSEvent.mouseLocation) {
                scheduleWindowTitleTooltipLinger()
            } else {
                dismissWindowTitleTooltip()
            }
        }
    }

    /// Dismiss the tooltip later; if another chip's `.update` arrives within the grace period it takes over this panel directly (see `windowTitleTooltipLingerDelay`).
    private func scheduleWindowTitleTooltipLinger() {
        cancelWindowTitleTooltipLinger()
        let timer = Timer(timeInterval: Self.windowTitleTooltipLingerDelay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.windowTitleTooltipLingerTimer = nil
                self.dismissWindowTitleTooltip()
            }
        }
        windowTitleTooltipLingerTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func cancelWindowTitleTooltipLinger() {
        windowTitleTooltipLingerTimer?.invalidate()
        windowTitleTooltipLingerTimer = nil
    }

    /// Watchdog while the tooltip is on screen: dismiss it once the pointer leaves the panels that can pop a tooltip.
    ///
    /// After the rework it has only one role, **fallback**: who owns the tooltip on the strip is computed live by the whole-strip tracking area
    /// (`StripHoverResolution`), and its own `mouseExited` is the normal path for dismissing the tooltip.
    /// But when the panel is `orderOut`ed (edge-hidden, entering full screen) or a chip is pulled out from under the pointer,
    /// the tracking area does not guarantee a final exit; this 10Hz recheck then keeps the tooltip from hanging forever
    /// (the owner has reported "sometimes the tooltip stays after the mouse moves away").
    ///
    /// **The check uses the whole panel, not the anchor rectangle**: ownership within the strip is left to the tracking area, and judging again by the anchor here
    /// would only fight with it -- when the pointer rests on a divider or narrow gap the two reach different conclusions, and the tooltip would be dismissed prematurely.
    ///
    /// Deliberately uses a timer that **lives only while the tooltip is visible**, rather than a resident global `.mouseMoved` monitor:
    /// the latter is an event tap that slows mouse events when our own menu pops up (AGENTS "Menus, Panels, And Screens"
    /// is where that 100ms stickiness came from), and one tooltip is not worth opening another.
    func startWindowTitleTooltipWatchdog() {
        guard windowTitleTooltipWatchdog == nil else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.windowTitleTooltipPanel?.isVisible == true,
                      self.windowTitleTooltipRequest != nil else {
                    self.stopWindowTitleTooltipWatchdog()
                    return
                }
                guard !self.isPointInsideTaskbarPanels(NSEvent.mouseLocation) else { return }
                self.dismissWindowTitleTooltip()
            }
        }
        windowTitleTooltipWatchdog = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Whether the pointer is still on "the panels that can pop a tooltip" (the strip itself + capsule + any open drawer).
    /// The whole window frame is enough: the only extra area it counts is the 20pt transparent shadow margin, and the grace period dismisses it on expiry anyway.
    private func isPointInsideTaskbarPanels(_ point: CGPoint) -> Bool {
        if let dock = dockPanel, dock.frame.contains(point) { return true }
        if let capsule = capsulePanel, capsule.frame.contains(point) { return true }
        // The drawer's window carries 40pt of transparent border: its plate is what counts.
        if drawerWantsOpen, let drawer = drawerPanel,
           PanelGeometry.folderPopupPlateFrame(panelFrame: drawer.frame).contains(point) { return true }
        return false
    }

    private func stopWindowTitleTooltipWatchdog() {
        windowTitleTooltipWatchdog?.invalidate()
        windowTitleTooltipWatchdog = nil
    }

    private func presentWindowTitleTooltip(_ request: WindowTitleTooltipRequest) {
        guard request.anchorVisibleRect != .zero else { return }
        onAccessoryWillOpen?(self, .tooltip)
        let traceStart = CACurrentMediaTime()
        let traceCold = windowTitleTooltipPanel?.isVisible != true
        defer { HoverTrace.present(chipID: request.chipID, cold: traceCold,
                                   elapsed: CACurrentMediaTime() - traceStart) }
        let panel: NSPanel
        if let existing = windowTitleTooltipPanel {
            panel = existing
        } else {
            let created = makeFloatingPanel(contentRect: .zero, usesLiquidGlass: usesLiquidGlass)
            configurePanel(created, backgroundColor: .clear, appliesLevelOverride: false)
            created.ignoresMouseEvents = true
            windowTitleTooltipPanel = created
            panel = created
        }

        // The bubble keeps the native size at every bar height, as the native Dock's label does.
        let style = WindowTitleTooltipStyle.native
        let contentHost: ManualPanelHost
        if let hosting = windowTitleTooltipHosting, let existingHost = windowTitleTooltipHost {
            hosting.rootView = WindowTitleTooltipView(title: request.title, style: style,
                                                    usesLiquidGlass: usesLiquidGlass)
            contentHost = existingHost
        } else {
            let hosting = NSHostingView(rootView: WindowTitleTooltipView(title: request.title, style: style,
                                                          usesLiquidGlass: usesLiquidGlass))
            hosting.wantsLayer = true
            hosting.layer?.backgroundColor = NSColor.clear.cgColor
            contentHost = ManualPanelHost(contentView: hosting, in: panel)
            windowTitleTooltipHosting = hosting
            windowTitleTooltipHost = contentHost
        }
        panel.layoutIfNeeded()
        let size = contentHost.fittingSize
        guard size.width > 0, size.height > 0 else { return }

        let anchorPoint = CGPoint(x: request.anchorVisibleRect.midX, y: request.anchorVisibleRect.midY)
        // **The anchor must be on the screen where the strip lives.** All chips that pop tooltips live in the strip / drawer,
        // and the two are always on the same screen; an anchor on another screen can only mean that card's cached screen rectangle is stale (the panel changed screens).
        // In that case better to skip the tooltip for this frame -- `ScreenRectReader` now reports again when the window moves,
        // so the next frame is correct. Actually popping it up is the owner's reported "tooltip appears on the screen without a strip".
        let dockScreen = dockPanel.map { panelCurrentScreen(panel: $0) }
        if let dockScreen, !dockScreen.frame.contains(anchorPoint) { return }
        let screen = NSScreen.screens.first(where: { $0.frame.contains(anchorPoint) })
            ?? dockScreen
            ?? NSScreen.main
            ?? NSScreen.screens[0]
        let target = PanelGeometry.windowTitleTooltipTargetFrame(
            anchorVisibleRect: request.anchorVisibleRect,
            size: size,
            tipGap: style.tipGap,
            on: Self.screenGeometry(screen)
        )
        panel.setFrame(target, display: true)

        // **No fade-in.** Measured: input to tooltip on screen takes only 2.9-9.5ms, so the pipeline is already instant;
        // what the owner meant by "not as crisp as native" is the **softness** that this 0.1s fade-in brings, not slowness
        // (the native Dock's app name appears directly). Likewise dismissal is direct too, see the `.exit` branch.
        panel.alphaValue = 1
        // A bar card's bubble can overlap the open drawer's bottom row: never under a raised one.
        var level = drawerWantsOpen ? max(drawerPanel?.level ?? .floating, .floating) : .floating
        // Over a folder popup flying back into its chip, as the native Dock's label is.
        if let exiting = exitingPopupSession?.panel, exiting.isVisible, exiting.level >= level {
            level = NSWindow.Level(rawValue: exiting.level.rawValue + 1)
        }
        if panel.level != level { panel.level = level }
        if !panel.isVisible { panel.orderFrontRegardless() }
        pinOverlappingPanelIfNeeded(panel)
        startWindowTitleTooltipWatchdog()
    }

    /// **Idempotent**: called on every `.update` (switching chips no longer dismisses first and then reinstalls), and installing repeatedly would leak the old monitor.
    private func installWindowTitleTooltipMouseMonitors() {
        guard windowTitleTooltipLocalMonitor == nil, windowTitleTooltipGlobalMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        windowTitleTooltipLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.dismissWindowTitleTooltipOnMouseDown(event.type)
            return event
        }
        windowTitleTooltipGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.dismissWindowTitleTooltipOnMouseDown(event.type)
        }
    }

    /// A press on a pinned folder keeps its name, as the native Dock's stack label does: the
    /// popup's first frame takes it off (`folderPopupWillShow`), its close brings it back.
    private func dismissWindowTitleTooltipOnMouseDown(_ type: NSEvent.EventType) {
        if type == .leftMouseDown, let request = windowTitleTooltipRequest,
           request.chipID.hasPrefix(Self.folderChipIDPrefix),
           request.anchorVisibleRect.contains(NSEvent.mouseLocation) { return }
        dismissWindowTitleTooltip(suppressCurrentUntilExit: true)
    }

    static let folderChipIDPrefix = "folder-"

    /// The folder's popup is on screen: its name goes until the pointer leaves or the popup closes.
    func folderPopupWillShow(path: String) {
        guard windowTitleTooltipRequest?.chipID == Self.folderChipIDPrefix + path else { return }
        dismissWindowTitleTooltip(suppressCurrentUntilExit: true)
    }

    /// The folder's popup started closing with the pointer still on its chip: the name is back on
    /// the close's first frame, over the items flying in.
    func folderPopupWillClose(path: String) {
        guard let request = windowTitleTooltipSuppressedRequest,
              request.chipID == Self.folderChipIDPrefix + path,
              windowTitleTooltipSuppressedChipID == request.chipID,
              request.anchorVisibleRect.contains(NSEvent.mouseLocation) else { return }
        windowTitleTooltipSuppressedChipID = nil
        windowTitleTooltipSuppressedRequest = nil
        windowTitleTooltipRequest = request
        installWindowTitleTooltipMouseMonitors()
        presentWindowTitleTooltip(request)
    }

    func dismissWindowTitleTooltip(suppressCurrentUntilExit: Bool = false) {
        if suppressCurrentUntilExit, let request = windowTitleTooltipRequest {
            windowTitleTooltipSuppressedChipID = request.chipID
            windowTitleTooltipSuppressedRequest = request
        }
        cancelWindowTitleTooltipLinger()
        stopWindowTitleTooltipWatchdog()
        windowTitleTooltipRequest = nil
        if let monitor = windowTitleTooltipLocalMonitor {
            NSEvent.removeMonitor(monitor)
            windowTitleTooltipLocalMonitor = nil
        }
        if let monitor = windowTitleTooltipGlobalMonitor {
            NSEvent.removeMonitor(monitor)
            windowTitleTooltipGlobalMonitor = nil
        }
        windowTitleTooltipPanel?.alphaValue = 0
        windowTitleTooltipPanel?.orderOut(nil)
    }
}
