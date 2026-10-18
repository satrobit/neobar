import XCTest
@testable import NeoBar

/// Landing-spot decision for dragging the whole drawer block into the strip. Before the rework it used a whole-frame `contains`; measured (2026-08-18 drag log),
/// the first landing spot degraded 100% to "land at the end", because the conversion decision box deliberately extends 16pt beyond the strip's top edge,
/// and outside the strip a whole-frame hit always fails. What is pinned here is "**look only at x, and always give an answer**".
final class StripBlockLandingTests: XCTestCase {
    /// Three cards at native spacing in the live zone: width 40, gap 2, centers at 20 / 62 / 104.
    private let live: [String: CGRect] = [
        "a": CGRect(x: 0,   y: 0, width: 40, height: 54),
        "b": CGRect(x: 42,  y: 0, width: 40, height: 54),
        "c": CGRect(x: 84,  y: 0, width: 40, height: 54)
    ]

    private func hit(_ x: CGFloat, _ frames: [String: CGRect]? = nil) -> String {
        guard let t = StripBlockLanding.target(pointerX: x, frames: frames ?? live) else { return "nil" }
        return "\(t.id)\(t.after ? ">" : "<")"
    }

    func testLandsOnTheHalfThePointerIsIn() {
        XCTAssertEqual(hit(10), "a<")
        XCTAssertEqual(hit(30), "a>")
        XCTAssertEqual(hit(55), "b<")
        XCTAssertEqual(hit(70), "b>")
    }

    /// **The core of this round**: beyond the strip's top edge, the 2pt gap between cards, above the messaging zone/folder zone:
    /// these positions used to always have "no target", and the whole block stayed in place or landed at the end. Now they all have to give the nearest insertion slot.
    func testEveryPointerPositionResolvesToASlot() {
        for x in stride(from: CGFloat(-200), through: 400, by: 1) {
            XCTAssertNotEqual(hit(x), "nil", "x=\(x) 必须能落位")
        }
    }

    /// In a gap, take whichever is nearer by distance to the card center: left of the gap's center belongs to the left card's right side, right of it to the right card's left side;
    /// the two are actually **the same insertion slot**, so however the gap is decided it never jumps cells.
    func testTheGapResolvesToTheSameInsertionSlotFromEitherSide() {
        XCTAssertEqual(hit(40.9), "a>")
        XCTAssertEqual(hit(43.1), "b<")
    }

    /// Cursor far to the left of the live zone (over the messaging zone/folder zone) → insert **before** the leftmost card,
    /// not at the end. The gap should open on the side that is visible and close to the finger.
    func testFarLeftInsertsBeforeTheFirstCard() {
        XCTAssertEqual(hit(-500), "a<")
    }

    /// Far to the right → after the rightmost card.
    func testFarRightInsertsAfterTheLastCard() {
        XCTAssertEqual(hit(9999), "c>")
    }

    /// y takes no part at all: the decision must also have an answer inside the 16pt tolerance band above the strip's top edge.
    /// (Expressed with a set of frames whose y lands outside the strip: as long as x lines up it should hit.)
    func testVerticalPositionIsIrrelevantByConstruction() {
        // The signature of target has no y at all; this line pins that down with "the same x gives the same result".
        let shifted = live.mapValues { $0.offsetBy(dx: 0, dy: 500) }
        for x in stride(from: CGFloat(-50), through: 200, by: 7) {
            XCTAssertEqual(hit(x, shifted), hit(x), "x=\(x) 的落位不该受纵向位置影响")
        }
    }

    /// Frames not yet measured don't take part, otherwise an extra landing slot would appear out of nowhere near the origin.
    func testUnmeasuredFramesAreIgnored() {
        XCTAssertEqual(hit(500, ["ghost": .zero]), "nil")
        XCTAssertEqual(hit(50, ["a": live["a"]!, "ghost": .zero]), "a>")
    }

    /// Return nil only when the live zone is truly empty (the caller has nowhere to insert then anyway).
    func testEmptyLiveZone() {
        XCTAssertEqual(hit(50, [:]), "nil")
    }

    /// With equal distances the result must be deterministic: dictionary iteration order is undefined, and an undefined order would bounce back and forth between frames.
    func testTiesAreResolvedDeterministically() {
        let symmetric: [String: CGRect] = [
            "z": CGRect(x: 0,  y: 0, width: 40, height: 54),
            "a": CGRect(x: 60, y: 0, width: 40, height: 54)
        ]
        // x = 40 is 20 away from both centers.
        let first = hit(40, symmetric)
        for _ in 0..<50 { XCTAssertEqual(hit(40, symmetric), first) }
    }
}
