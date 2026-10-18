import XCTest

final class DocumentUsageRankingTests: XCTestCase {
    private func date(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSinceReferenceDate: offset)
    }

    func testCountedFilesOutrankRecentOnlyAndTiesFallToRecency() {
        let counts = [
            "/a": DocumentUsageRecord(count: 3, lastOpened: date(10)),
            "/b": DocumentUsageRecord(count: 3, lastOpened: date(20)),
            "/c": DocumentUsageRecord(count: 1, lastOpened: date(99)),
        ]
        let ranked = DocumentUsageRanking.ranked(counts: counts, recentPaths: ["/new1", "/new2", "/a"])
        XCTAssertEqual(ranked.prefix(3), ["/b", "/a", "/c"], "同次数比 lastOpened，次数高的永远在前")
        XCTAssertEqual(Array(ranked.suffix(2)), ["/new1", "/new2"], "没计过数的按系统最近序垫底")
    }

    func testRankedDeduplicatesAndHonorsLimit() {
        let ranked = DocumentUsageRanking.ranked(
            counts: [:],
            recentPaths: ["/x", "/x", "/y", "/z"],
            limit: 2
        )
        XCTAssertEqual(ranked, ["/x", "/y"])
    }

    func testEmptyCountsMatchesSystemRecentOrder() {
        let ranked = DocumentUsageRanking.ranked(counts: [:], recentPaths: ["/1", "/2", "/3"])
        XCTAssertEqual(ranked, ["/1", "/2", "/3"], "刚升级的头几天 = 原来的「最近」")
    }

    func testBumpIncrementsAndEvictsLowestWhenOverCap() {
        var files = [
            "/low": DocumentUsageRecord(count: 1, lastOpened: date(1)),
            "/mid": DocumentUsageRecord(count: 1, lastOpened: date(50)),
            "/high": DocumentUsageRecord(count: 9, lastOpened: date(2)),
        ]
        files = DocumentUsageRanking.bumped(files, path: "/new", at: date(100), cap: 3)
        XCTAssertEqual(files["/new"]?.count, 1)
        XCTAssertNil(files["/low"], "淘汰计数最低、最久未开的")
        XCTAssertNotNil(files["/mid"])
        XCTAssertNotNil(files["/high"])

        files = DocumentUsageRanking.bumped(files, path: "/new", at: date(101), cap: 3)
        XCTAssertEqual(files["/new"]?.count, 2, "重复 +1 累加且不再淘汰（未超容量）")
    }

    func testBumpNeverEvictsTheJustBumpedPath() {
        let files = DocumentUsageRanking.bumped([:], path: "/only", at: date(1), cap: 0)
        XCTAssertNotNil(files["/only"], "cap 再小也不淘汰刚用过的那一个")
    }

    func testTopChangeCountsOnlyRealTransitions() {
        XCTAssertFalse(DocumentUsageRanking.shouldCountTopChange(previousTop: nil, newTop: "/a"), "首次采样只立基线")
        XCTAssertFalse(DocumentUsageRanking.shouldCountTopChange(previousTop: "/a", newTop: "/a"), "重复采样不计")
        XCTAssertFalse(DocumentUsageRanking.shouldCountTopChange(previousTop: "/a", newTop: nil), "清空不计")
        XCTAssertTrue(DocumentUsageRanking.shouldCountTopChange(previousTop: "/a", newTop: "/b"))
    }

    func testBundlePruneKeepsMostRecentlyTouched() {
        let store = [
            "com.old": BundleDocumentUsage(files: [:], lastTop: nil, touchedAt: date(1)),
            "com.mid": BundleDocumentUsage(files: [:], lastTop: nil, touchedAt: date(50)),
            "com.new": BundleDocumentUsage(files: [:], lastTop: nil, touchedAt: date(99)),
        ]
        let pruned = DocumentUsageRanking.prunedBundles(store, maxBundles: 2)
        XCTAssertEqual(Set(pruned.keys), ["com.mid", "com.new"])
        XCTAssertEqual(DocumentUsageRanking.prunedBundles(store, maxBundles: 3).count, 3, "没超就不动")
    }
}
