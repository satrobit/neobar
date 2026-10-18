import XCTest

final class DragConversionPlanTests: XCTestCase {

    // MARK: - drawerDragOutMode

    func testEmptyBundleIDRejects() {
        XCTAssertEqual(DragConversionPlan.drawerDragOutMode(
            bundleID: "", isMessagingMember: false, isInSnapshot: true, isRunningProcess: true, hasRealWindow: true, isKept: true), .reject)
    }

    /// 2026-08-20: Finder can enter the drawer, and so can be dragged back onto the taskbar like an ordinary app.
    func testFinderDragsOutLikeAnOrdinaryApp() {
        XCTAssertEqual(DragConversionPlan.drawerDragOutMode(
            bundleID: FinderTaskbarPolicy.bundleID, isMessagingMember: false,
            isInSnapshot: true, isRunningProcess: true, hasRealWindow: true, isKept: true), .unstash)
        XCTAssertEqual(DragConversionPlan.drawerDragOutMode(
            bundleID: FinderTaskbarPolicy.bundleID, isMessagingMember: false,
            isInSnapshot: true, isRunningProcess: true, hasRealWindow: false, isKept: true), .keepPlacement)
    }

    func testRunningMessagingMemberReleasesToMessaging() {
        XCTAssertEqual(DragConversionPlan.drawerDragOutMode(
            bundleID: "com.example.chat", isMessagingMember: true, isInSnapshot: true, isRunningProcess: true, hasRealWindow: false, isKept: false), .releaseToMessaging)
    }

    /// The messaging decision must precede the real-window decision: a running messaging app has a main window and must not wrongly enter unstash.
    func testMessagingPrecedesRealWindowCheck() {
        XCTAssertEqual(DragConversionPlan.drawerDragOutMode(
            bundleID: "com.example.chat", isMessagingMember: true, isInSnapshot: true, isRunningProcess: true, hasRealWindow: true, isKept: false), .releaseToMessaging)
    }

    /// Rejected only when it is neither running nor ticked as kept -- in that case releasing it there would indeed vanish into thin air.
    func testMessagingMemberNeitherRunningNorKeptRejects() {
        XCTAssertEqual(DragConversionPlan.drawerDragOutMode(
            bundleID: "com.example.chat", isMessagingMember: true, isInSnapshot: false,
            isRunningProcess: false, hasRealWindow: false, isKept: false), .reject)
    }

    /// **Regression lock**: the process is running but the window inventory doesn't have it (this is what happens when WeChat's main window is closed) -- it must be releasable.
    /// The criterion must share its source with the messaging zone's own visibility rule, not judge by the window inventory (owner 2026-08-20 measured, confirmed by logs).
    func testRunningWithNoTrackedWindowStillReleases() {
        XCTAssertEqual(DragConversionPlan.drawerDragOutMode(
            bundleID: "com.tencent.xinWeChat", isMessagingMember: true, isInSnapshot: false,
            isRunningProcess: true, hasRealWindow: false, isKept: false), .releaseToMessaging)
    }

    /// Not running but ticked as kept: the messaging zone shows it anyway (unified keep model), so it can be released back too.
    func testKeptButNotRunningMessagingMemberReleases() {
        XCTAssertEqual(DragConversionPlan.drawerDragOutMode(
            bundleID: "com.example.chat", isMessagingMember: true, isInSnapshot: false,
            isRunningProcess: false, hasRealWindow: false, isKept: true), .releaseToMessaging)
    }

    func testRealWindowUnstashes() {
        XCTAssertEqual(DragConversionPlan.drawerDragOutMode(
            bundleID: "com.example.app", isMessagingMember: false, isInSnapshot: true, isRunningProcess: true, hasRealWindow: true, isKept: false), .unstash)
    }

    func testKeptAppWithoutSnapshotUsesKeepPlacement() {
        XCTAssertEqual(DragConversionPlan.drawerDragOutMode(
            bundleID: "com.example.app", isMessagingMember: false, isInSnapshot: false, isRunningProcess: false, hasRealWindow: false, isKept: true), .keepPlacement)
    }

    func testRunningFallbackUsesKeepPlacementWithoutKept() {
        XCTAssertEqual(DragConversionPlan.drawerDragOutMode(
            bundleID: "com.example.app", isMessagingMember: false, isInSnapshot: true, isRunningProcess: true, hasRealWindow: false, isKept: false), .keepPlacement)
    }

    func testInactiveUncheckedPlacementRejects() {
        XCTAssertEqual(DragConversionPlan.drawerDragOutMode(
            bundleID: "com.example.app", isMessagingMember: false, isInSnapshot: false, isRunningProcess: false, hasRealWindow: false, isKept: false), .reject)
    }

    // MARK: - endAction

    func testStripAndFolderNeverRouteHere() {
        XCTAssertEqual(DragConversionPlan.endAction(
            source: .strip, isConvertedToStrip: false, isOverDropZone: true, isMessagingMember: false), .none)
        XCTAssertEqual(DragConversionPlan.endAction(
            source: .folder, isConvertedToStrip: false, isOverDropZone: true, isMessagingMember: false), .none)
    }

    func testMessagingChipOverDropZoneStashes() {
        XCTAssertEqual(DragConversionPlan.endAction(
            source: .messaging, isConvertedToStrip: false, isOverDropZone: true, isMessagingMember: true), .stashMessagingChip)
    }

    /// Messaging chip released over the desktop / folder zone / live zone (none of them drop zones) -> stays in place.
    func testMessagingChipOutsideDropZoneDoesNothing() {
        XCTAssertEqual(DragConversionPlan.endAction(
            source: .messaging, isConvertedToStrip: false, isOverDropZone: false, isMessagingMember: true), .none)
    }

    func testConvertedDrawerDragCommits() {
        XCTAssertEqual(DragConversionPlan.endAction(
            source: .drawer, isConvertedToStrip: true, isOverDropZone: true, isMessagingMember: false), .commitDrawerToStrip)
        XCTAssertEqual(DragConversionPlan.endAction(
            source: .drawer, isConvertedToStrip: true, isOverDropZone: false, isMessagingMember: false), .commitDrawerToStrip)
    }

    func testUnconvertedDrawerDropOnStripFallbackUnstashes() {
        XCTAssertEqual(DragConversionPlan.endAction(
            source: .drawer, isConvertedToStrip: false, isOverDropZone: true, isMessagingMember: false), .fallbackUnstash)
    }

    /// A messaging member's drawer icon never takes the degraded unstash: released on the taskbar (outside the messaging zone's range) -> stays in the drawer.
    func testMessagingMemberNeverFallbackUnstashes() {
        XCTAssertEqual(DragConversionPlan.endAction(
            source: .drawer, isConvertedToStrip: false, isOverDropZone: true, isMessagingMember: true), .none)
    }

    func testUnconvertedDrawerDropOutsideDoesNothing() {
        XCTAssertEqual(DragConversionPlan.endAction(
            source: .drawer, isConvertedToStrip: false, isOverDropZone: false, isMessagingMember: false), .none)
    }

    // MARK: - Dropped into drawer settles -> auto-open kept

    /// Open only when brought in from outside the drawer (taskbar / messaging zone).
    func testDropFromOutsideIntoDrawerEnablesKept() {
        XCTAssertTrue(DragConversionPlan.enablesKeptOnDrop(originSource: .strip, endedInDrawer: true))
        XCTAssertTrue(DragConversionPlan.enablesKeptOnDrop(originSource: .messaging, endedInDrawer: true))
    }

    /// If the drag source is the drawer itself = it was already inside (reordering within the drawer, promote-and-undo), so it isn't a "drag-in".
    func testDragStartingInDrawerNeverEnablesKept() {
        XCTAssertFalse(DragConversionPlan.enablesKeptOnDrop(originSource: .drawer, endedInDrawer: true))
    }

    /// A folder chip is completely isolated from the stash semantics and never enters this path.
    func testFolderDragNeverEnablesKept() {
        XCTAssertFalse(DragConversionPlan.enablesKeptOnDrop(originSource: .folder, endedInDrawer: true))
    }

    /// If it's not in the drawer after settling -> never open, no matter where it came from (undo, degraded move-out, promotion onto the taskbar all take this branch).
    func testNotEndingInDrawerNeverEnablesKept() {
        for source in [DragSource.strip, .drawer, .folder, .messaging] {
            XCTAssertFalse(DragConversionPlan.enablesKeptOnDrop(originSource: source, endedInDrawer: false))
        }
    }
}
