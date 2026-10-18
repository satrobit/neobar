import AppKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Mouse wheel horizontal strip scrolling

struct WheelScrollInterceptorRepresentable: NSViewRepresentable {
    func makeNSView(context: Context) -> WheelScrollInterceptorView {
        WheelScrollInterceptorView()
    }

    func updateNSView(_ nsView: WheelScrollInterceptorView, context: Context) {
        nsView.resolveScrollViewIfNeeded()
    }
}

final class WheelScrollInterceptorView: NSView {
    /// Diagnostics, off by default: only printed with `DOCK_STRIP_WHEEL_TRACE=1`.
    private static let trace = DebugSwitch.stripWheelTrace.isEnabled(in: ProcessInfo.processInfo.environment)

    private weak var scrollView: NSScrollView?
    private var reportedMissingScrollView = false

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        resolveScrollViewIfNeeded()
    }

    override func layout() {
        super.layout()
        resolveScrollViewIfNeeded()
    }

    /// **`point` is a point in the parent view's coordinate system**, so the decision must go through `super.hitTest` and must not be compared against its own
    /// `bounds` (`MenuHostNSView` uses the same pattern). The bar has a 20pt shadow margin on the outside, and comparing with bounds
    /// would shift everything, leaving a whole band of the bar unable to receive the wheel.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard super.hitTest(point) != nil,
              let event = NSApp.currentEvent,
              event.type == .scrollWheel,
              StripWheelScroll.horizontalStep(for: Self.input(from: event)) != nil,
              overflowExtent() > 0 else {
            return nil
        }
        return self
    }

    /// When "Reverse mouse wheel direction" is on, **nothing needs to be done**: that tap is inserted at the head of the session, and what's received here
    /// is already the reversed delta, consistent with what other apps see -- so the pan direction on the bar naturally reverses along with it.
    override func scrollWheel(with event: NSEvent) {
        let input = Self.input(from: event)
        guard let delta = StripWheelScroll.horizontalStep(for: input),
              let scrollView = resolveScrollViewIfNeeded(),
              let documentView = scrollView.documentView else {
            super.scrollWheel(with: event)
            return
        }

        let clipView = scrollView.contentView
        let maxX = max(0, documentView.bounds.width - clipView.bounds.width)
        let currentX = clipView.bounds.origin.x
        let nextX = min(max(currentX + delta, 0), maxX)
        if Self.trace {
            print("[stripwheel] precise=\(input.hasPreciseDeltas) dx=\(input.deltaX) dy=\(input.deltaY)"
                + " inverted=\(input.isDirectionInverted) step=\(delta) x=\(currentX)->\(nextX) maxX=\(maxX)")
        }
        guard maxX > 0, nextX != currentX else { return }

        clipView.scroll(to: NSPoint(x: nextX, y: clipView.bounds.origin.y))
        scrollView.reflectScrolledClipView(clipView)
    }

    private static func input(from event: NSEvent) -> StripWheelScroll.Input {
        StripWheelScroll.Input(
            deltaX: event.scrollingDeltaX,
            deltaY: event.scrollingDeltaY,
            hasPreciseDeltas: event.hasPreciseScrollingDeltas,
            isDirectionInverted: event.isDirectionInvertedFromDevice
        )
    }

    /// How many more pt it can scroll right. `0` = no overflow (or the scrollView hasn't been resolved yet), in which case events are never claimed.
    ///
    /// **Call only when a scroll event is really received** (the event type has already been filtered in `hitTest`) -- the warning for "can't find
    /// `NSScrollView`" is hung here so it won't be falsely triggered by the normal empty lookup early at startup when
    /// "SwiftUI hasn't built it yet".
    private func overflowExtent() -> CGFloat {
        guard let scrollView = resolveScrollViewIfNeeded(),
              let documentView = scrollView.documentView else {
            reportMissingScrollViewOnce()
            return 0
        }
        return max(0, documentView.bounds.width - scrollView.contentView.bounds.width)
    }

    /// This feature's **only silent failure point**: if SwiftUI's `ScrollView` is ever no longer hosted by `NSScrollView`,
    /// the whole horizontal scroll would die without a sound, not even a line of log. Reported only once.
    private func reportMissingScrollViewOnce() {
        guard !reportedMissingScrollView else { return }
        reportedMissingScrollView = true
        print("[stripwheel] 找不到 NSScrollView —— 任务条横向滚动已失效"
            + "（SwiftUI 的 ScrollView 可能不再由 NSScrollView 承载）")
    }

    @discardableResult
    func resolveScrollViewIfNeeded() -> NSScrollView? {
        if let scrollView, scrollView.window != nil {
            return scrollView
        }

        var ancestor = superview
        while let candidate = ancestor {
            if let found = findScrollView(in: candidate) {
                scrollView = found
                return found
            }
            ancestor = candidate.superview
        }
        scrollView = nil
        return nil
    }

    private func findScrollView(in root: NSView) -> NSScrollView? {
        guard root !== self else { return nil }
        if let scrollView = root as? NSScrollView {
            return scrollView
        }
        for subview in root.subviews {
            if let found = findScrollView(in: subview) {
                return found
            }
        }
        return nil
    }
}

extension View {
    /// macOS 14's `defaultScrollAnchor(.leading)` is unavailable on older systems; a horizontal ScrollView already starts from
    /// the leading edge, so older systems just use the default (explicit anchoring only on 14+, preserving the original behavior).
    @ViewBuilder
    func compatLeadingScrollAnchor() -> some View {
        if #available(macOS 14.0, *) {
            self.defaultScrollAnchor(.leading)
        } else {
            self
        }
    }
}
