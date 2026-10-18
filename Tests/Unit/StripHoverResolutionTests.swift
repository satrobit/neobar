import XCTest
@testable import NeoBar

/// The pure decision of "which card the pointer is over". It replaces each card's own `.onHover`; the causes, measured data, and
/// the two defects it fixes at the same time (fast sweeps skipping cells / direction-dependent switch boundary) are in the comments of `StripHoverResolution`.
final class StripHoverResolutionTests: XCTestCase {
    /// A row of icon cards at native spacing: width 40, gap 2, center spacing 42.
    private let bar: [String: CGRect] = [
        "a": CGRect(x: 0,  y: 0, width: 40, height: 54),
        "b": CGRect(x: 42, y: 0, width: 40, height: 54),
        "c": CGRect(x: 84, y: 0, width: 40, height: 54)
    ]
    private let midY: CGFloat = 27

    private func hit(_ x: CGFloat, _ frames: [String: CGRect]? = nil) -> String? {
        StripHoverResolution.chip(at: CGPoint(x: x, y: midY), frames: frames ?? bar)
    }

    func testPointerInsideACardHitsThatCard() {
        XCTAssertEqual(hit(20), "a")
        XCTAssertEqual(hit(62), "b")
        XCTAssertEqual(hit(104), "c")
    }

    // MARK: - Boundary: one hard line, independent of the direction of approach

    /// **This is the goal of this round.** Before the rework there was a 2pt dead zone between the hit rects of two cards, and the pointer had to walk fully into
    /// the next card before the hand-off, so the switch point was direction-dependent: measured, going right it landed on the right card's left edge, going left at the midpoint plus a bit left,
    /// a 3.5pt hysteresis (owner, 2026-08-17: "the boundary isn't fixed, not crisp").
    /// Now the gap is bridged, and the switch point is the exact middle of the gap, 41, the same number in both directions.
    func testTheSwitchPointIsExactlyTheMiddleOfTheGap() {
        XCTAssertEqual(hit(40.4), "a", "缝的左半边仍归左卡")
        XCTAssertEqual(hit(41.6), "b", "缝的右半边归右卡")
    }

    /// **No spot in the gap is ownerless**: those 2pt used to be a "belongs to nobody" middle state,
    /// and sliding over slowly you would see "A → empty → B".
    func testNoDeadZoneAnywhereInsideTheGap() {
        for step in stride(from: CGFloat(40), through: 42, by: 0.1) {
            XCTAssertNotNil(hit(step), "缝内 x=\(step) 不该无人认领")
        }
    }

    /// When cards of different widths sit side by side, the gap verdict takes whichever is nearer by distance **to the card edge**, not to the card center:
    /// by card center the narrow card would eat an extra piece and the boundary would no longer be at the exact middle of the gap.
    func testGapIsSplitByEdgeDistanceNotByCardCentre() {
        let mixed: [String: CGRect] = [
            "wide": CGRect(x: 0, y: 0, width: 160, height: 54),
            "icon": CGRect(x: 162, y: 0, width: 40, height: 54)
        ]
        XCTAssertEqual(hit(160.4, mixed), "wide")
        XCTAssertEqual(hit(161.6, mixed), "icon")
    }

    // MARK: - A wide gap still pops up nothing

    /// The 9pt-wide gap of a section divider, and the margins at the two ends of the strip: after bridging 2pt on each side the middle is still empty,
    /// so hovering over it no card is owned (native is the same).
    func testWideGapsStayUnowned() {
        let zones: [String: CGRect] = [
            "left":  CGRect(x: 0,  y: 0, width: 40, height: 54),
            "right": CGRect(x: 49, y: 0, width: 40, height: 54)   // 9pt section gap
        ]
        XCTAssertNil(hit(44.5, zones), "分区缝正中不该有人拥有")
        XCTAssertNil(hit(-5, zones), "条左端留白之外")
        XCTAssertNil(hit(200, zones), "条右端留白之外")
    }

    /// No vertical bridging: leaving the strip vertically should leave nobody owning, otherwise the edge-wake/capsule area would be misjudged.
    func testVerticalIsNotBridged() {
        XCTAssertNil(StripHoverResolution.chip(at: CGPoint(x: 20, y: -3), frames: bar))
        XCTAssertNil(StripHoverResolution.chip(at: CGPoint(x: 20, y: 80), frames: bar))
    }

    /// The bridging amount scales with the tier (small tier: cards narrow, gaps narrow). Passing 0 degrades to "must walk fully into the card",
    /// which is the direction-dependent behavior from before the rework; this also pins down that the parameter is really used.
    func testGapBridgeIsAParameter() {
        XCTAssertNil(StripHoverResolution.chip(at: CGPoint(x: 41, y: midY),
                                               frames: bar, gapBridge: 0))
        XCTAssertNotNil(StripHoverResolution.chip(at: CGPoint(x: 41, y: midY),
                                                  frames: bar, gapBridge: 2))
    }

    /// The bridging amount is exactly the card spacing; the two are the same thing: extending each side of the gap by half its width makes them meet in the exact middle.
    func testBridgeMatchesTheChipSpacing() {
        XCTAssertEqual(StripHoverResolution.defaultGapBridge, ChipPillMetrics.chipSpacing)
    }

    /// Frames not yet measured (`.zero`) don't take part in the decision, otherwise an extra owner would appear out of nowhere near the origin.
    func testUnmeasuredFramesAreIgnored() {
        XCTAssertNil(StripHoverResolution.chip(at: .zero, frames: ["x": .zero]))
    }

    /// An empty table doesn't crash and claims nothing.
    func testEmptyFrames() {
        XCTAssertNil(hit(20, [:]))
    }
}
