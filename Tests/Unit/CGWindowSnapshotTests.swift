import CoreGraphics
import XCTest

final class CGWindowSnapshotTests: XCTestCase {
    func testParseSeparatesAllAndOnScreenLayerZeroWindows() {
        let snapshot = AppTrackerCGWindowSnapshot.parse([
            windowInfo(id: 11, layer: 0, isOnScreen: true, pid: 100),
            windowInfo(id: 12, layer: 0, isOnScreen: false, pid: 100),
            windowInfo(id: 13, layer: 1, isOnScreen: true, pid: 100),
        ])

        XCTAssertEqual(snapshot.allWindowIDs, [11, 12])
        XCTAssertEqual(snapshot.onScreenWindowIDs, [11])
    }

    func testParseGroupsLayerZeroWindowsByOwnerPID() {
        let snapshot = AppTrackerCGWindowSnapshot.parse([
            windowInfo(id: 11, layer: 0, isOnScreen: true, pid: 100),
            windowInfo(id: 12, layer: 0, isOnScreen: false, pid: 100),
            windowInfo(id: 21, layer: 0, isOnScreen: false, pid: 200),
            windowInfo(id: 22, layer: 1, isOnScreen: true, pid: 200),   // non-layer-0 doesn't enter the mapping
            windowInfo(id: 31, layer: 0, isOnScreen: false, pid: nil),  // missing pid enters only the full set
        ])

        XCTAssertEqual(snapshot.windowIDsByPID[100], [11, 12])
        XCTAssertEqual(snapshot.windowIDsByPID[200], [21])
        XCTAssertEqual(snapshot.allWindowIDs, [11, 12, 21, 31])
    }

    func testParseCapturesAlphaByLayerZeroWindowID() {
        let snapshot = AppTrackerCGWindowSnapshot.parse([
            windowInfo(id: 11, layer: 0, isOnScreen: true, pid: 100, alpha: 1),
            windowInfo(id: 12, layer: 0, isOnScreen: false, pid: 100, alpha: 0),
            windowInfo(id: 13, layer: 0, isOnScreen: false, pid: 100, alpha: nil),
            windowInfo(id: 14, layer: 1, isOnScreen: true, pid: 100, alpha: 0.5),
        ])

        XCTAssertEqual(snapshot.alphaByWindowID, [11: 1, 12: 0])
    }

    /// The multi-screen ④ tick traversal relies on `kCGWindowBounds`; only layer-0 is accepted, and ones missing bounds don't enter the mapping.
    func testParseCapturesBoundsByLayerZeroWindowID() {
        let rect = CGRect(x: 1200, y: 40, width: 800, height: 600)
        let snapshot = AppTrackerCGWindowSnapshot.parse([
            windowInfo(id: 11, layer: 0, isOnScreen: true, pid: 100, bounds: rect),
            windowInfo(id: 12, layer: 0, isOnScreen: false, pid: 100, bounds: nil),
            windowInfo(id: 13, layer: 1, isOnScreen: true, pid: 100, bounds: rect),
        ])

        XCTAssertEqual(snapshot.boundsByWindowID, [11: rect])
        XCTAssertTrue(AppTrackerCGWindowSnapshot.failed.boundsByWindowID.isEmpty)
    }

    func testParseTreatsMissingOnScreenFlagAsNotOnScreen() {
        let snapshot = AppTrackerCGWindowSnapshot.parse([
            windowInfo(id: 21, layer: 0, isOnScreen: nil, pid: 100),
        ])

        XCTAssertEqual(snapshot.allWindowIDs, [21])
        XCTAssertTrue(snapshot.onScreenWindowIDs.isEmpty)
    }

    func testParseIgnoresMalformedEntriesAndHandlesEmptyInput() {
        let malformed: [[String: Any]] = [
            [kCGWindowLayer as String: 0],
            [kCGWindowNumber as String: 31],
            [kCGWindowLayer as String: "0", kCGWindowNumber as String: 32],
        ]

        let empty = AppTrackerCGWindowSnapshot(
            allWindowIDs: [],
            onScreenWindowIDs: [],
            windowIDsByPID: [:],
            alphaByWindowID: [:]
        )
        XCTAssertEqual(AppTrackerCGWindowSnapshot.parse(malformed), empty)
        XCTAssertEqual(AppTrackerCGWindowSnapshot.parse([]), empty)
    }

    func testParseNeverMarksCaptureFailed() {
        XCTAssertFalse(AppTrackerCGWindowSnapshot.parse([]).captureFailed)
        XCTAssertFalse(AppTrackerCGWindowSnapshot.parse([
            windowInfo(id: 11, layer: 0, isOnScreen: true, pid: 100),
        ]).captureFailed)
    }

    func testFailedFactoryIsEmptyAndMarksCaptureFailed() {
        let failed = AppTrackerCGWindowSnapshot.failed
        XCTAssertTrue(failed.captureFailed)
        XCTAssertTrue(failed.allWindowIDs.isEmpty)
        XCTAssertTrue(failed.onScreenWindowIDs.isEmpty)
        XCTAssertTrue(failed.windowIDsByPID.isEmpty)
        XCTAssertTrue(failed.alphaByWindowID.isEmpty)
    }

    /// Desktop-layer windows (widgets) feed only the veto set; every layer-0 field ignores them.
    func testParseCollectsBelowNormalLayerWindowIDsSeparately() {
        let rect = CGRect(x: 16, y: 30, width: 344, height: 359)
        let snapshot = AppTrackerCGWindowSnapshot.parse([
            windowInfo(id: 11, layer: 0, isOnScreen: true, pid: 100, alpha: 1, bounds: rect),
            windowInfo(id: 12, layer: -20, isOnScreen: true, pid: 100, alpha: 1, bounds: rect),
            windowInfo(id: 13, layer: 3, isOnScreen: true, pid: 100, alpha: 1, bounds: rect),
        ])

        XCTAssertEqual(snapshot.belowNormalLayerWindowIDs, [12])
        XCTAssertEqual(snapshot.allWindowIDs, [11])
        XCTAssertEqual(snapshot.onScreenWindowIDs, [11])
        XCTAssertEqual(snapshot.windowIDsByPID, [100: [11]])
        XCTAssertEqual(snapshot.alphaByWindowID, [11: 1])
        XCTAssertEqual(snapshot.boundsByWindowID, [11: rect])
        XCTAssertTrue(AppTrackerCGWindowSnapshot.failed.belowNormalLayerWindowIDs.isEmpty)
    }

    func testFailedDiffersFromGenuinelyEmptyCapture() {
        XCTAssertNotEqual(AppTrackerCGWindowSnapshot.failed, AppTrackerCGWindowSnapshot.parse([]))
    }

    private func windowInfo(
        id: Int,
        layer: Int,
        isOnScreen: Bool?,
        pid: Int?,
        alpha: Double? = nil,
        bounds: CGRect? = nil
    ) -> [String: Any] {
        var info: [String: Any] = [
            kCGWindowNumber as String: id,
            kCGWindowLayer as String: layer,
        ]
        if let isOnScreen {
            info[kCGWindowIsOnscreen as String] = isOnScreen
        }
        if let pid {
            info[kCGWindowOwnerPID as String] = pid
        }
        if let alpha {
            info[kCGWindowAlpha as String] = alpha
        }
        if let bounds {
            info[kCGWindowBounds as String] = bounds.dictionaryRepresentation
        }
        return info
    }
}
