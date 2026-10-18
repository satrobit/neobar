import XCTest
@testable import NeoBar

final class TaskbarPerDisplaySeedTests: XCTestCase {
    func testUpgraderIsInertEvenWithTwoDisplays() {
        XCTAssertEqual(evaluate(false, false, 2), .inert)
    }

    func testTwoIdentifiedDisplaysSeeds() {
        XCTAssertEqual(evaluate(true, false, 2), .seedPerDisplay)
    }

    func testThreeIdentifiedDisplaysSeeds() {
        XCTAssertEqual(evaluate(true, false, 3), .seedPerDisplay)
    }

    func testOneIdentifiedDisplayWaits() {
        XCTAssertEqual(evaluate(true, false, 1), .wait)
    }

    func testNoIdentifiedDisplaysWaits() {
        XCTAssertEqual(evaluate(true, false, 0), .wait)
    }

    func testStoredChoiceConsumesWithTwoDisplays() {
        XCTAssertEqual(evaluate(true, true, 2), .consumeWithoutSeeding)
    }

    func testStoredChoiceConsumesWithOneDisplay() {
        XCTAssertEqual(evaluate(true, true, 1), .consumeWithoutSeeding)
    }

    func testConsumedMarkerIsInertWithStoredChoice() {
        XCTAssertEqual(evaluate(false, true, 5), .inert)
    }

    private func evaluate(_ pending: Bool, _ stored: Bool, _ count: Int) -> TaskbarPerDisplaySeed.Outcome {
        TaskbarPerDisplaySeed.evaluate(
            isSeedPending: pending,
            hasStoredPlacementChoice: stored,
            identifiedDisplayCount: count
        )
    }
}
