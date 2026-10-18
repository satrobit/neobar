import XCTest
@testable import NeoBar

final class StripWheelScrollTests: XCTestCase {
    private func input(dx: CGFloat = 0,
                       dy: CGFloat,
                       precise: Bool,
                       inverted: Bool) -> StripWheelScroll.Input {
        StripWheelScroll.Input(deltaX: dx, deltaY: dy,
                               hasPreciseDeltas: precise, isDirectionInverted: inverted)
    }

    // MARK: - Cases not taken over

    func testNoVerticalComponentIsNotClaimed() {
        XCTAssertNil(StripWheelScroll.horizontalStep(for: input(dx: 12, dy: 0, precise: true, inverted: true)))
        XCTAssertNil(StripWheelScroll.horizontalStep(for: input(dy: 0, precise: false, inverted: false)))
    }

    /// Predominantly horizontal gestures must be let through to `NSScrollView`: its inertia and rubber-banding are native, and taking them over would only be worse.
    func testHorizontallyDominantGestureIsNotClaimed() {
        XCTAssertNil(StripWheelScroll.horizontalStep(for: input(dx: 30, dy: 4, precise: true, inverted: true)))
        XCTAssertNil(StripWheelScroll.horizontalStep(for: input(dx: -30, dy: 4, precise: true, inverted: true)))
        // Equal also counts as predominantly horizontal: only a strictly "vertical beats horizontal" is taken over.
        XCTAssertNil(StripWheelScroll.horizontalStep(for: input(dx: 8, dy: 8, precise: true, inverted: true)))
    }

    func testVerticallyDominantGestureIsClaimedEvenWithSomeHorizontalDrift() {
        XCTAssertNotNil(StripWheelScroll.horizontalStep(for: input(dx: 3, dy: 20, precise: true, inverted: true)))
    }

    // MARK: - Discrete wheel (mice with notches)

    /// These four notches must match the pre-change result of `sign * deltaY * 56` value for value; the feel has been signed off.
    func testDiscreteWheelMatchesTheShippedFeel() {
        let table: [(dy: CGFloat, inverted: Bool, expected: CGFloat)] = [
            (1, false, 56), (-1, false, -56),
            (1, true, -56), (-1, true, 56),
        ]
        for row in table {
            XCTAssertEqual(
                StripWheelScroll.horizontalStep(for: input(dy: row.dy, precise: false, inverted: row.inverted)),
                row.expected,
                "dy=\(row.dy) inverted=\(row.inverted)"
            )
        }
    }

    func testDiscreteWheelStepIsClamped() {
        XCTAssertEqual(StripWheelScroll.horizontalStep(for: input(dy: 10, precise: false, inverted: false)),
                       StripWheelScroll.maxStep)
        XCTAssertEqual(StripWheelScroll.horizontalStep(for: input(dy: -10, precise: false, inverted: false)),
                       -StripWheelScroll.maxStep)
    }

    // MARK: - Continuous events (trackpad / Magic Mouse / smooth wheel)

    /// The delta of a continuous event is already in points: carried over 1:1, neither multiplied by `wheelSpeed` nor capped
    /// (the large deltas in the inertia phase are exactly the feel it should have).
    func testPreciseDeltasArePassedThroughOneToOne() {
        let table: [(dy: CGFloat, inverted: Bool, expected: CGFloat)] = [
            (7, false, 7), (-7, false, -7),
            (7, true, -7), (-7, true, 7),
            (400, true, -400),
        ]
        for row in table {
            XCTAssertEqual(
                StripWheelScroll.horizontalStep(for: input(dy: row.dy, precise: true, inverted: row.inverted)),
                row.expected,
                "dy=\(row.dy) inverted=\(row.inverted)"
            )
        }
    }

    /// With the same delta, a continuous event must never be treated as a discrete wheel and amplified; that would fling straight to the end.
    func testPreciseDeltasAreNotAmplifiedLikeAWheelNotch() {
        let precise = StripWheelScroll.horizontalStep(for: input(dy: 1, precise: true, inverted: false))
        let discrete = StripWheelScroll.horizontalStep(for: input(dy: 1, precise: false, inverted: false))
        XCTAssertEqual(precise, 1)
        XCTAssertEqual(discrete, StripWheelScroll.wheelSpeed)
    }
}
