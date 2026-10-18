import AppKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Whole-strip pointer tracking area

/// Reference box for the last pointer position. Put into `@State` only to survive across bodies; **mutating it doesn't trigger a recompute**,
/// which is exactly what we want -- recomputing the whole body on every pointer move is too expensive; recomputation happens only when the owner actually changes.
final class PointerBox {
    var value: CGPoint?
}

/// One `NSTrackingArea` covering the whole taskbar, reporting the pointer position upward. Who is hovered is computed by the pure decision
/// `StripHoverResolution` -- **this is the only hover source for the whole strip**; each card no longer attaches its own `.onHover`
///(missed cells + boundary-band direction; see that type for the cause).
///
/// **Enter/exit use the tracking area; position is polled per frame by ourselves.** The first version relied entirely on the tracking area's `.mouseMoved`, which proved a dead end:
/// a synthetic 34-step sweep reported only **6** times, with 5 of them bunched into the last 80ms (2026-08-17).
/// The reason is that these panels are all `.nonactivatingPanel` and never become the key window, while AppKit only guarantees to deliver
/// mouse-move events to the key window -- `acceptsMouseMovedEvents` can't rescue it either (tried).
/// Enter / exit are reliable though (SwiftUI's `.onHover(true)` has always relied on it).
///
/// So: `mouseEntered` starts a 60Hz timer reading `NSEvent.mouseLocation`, and when the pointer leaves this view
/// it reports `nil` and stops the timer. **It exists only while the pointer is over the taskbar**, not as permanent polling; a beat where the position is unchanged is skipped outright,
/// and `@State` isn't written when ownership is unchanged, so resting on the strip without moving costs nothing.
///
/// This is not the permanent global `.mouseMoved` monitor banned by AGENTS: what that bans is `addGlobalMonitorForEvents`
///(an event tap; all system mouse events pass through our process first, and when we pop a menu ourselves we'd be slowed by 100ms). A timer is not a tap.
///
/// Two more load-bearing points:
/// - `.activeAlways`: the panel is never the key window, and the default `.activeInKeyWindow` doesn't even receive enter/exit.
/// - `hitTest` returns `nil`: it is a `.background`, only observing and never eating clicks.
struct StripPointerTracker: NSViewRepresentable {
    /// Screen coordinates (bottom-left); `nil` = the pointer left the taskbar.
    let onMove: (CGPoint?) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onMove = onMove
        return view
    }

    func updateNSView(_ nsView: TrackingView, context: Context) {
        nsView.onMove = onMove   // refresh the closure, capturing the latest @State write entry
    }

    static func dismantleNSView(_ nsView: TrackingView, coordinator: ()) {
        nsView.stopPolling()
        nsView.onMove = nil
    }

    final class TrackingView: NSView {
        /// Turn off polling and keep only the tracking area's own `.mouseMoved` (`DOCK_STRIP_HOVER_POLL=0`).
        /// Keeping it is the only way to answer "is polling actually necessary" -- it was settled by this A/B on 2026-08-17.
        static let pollingEnabled =
            DebugSwitch.stripHoverPoll.isEnabled(in: ProcessInfo.processInfo.environment)

        var onMove: ((CGPoint?) -> Void)?
        private var area: NSTrackingArea?
        private var poll: Timer?
        private var lastReported: CGPoint?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { stopPolling() }
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let area { removeTrackingArea(area) }
            let next = NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(next)
            area = next
        }

        override func mouseEntered(with event: NSEvent) { pointerEvent() }
        override func mouseMoved(with event: NSEvent) { pointerEvent() }
        override func mouseDragged(with event: NSEvent) { pointerEvent() }

        /// The tracking area did deliver an event: report the position as usual (this path always runs), and start the timer along the way.
        private func pointerEvent() {
            report(NSEvent.mouseLocation)
            guard Self.pollingEnabled else { return }
            startPolling()
        }

        /// The tracking area's exit is only **one** of the wind-down paths: it misses when the pointer leaves quickly
        ///(the reason for the existence of the "bubble watchdog" in AGENTS). Polling detects out-of-bounds more reliably,
        /// so this merely stops the timer one step early.
        override func mouseExited(with event: NSEvent) { leave() }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        private func startPolling() {
            guard poll == nil else { return }
            tick()
            // 60Hz: that's the screen's refresh rate, and denser would be invisible. During a 2400pt/s sweep each 42pt cell
            // is about 17.5ms, a cadence that misses no cell.
            let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                self?.tick()
            }
            poll = timer
            RunLoop.main.add(timer, forMode: .common)
        }

        func stopPolling() {
            poll?.invalidate()
            poll = nil
        }

        private func leave() {
            stopPolling()
            guard lastReported != nil else { return }
            lastReported = nil
            onMove?(nil)
        }

        private func tick() {
            guard let window, window.isVisible else {
                leave()
                return
            }
            let location = NSEvent.mouseLocation
            guard window.convertToScreen(convert(bounds, to: nil)).contains(location) else {
                leave()
                return
            }
            report(location)
        }

        /// A beat where the position is unchanged is skipped outright: resting on the strip = zero overhead.
        private func report(_ location: CGPoint) {
            guard location != lastReported else { return }
            lastReported = location
            onMove?(location)
        }
    }
}
