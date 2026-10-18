import XCTest
@testable import NeoBar

@MainActor
final class TaskbarPerDisplaySeedControllerTests: XCTestCase {
    func testSingleDisplayDoesNotSeedOrSchedule() {
        let harness = Harness(snapshots: [Self.snapshot(physical: 1, uuids: ["A"])])

        let result = harness.controller.prepareForTopologyChange()

        XCTAssertEqual(result.identifiedDisplayUUIDs, ["A"])
        XCTAssertEqual(harness.seedCount, 0)
        XCTAssertTrue(harness.scheduler.entries.isEmpty)
    }

    func testCompleteDualDisplaySnapshotSeedsSynchronously() {
        let harness = Harness(snapshots: [Self.snapshot(physical: 2, uuids: ["A", "B"])])

        let result = harness.controller.prepareForTopologyChange()

        XCTAssertEqual(result.identifiedDisplayUUIDs, ["A", "B"])
        XCTAssertEqual(harness.seedCount, 1)
        XCTAssertFalse(harness.pending)
        XCTAssertTrue(harness.retrySeededSnapshots.isEmpty)
    }

    func testIncompleteSnapshotSchedulesExactlyTwoRetries() {
        let incomplete = Self.snapshot(physical: 2, uuids: ["A"])
        let harness = Harness(snapshots: [incomplete])

        _ = harness.controller.prepareForTopologyChange()

        XCTAssertEqual(harness.scheduler.entries.map { $0.delay }, [0.5, 2.0])
    }

    func testFirstRetryCanSeedAndCancelsSecond() {
        let complete = Self.snapshot(physical: 2, uuids: ["A", "B"])
        let harness = Harness(snapshots: [Self.snapshot(physical: 2, uuids: ["A"]), complete])
        _ = harness.controller.prepareForTopologyChange()

        harness.scheduler.fire(0)

        XCTAssertEqual(harness.seedCount, 1)
        XCTAssertEqual(harness.retrySeededSnapshots, [complete])
        XCTAssertTrue(harness.scheduler.entries[1].item.isCancelled)
        XCTAssertEqual(harness.scheduler.entries.count, 2, "retry callbacks must never schedule another generation")
    }

    func testSecondRetryCanSeedAfterFirstStillFails() {
        let incomplete = Self.snapshot(physical: 2, uuids: ["A"])
        let complete = Self.snapshot(physical: 2, uuids: ["A", "B"])
        let harness = Harness(snapshots: [incomplete, incomplete, complete])
        _ = harness.controller.prepareForTopologyChange()

        harness.scheduler.fire(0)
        XCTAssertEqual(harness.seedCount, 0)
        harness.scheduler.fire(1)

        XCTAssertEqual(harness.seedCount, 1)
        XCTAssertEqual(harness.retrySeededSnapshots, [complete])
    }

    func testRetryExhaustionLeavesMarkerArmed() {
        let incomplete = Self.snapshot(physical: 2, uuids: ["A"])
        let harness = Harness(snapshots: [incomplete, incomplete, incomplete])
        _ = harness.controller.prepareForTopologyChange()

        harness.scheduler.fire(0)
        harness.scheduler.fire(1)

        XCTAssertTrue(harness.pending)
        XCTAssertEqual(harness.seedCount, 0)
        XCTAssertTrue(harness.retrySeededSnapshots.isEmpty)
    }

    func testOldGenerationCannotLandAfterNewTopologyEvent() {
        let incomplete = Self.snapshot(physical: 2, uuids: ["A"])
        let harness = Harness(snapshots: [incomplete, incomplete, Self.snapshot(physical: 1, uuids: ["A"])])
        _ = harness.controller.prepareForTopologyChange()
        let oldAction = harness.scheduler.entries[0].action

        _ = harness.controller.prepareForTopologyChange()
        oldAction()

        XCTAssertEqual(harness.seedCount, 0)
        XCTAssertEqual(harness.appliedSnapshots.count, 2)
    }

    func testStoredPlacementChoiceConsumesWithoutSeedingOrRetry() {
        let harness = Harness(snapshots: [Self.snapshot(physical: 2, uuids: ["A"] )])
        harness.hasStoredChoice = true

        _ = harness.controller.prepareForTopologyChange()

        XCTAssertFalse(harness.pending)
        XCTAssertEqual(harness.consumeCount, 1)
        XCTAssertEqual(harness.seedCount, 0)
        XCTAssertTrue(harness.scheduler.entries.isEmpty)
    }

    private static func snapshot(physical: Int, uuids: [String]) -> ScreenTopologySnapshot {
        let displays = uuids.enumerated().map { index, uuid in
            WindowDisplayAttribution.Display(
                uuid: uuid,
                cgFrame: CGRect(x: CGFloat(index * 100), y: 0, width: 100, height: 100)
            )
        }
        return ScreenTopologySnapshot(
            physicalDisplayCount: physical,
            identifiedDisplayUUIDs: uuids,
            attributionTable: .init(displays: displays, primaryUUID: uuids.first)
        )
    }
}

@MainActor
private final class Harness {
    var pending = true
    var hasStoredChoice = false
    var seedCount = 0
    var consumeCount = 0
    var appliedSnapshots: [ScreenTopologySnapshot] = []
    var retrySeededSnapshots: [ScreenTopologySnapshot] = []
    let scheduler = ManualSeedRetryScheduler()

    private var snapshots: [ScreenTopologySnapshot]
    private var snapshotIndex = 0

    init(snapshots: [ScreenTopologySnapshot]) {
        self.snapshots = snapshots
    }

    lazy var controller = TaskbarPerDisplaySeedController(
        snapshotProvider: { [unowned self] in
            let index = min(snapshotIndex, snapshots.count - 1)
            snapshotIndex += 1
            return snapshots[index]
        },
        isSeedPending: { [unowned self] in pending },
        hasStoredPlacementChoice: { [unowned self] in hasStoredChoice },
        applySnapshot: { [unowned self] in appliedSnapshots.append($0) },
        applySeed: { [unowned self] in
            seedCount += 1
            pending = false
        },
        consumeWithoutSeeding: { [unowned self] in
            consumeCount += 1
            pending = false
        },
        onRetrySeeded: { [unowned self] in retrySeededSnapshots.append($0) },
        scheduleAfter: { [unowned self] delay, action in scheduler.schedule(after: delay, action: action) }
    )
}

@MainActor
private final class ManualSeedRetryScheduler {
    struct Entry {
        let delay: TimeInterval
        let action: () -> Void
        let item: DispatchWorkItem
    }

    private(set) var entries: [Entry] = []

    func schedule(after delay: TimeInterval, action: @escaping () -> Void) -> DispatchWorkItem {
        let item = DispatchWorkItem(block: action)
        entries.append(Entry(delay: delay, action: action, item: item))
        return item
    }

    func fire(_ index: Int) {
        let entry = entries[index]
        guard !entry.item.isCancelled else { return }
        entry.action()
    }
}
