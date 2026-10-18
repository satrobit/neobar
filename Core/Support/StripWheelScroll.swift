import CoreGraphics

/// Pure decision logic for horizontal scrolling of the taskbar: converts a scroll event into a horizontal displacement within the strip.
///
/// Why it is needed: when the taskbar can't fit, it scrolls via a horizontal `ScrollView`, and a horizontal ScrollView **doesn't respond to
/// vertical swipes** at all. Originally only discrete wheels were taken over (`hasPreciseScrollingDeltas == false`), so trackpads, Magic Mouse, and
/// mice with smooth scrolling enabled (Logitech Options, etc.), all of which emit continuous events (see
/// `Docs/27-product-decisions.md` "Reverse Mouse Wheel"), had vertical swipes vanish without a trace (issue #14).
///
/// Side effects (reading `NSEvent`, writing `NSScrollView`) stay in the interception view of `DockStripView`.
enum StripWheelScroll {
    /// How many pt one notch of a discrete wheel converts to. A finalized feel; it must be identical before and after changes.
    static let wheelSpeed: CGFloat = 56
    /// Upper bound of a single step of a discrete wheel. The delta of a fast flick can be huge, and without a cap it would fly straight to the end.
    static let maxStep: CGFloat = 120

    /// Pure input distilled from `NSEvent`.
    struct Input: Equatable {
        var deltaX: CGFloat
        var deltaY: CGFloat
        /// `NSEvent.hasPreciseScrollingDeltas`: true = a continuous event (trackpad / Magic Mouse / smooth wheel).
        var hasPreciseDeltas: Bool
        /// `NSEvent.isDirectionInvertedFromDevice`: i.e. whether the system "natural scrolling" is in effect for that device.
        /// **Taken from the event itself rather than reading `com.apple.swipescrolldirection`**: correct per device,
        /// and the hot event path no longer does UserDefaults reads.
        var isDirectionInverted: Bool

        init(deltaX: CGFloat, deltaY: CGFloat, hasPreciseDeltas: Bool, isDirectionInverted: Bool) {
            self.deltaX = deltaX
            self.deltaY = deltaY
            self.hasPreciseDeltas = hasPreciseDeltas
            self.isDirectionInverted = isDirectionInverted
        }
    }

    /// Horizontal displacement to move within the strip (pt, positive = page backward); `nil` = this event is not taken over, passed to the underlying `NSScrollView` as is.
    static func horizontalStep(for input: Input) -> CGFloat? {
        guard input.deltaY != 0 else { return nil }
        // **Predominantly horizontal gestures must be let through**: trackpad left/right swipes and Magic Mouse left/right swipes are already handled by NSScrollView
        // natively, with inertia and rubber-banding; taking them over would only be worse.
        guard abs(input.deltaY) > abs(input.deltaX) else { return nil }

        let sign: CGFloat = input.isDirectionInverted ? -1 : 1
        if input.hasPreciseDeltas {
            // The delta of a continuous event is already in points, so 1:1 is enough; multiplying by wheelSpeed would make it fly off.
            // And no cap: the large deltas in the inertia phase are exactly the feel it should have.
            let step = sign * input.deltaY
            return step == 0 ? nil : step
        }
        let raw = sign * input.deltaY * wheelSpeed
        let step = min(max(raw, -maxStep), maxStep)
        return step == 0 ? nil : step
    }
}
