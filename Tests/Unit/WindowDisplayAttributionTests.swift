import CoreGraphics
import XCTest

final class WindowDisplayAttributionTests: XCTestCase {
    private let table = WindowDisplayAttribution.Table(
        displays: [
            .init(uuid: "A", cgFrame: CGRect(x: 0, y: 0, width: 1000, height: 800)),
            .init(uuid: "B", cgFrame: CGRect(x: 1000, y: 0, width: 1000, height: 800)),
        ],
        primaryUUID: "A"
    )

    func testNilFrameIsUnknown() {
        XCTAssertNil(WindowDisplayAttribution.displayUUID(for: nil, table: table))
    }

    func testFrameFullyInsideADisplayBelongsToIt() {
        let frame = CGRect(x: 1200, y: 100, width: 400, height: 300)
        XCTAssertEqual(WindowDisplayAttribution.displayUUID(for: frame, table: table), "B")
    }

    func testStraddlingFrameGoesToTheDisplayHoldingMostOfItsArea() {
        // 70% on A, 30% on B.
        let frame = CGRect(x: 300, y: 100, width: 1000, height: 300)
        XCTAssertEqual(WindowDisplayAttribution.displayUUID(for: frame, table: table), "A")
    }

    func testFrameOffEveryDisplayIsUnknown() {
        let frame = CGRect(x: 5000, y: 5000, width: 100, height: 100)
        XCTAssertNil(WindowDisplayAttribution.displayUUID(for: frame, table: table))
    }

    func testEmptyTableIsUnknown() {
        let frame = CGRect(x: 10, y: 10, width: 100, height: 100)
        XCTAssertNil(WindowDisplayAttribution.displayUUID(for: frame, table: .empty))
    }

    func testConnectedUUIDsMirrorTheTable() {
        XCTAssertEqual(table.connectedUUIDs, ["A", "B"])
        XCTAssertTrue(WindowDisplayAttribution.Table.empty.connectedUUIDs.isEmpty)
    }
}
