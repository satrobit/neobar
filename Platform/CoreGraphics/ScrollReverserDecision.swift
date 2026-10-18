import Foundation

/// The six direction fields of one scroll-wheel event (the three axis1/axis2 groups of `CGEventField`).
/// A pure value type: the reversal logic must be unit-testable, and the side effects of reading/writing CGEvent stay in `ScrollReverserMonitor`.
struct ScrollWheelDeltas: Equatable {
    var axis1: Int64
    var axis2: Int64
    var pointAxis1: Int64
    var pointAxis2: Int64
    var fixedAxis1: Double
    var fixedAxis2: Double
}

/// Pure decision for "globally reverse the mouse wheel" (setting "General · Reverse mouse wheel direction", off by default).
enum ScrollReverserDecision {
    static func isEnabled(
        settingEnabled: Bool,
        environment: [String: String]
    ) -> Bool {
        settingEnabled && DebugSwitch.scrollReverser.isEnabled(in: environment)
    }

    /// Reverses only discrete wheels (`scrollWheelEventIsContinuous == 0` = a mouse wheel with notches).
    /// Trackpads, Magic Mouse, and mice with smooth scrolling on send continuous events, which are always passed through --
    /// their direction is governed by the system's "natural scrolling", and reversing along would flip the trackpad too.
    /// Momentum scrolling needs no separate check: momentum appears only on continuous events, and is already covered by this rule.
    static func shouldReverse(isContinuous: Bool) -> Bool {
        !isContinuous
    }

    static func reversed(_ deltas: ScrollWheelDeltas) -> ScrollWheelDeltas {
        ScrollWheelDeltas(
            axis1: negated(deltas.axis1),
            axis2: negated(deltas.axis2),
            pointAxis1: negated(deltas.pointAxis1),
            pointAxis2: negated(deltas.pointAxis2),
            fixedAxis1: -deltas.fixedAxis1,
            fixedAxis2: -deltas.fixedAxis2
        )
    }

    /// Negating `Int64.min` overflows and crashes. Real wheel deltas are single digits, so this is purely defensive --
    /// but this tap receives **system-wide** scroll events, so the defense has to be absolute.
    private static func negated(_ value: Int64) -> Int64 {
        value == .min ? .max : -value
    }
}
