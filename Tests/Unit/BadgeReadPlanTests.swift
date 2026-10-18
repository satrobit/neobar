import XCTest

/// Badge read plan decision matrix: pause priority, each full-walk reason, targeted read passthrough, the 10s self-healing boundary.
final class BadgeReadPlanTests: XCTestCase {
    private func input(
        messagingBundleIDs: [String] = ["com.tencent.xinWeChat"],
        taskbarVisible: Bool = true,
        hasCache: Bool = true,
        cacheAgeSeconds: TimeInterval = 3,
        rewalkRequested: Bool = false
    ) -> BadgeReadPlan.Input {
        BadgeReadPlan.Input(
            messagingBundleIDs: messagingBundleIDs,
            taskbarVisible: taskbarVisible,
            hasCache: hasCache,
            cacheAgeSeconds: cacheAgeSeconds,
            rewalkRequested: rewalkRequested
        )
    }

    func testEmptyMessagingListPausesBeforeEverything() {
        // pause takes priority over walking the tree: with nothing readable, not even the cache rebuild is done (zero AX traffic).
        XCTAssertEqual(
            BadgeReadPlan.verdict(input(messagingBundleIDs: [], hasCache: false, rewalkRequested: true)),
            .pause
        )
    }

    func testHiddenTaskbarPausesBeforeEverything() {
        XCTAssertEqual(
            BadgeReadPlan.verdict(input(taskbarVisible: false, hasCache: false, rewalkRequested: true)),
            .pause
        )
    }

    func testMissingCacheWalks() {
        XCTAssertEqual(
            BadgeReadPlan.verdict(input(hasCache: false)),
            .fullWalk(.noCache)
        )
    }

    func testRequestedRewalkWalks() {
        XCTAssertEqual(
            BadgeReadPlan.verdict(input(rewalkRequested: true)),
            .fullWalk(.rewalkRequested)
        )
    }

    func testSelfHealBoundaryIsInclusive() {
        XCTAssertEqual(
            BadgeReadPlan.verdict(input(cacheAgeSeconds: BadgeReadPlan.defaultFullWalkInterval)),
            .fullWalk(.selfHealDue)
        )
        XCTAssertEqual(
            BadgeReadPlan.verdict(input(cacheAgeSeconds: BadgeReadPlan.defaultFullWalkInterval - 0.001)),
            .targeted(["com.tencent.xinWeChat"])
        )
    }

    func testQuietTickReadsTargetedMessagingSet() {
        XCTAssertEqual(
            BadgeReadPlan.verdict(input(messagingBundleIDs: ["a", "b"])),
            .targeted(["a", "b"])
        )
    }
}
