import AppKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Gesture monitor (force click / middle button → content preview)
//
// Attach a **local** NSEvent monitor in the strip's view tree: trackpad force click (.pressure pressing into stage 2, debounced so it fires only once
// at the moment of entering stage 2) + mouse middle button (.otherMouseDown button 2) → callback with global screen coordinates, handed to
// handleGesturePreview for the hit-test reverse lookup. The monitor only observes and doesn't consume (return e), with zero interference to left click / folder dragging;
// the spike (2026-07-09) verified that force click doesn't trigger left-click actions, so there is no conflict.
struct GestureMonitorInstaller: NSViewRepresentable {
    let onGesture: (CGPoint) -> Void

    func makeNSView(context: Context) -> NSView {
        context.coordinator.onGesture = onGesture
        context.coordinator.start()
        return NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onGesture = onGesture   // refresh the closure, capturing the latest chip frames
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var onGesture: ((CGPoint) -> Void)?
        private var pressureMonitor: Any?
        private var middleMonitor: Any?
        private var lastStage = 0

        func start() {
            pressureMonitor = NSEvent.addLocalMonitorForEvents(matching: .pressure) { [weak self] e in
                guard let self else { return e }
                if e.stage == 2 && self.lastStage < 2 { self.onGesture?(NSEvent.mouseLocation) }
                self.lastStage = e.stage
                return e
            }
            middleMonitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { [weak self] e in
                if e.buttonNumber == 2 { self?.onGesture?(NSEvent.mouseLocation) }
                return e
            }
        }

        func stop() {
            if let m = pressureMonitor { NSEvent.removeMonitor(m) }
            if let m = middleMonitor { NSEvent.removeMonitor(m) }
            pressureMonitor = nil
            middleMonitor = nil
        }
    }
}
