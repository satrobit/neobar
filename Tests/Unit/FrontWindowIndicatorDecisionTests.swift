import XCTest
@testable import NeoBar

final class FrontWindowIndicatorDecisionTests: XCTestCase {
    private func item(_ id: String, status: WindowStatus, groupID: String = "") -> StripItem {
        StripItem(record: WindowRecord(
            id: WindowID(rawValue: id),
            appID: AppID(rawValue: "app:com.example"),
            pid: 100,
            bundleIdentifier: "com.example",
            title: id,
            bounds: nil,
            status: status,
            groupID: groupID
        ))
    }

    private func decide(_ items: [StripItem],
                        optimistic: [String: OptimisticWindowState] = [:]) -> Set<String> {
        FrontWindowIndicatorDecision.frontWindowChipIDs(items: items, optimisticStates: optimistic)
    }

    func testOnlyTheFocusedWindowOfTheFrontmostAppWidens() {
        let items = [item("a", status: .active), item("b", status: .inactive), item("c", status: .minimized)]
        XCTAssertEqual(decide(items), ["a"])
    }

    func testNothingWidensWhenNoWindowIsFocused() {
        XCTAssertEqual(decide([item("a", status: .inactive), item("b", status: .hidden)]), [])
    }

    func testAppLevelFallbackChipNeverWidens() {
        // The tracker never marks an app-* seat .active; the exclusion is explicit so a future
        // status change upstream cannot turn an application chip into a window indicator.
        let fallback = item("app-com.example", status: .active, groupID: "app-com.example")
        XCTAssertTrue(fallback.isAppLevelFallback)
        XCTAssertEqual(decide([fallback]), [])
    }

    func testClickedWindowWinsOverSnapshotBeforeTheNextRound() {
        let items = [item("a", status: .active), item("b", status: .inactive)]
        let optimistic = ["b": OptimisticWindowState(status: .active, createdAt: Date())]
        XCTAssertEqual(decide(items, optimistic: optimistic), ["b"])
    }

    func testNewestPredictionWinsWhenTwoAreInFlight() {
        let items = [item("a", status: .inactive), item("b", status: .inactive)]
        let older = OptimisticWindowState(status: .active, createdAt: Date(timeIntervalSinceNow: -1))
        let newer = OptimisticWindowState(status: .active, createdAt: Date())
        XCTAssertEqual(decide(items, optimistic: ["a": older, "b": newer]), ["b"])
    }

    func testMinimizingTheFrontWindowDropsItsBarImmediately() {
        let items = [item("a", status: .active), item("b", status: .inactive)]
        let folding = ["a": OptimisticWindowState(status: .minimized, createdAt: Date())]
        XCTAssertEqual(decide(items, optimistic: folding), [])
        // A system-predicted handoff successor takes the bar over.
        let handoff = ["a": OptimisticWindowState(status: .minimized, createdAt: Date()),
                       "b": OptimisticWindowState(status: .active, createdAt: Date(),
                                                  focusHandoffGrace: true, systemPredicted: true)]
        XCTAssertEqual(decide(items, optimistic: handoff), ["b"])
    }
}
