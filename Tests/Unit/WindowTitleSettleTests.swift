import XCTest
@testable import NeoBar

final class WindowTitleSettleTests: XCTestCase {

    private func feed(_ settle: inout WindowTitleSettle, _ title: String, at t: TimeInterval) -> [String: String] {
        settle.observe(rawTitles: ["w": title], now: t)
    }

    func testFirstChangesFollowImmediately() {
        var settle = WindowTitleSettle()
        XCTAssertEqual(feed(&settle, "A", at: 0), [:])
        XCTAssertEqual(feed(&settle, "B", at: 1), [:])
        XCTAssertEqual(feed(&settle, "C", at: 2), [:])
        XCTAssertEqual(feed(&settle, "D", at: 3), [:])   // the 3rd change still follows as usual
        XCTAssertNil(settle.nextReleaseAt)
    }

    func testFourthChangeInsideWindowFreezesOnDisplayedTitle() {
        var settle = WindowTitleSettle()
        _ = feed(&settle, "A", at: 0)
        _ = feed(&settle, "B", at: 1)
        _ = feed(&settle, "A", at: 2)
        _ = feed(&settle, "B", at: 3)
        XCTAssertEqual(feed(&settle, "A", at: 4), ["w": "B"])   // 4th time: frozen at B
        XCTAssertEqual(settle.nextReleaseAt, 6)                 // 4 + quietInterval
    }

    func testContinuousFlippingNeverReleases() {
        var settle = WindowTitleSettle()
        var t: TimeInterval = 0
        var titles = ["A", "B"]
        for _ in 0..<20 {
            _ = feed(&settle, titles[0], at: t)
            titles.swapAt(0, 1)
            t += 1
        }
        // Flips every second for 20 seconds; from the 4th change on it stays frozen on the same value
        XCTAssertEqual(feed(&settle, "A", at: t), ["w": "B"])
        XCTAssertEqual(feed(&settle, "A", at: t + 1.5), ["w": "B"])   // 1.5s of quiet isn't enough yet
        XCTAssertEqual(feed(&settle, "A", at: t + 2), [:])            // released only after a full 2s of quiet
    }

    func testReleasesToLatestAfterQuietInterval() {
        var settle = WindowTitleSettle()
        _ = feed(&settle, "A", at: 0)
        _ = feed(&settle, "B", at: 1)
        _ = feed(&settle, "A", at: 2)
        _ = feed(&settle, "B", at: 3)
        XCTAssertEqual(feed(&settle, "Final", at: 4), ["w": "B"])
        XCTAssertEqual(feed(&settle, "Final", at: 5.9), ["w": "B"])   // not quiet long enough yet
        XCTAssertEqual(feed(&settle, "Final", at: 6), [:])            // released, straight to the latest value
        XCTAssertNil(settle.nextReleaseAt)
    }

    func testChangesOutsideMemoryWindowDoNotCount() {
        var settle = WindowTitleSettle()
        _ = feed(&settle, "A", at: 0)
        _ = feed(&settle, "B", at: 1)
        _ = feed(&settle, "C", at: 2)
        _ = feed(&settle, "D", at: 3)
        // After the 6-second window slides past the first three changes, another change is still "the 1st within the window"
        XCTAssertEqual(feed(&settle, "E", at: 10), [:])
        XCTAssertEqual(feed(&settle, "F", at: 10.5), [:])
    }

    func testForgetsCardsThatLeftAndStartsNewOnesAtCurrentTitle() {
        var settle = WindowTitleSettle()
        _ = settle.observe(rawTitles: ["w": "A"], now: 0)
        for (i, title) in ["B", "A", "B", "A"].enumerated() {
            _ = settle.observe(rawTitles: ["w": title], now: TimeInterval(i + 1))
        }
        XCTAssertNotNil(settle.nextReleaseAt)
        // The card leaves for a round and comes back: history is reset, no longer frozen
        XCTAssertEqual(settle.observe(rawTitles: [:], now: 5), [:])
        XCTAssertNil(settle.nextReleaseAt)
        XCTAssertEqual(settle.observe(rawTitles: ["w": "B"], now: 5.5), [:])
        XCTAssertEqual(settle.observe(rawTitles: ["w": "A"], now: 6), [:])
    }

    func testFrozenCardsAreIndependent() {
        var settle = WindowTitleSettle()
        _ = settle.observe(rawTitles: ["x": "A", "y": "P"], now: 0)
        for (i, title) in ["B", "A", "B", "A"].enumerated() {
            _ = settle.observe(rawTitles: ["x": title, "y": "P"], now: TimeInterval(i + 1))
        }
        // x's 5th change is still frozen at B; y is only on its 1st change, so it follows as usual
        XCTAssertEqual(settle.observe(rawTitles: ["x": "C", "y": "Q"], now: 5), ["x": "B"])
    }
}
