import XCTest

final class WindowListMenuPlanTests: XCTestCase {
    private func record(
        _ id: String,
        bundle: String = "com.example.app",
        title: String = "窗口",
        status: WindowStatus = .inactive,
        groupID: String = ""
    ) -> WindowRecord {
        WindowRecord(
            id: WindowID(rawValue: id),
            appID: AppID(rawValue: "app:\(bundle)"),
            pid: 100,
            bundleIdentifier: bundle,
            title: title,
            bounds: nil,
            status: status,
            groupID: groupID
        )
    }

    private func snapshot(_ records: [WindowRecord]) -> DockSnapshot {
        DockSnapshot(
            windows: Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) }),
            orderedWindowIDs: records.map(\.id)
        )
    }

    func testFollowsSnapshotOrderAndExcludesOtherBundlesAndFallbackSeats() {
        let snap = snapshot([
            record("w1", title: "一"),
            record("x1", bundle: "com.other.app", title: "别家"),
            record("app-com.example.app", title: "兜底"),
            record("w2", title: "二", status: .active),
        ])
        let entries = WindowListMenuPlan.entries(snapshot: snap, bundleID: "com.example.app", fallbackTitle: "App")
        XCTAssertEqual(entries.map(\.title), ["一", "二"])
        XCTAssertEqual(entries.map(\.actionWindowID), ["w1", "w2"])
        XCTAssertEqual(entries.map(\.marker), [.none, .front])
    }

    func testClosedPendingAndDisappearedAreExcluded() {
        let snap = snapshot([
            record("w1", status: .closedPending),
            record("w2", status: .disappeared),
            record("w3", title: "还在"),
        ])
        let entries = WindowListMenuPlan.entries(snapshot: snap, bundleID: "com.example.app", fallbackTitle: "App")
        XCTAssertEqual(entries.map(\.title), ["还在"])
    }

    func testTabGroupFoldsToOneEntryTitledByVisibleTab() {
        let snap = snapshot([
            record("t1", title: "后台标签", status: .minimized, groupID: "tabgrp-100-s1"),
            record("t2", title: "可见标签", status: .inactive, groupID: "tabgrp-100-s1"),
        ])
        let entries = WindowListMenuPlan.entries(snapshot: snap, bundleID: "com.example.app", fallbackTitle: "App")
        XCTAssertEqual(entries.count, 1, "原生标签组折叠成一行")
        XCTAssertEqual(entries[0].title, "可见标签")
        XCTAssertEqual(entries[0].actionWindowID, "t2")
        XCTAssertEqual(entries[0].marker, .none)
    }

    func testMinimizedMarkerOnlyWhenWholeGroupMinimized() {
        let snap = snapshot([
            record("m1", title: "全收", status: .minimized),
            record("h1", title: "隐藏", status: .hidden),
        ])
        let entries = WindowListMenuPlan.entries(snapshot: snap, bundleID: "com.example.app", fallbackTitle: "App")
        XCTAssertEqual(entries[0].marker, .minimized, "整组最小化 → ◇")
        XCTAssertEqual(entries[1].marker, .none, "隐藏不是最小化，不打 ◇")
    }

    func testBlankTitleFallsBackToAppName() {
        let snap = snapshot([record("w1", title: "  ")])
        let entries = WindowListMenuPlan.entries(snapshot: snap, bundleID: "com.example.app", fallbackTitle: "我的应用")
        XCTAssertEqual(entries[0].title, "我的应用")
    }

    func testEmptyForBundleWithNoRealWindows() {
        let snap = snapshot([record("app-com.example.app", title: "兜底")])
        XCTAssertTrue(WindowListMenuPlan.entries(snapshot: snap, bundleID: "com.example.app", fallbackTitle: "App").isEmpty)
    }
}
