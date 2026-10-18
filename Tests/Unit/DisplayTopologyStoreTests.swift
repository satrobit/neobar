import Combine
import XCTest
@testable import NeoBar

@MainActor
final class DisplayTopologyStoreTests: XCTestCase {
    func testApplyUpdatesLatestSnapshotAndPublishedTableTogether() {
        let initial = snapshot(uuid: "A", physicalCount: 1)
        let updated = snapshot(uuid: "B", physicalCount: 2)
        let store = DisplayTopologyStore(initialSnapshot: initial)

        store.apply(updated)

        XCTAssertEqual(store.latestSnapshot, updated)
        XCTAssertEqual(store.table, updated.attributionTable)
    }

    func testApplyingSameTableDoesNotPublishAgain() {
        let initial = snapshot(uuid: "A", physicalCount: 1)
        let sameTable = ScreenTopologySnapshot(
            physicalDisplayCount: 2,
            identifiedDisplayUUIDs: initial.identifiedDisplayUUIDs,
            attributionTable: initial.attributionTable
        )
        let store = DisplayTopologyStore(initialSnapshot: initial)
        var publications = 0
        let subscription = store.$table.dropFirst().sink { _ in publications += 1 }

        store.apply(sameTable)

        XCTAssertEqual(store.latestSnapshot, sameTable)
        XCTAssertEqual(publications, 0)
        withExtendedLifetime(subscription) {}
    }

    private func snapshot(uuid: String, physicalCount: Int) -> ScreenTopologySnapshot {
        let display = WindowDisplayAttribution.Display(
            uuid: uuid,
            cgFrame: CGRect(x: 0, y: 0, width: 100, height: 100)
        )
        let table = WindowDisplayAttribution.Table(displays: [display], primaryUUID: uuid)
        return ScreenTopologySnapshot(
            physicalDisplayCount: physicalCount,
            identifiedDisplayUUIDs: [uuid],
            attributionTable: table
        )
    }
}
