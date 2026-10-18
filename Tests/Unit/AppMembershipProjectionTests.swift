import XCTest
@testable import NeoBar

final class AppMembershipProjectionTests: XCTestCase {

    func testDrawerMembersDeduplicates() {
        let result = AppMembershipProjection.drawerMembers(drawerIDs: ["a", "a", "b"])
        XCTAssertEqual(result, ["a", "b"])
    }

    func testDrawerMembersPreservesOrder() {
        let result = AppMembershipProjection.drawerMembers(drawerIDs: ["c", "a", "b"])
        XCTAssertEqual(result, ["c", "a", "b"])
    }

    // MARK: - visibleDrawerIDs = drawer ∩ (running ∪ kept)

    func testVisibleDrawerIDsUsesRunningKeptUnion() {
        let result = AppMembershipProjection.visibleDrawerIDs(
            drawerIDs: ["running", "kept", "messagingOnly", "hidden"],
            keptIDs: ["kept"],
            runningIDs: ["running"]
        )
        // messagingOnly is neither running nor kept -> now hidden (messaging no longer keeps itself alive independently).
        XCTAssertEqual(result, ["running", "kept"])
    }

    func testVisibleDrawerIDsPreservesInputOrderAndDeduplicates() {
        let result = AppMembershipProjection.visibleDrawerIDs(
            drawerIDs: ["b", "a", "b", "c"],
            keptIDs: ["a", "b", "c"],
            runningIDs: []
        )
        XCTAssertEqual(result, ["b", "a", "c"])
    }

    func testDrawerPreviewHonorsLimit() {
        let drawerIDs = (0..<15).map { "app\($0)" }
        let result = AppMembershipProjection.drawerPreview(
            drawerIDs: drawerIDs,
            keptIDs: drawerIDs,
            runningIDs: [],
            limit: 4
        )
        XCTAssertEqual(result.count, 4)
        XCTAssertEqual(result.first, "app0")
    }

    func testDrawerPreviewExcludesInactivePlacements() {
        let result = AppMembershipProjection.drawerPreview(
            drawerIDs: ["a", "b", "c"],
            keptIDs: ["b"],
            runningIDs: ["c"],
            limit: 9
        )
        XCTAssertEqual(result, ["b", "c"])
    }

    // MARK: - visibleMessagingIDs = (messaging − drawer) ∩ (running ∪ kept)

    func testVisibleMessagingIDsExcludesDrawerAndRequiresRunningOrKept() {
        let result = AppMembershipProjection.visibleMessagingIDs(
            messagingIDs: ["running", "kept", "stashed", "gone"],
            drawerIDs: ["stashed"],
            keptIDs: ["kept"],
            runningIDs: ["running"]
        )
        // stashed -> hidden in the drawer; gone -> neither running nor kept, hidden.
        XCTAssertEqual(result, ["running", "kept"])
    }

    func testVisibleMessagingIDsPreservesOrderAndDeduplicates() {
        let result = AppMembershipProjection.visibleMessagingIDs(
            messagingIDs: ["c", "a", "c", "b"],
            drawerIDs: [],
            keptIDs: ["a", "b", "c"],
            runningIDs: []
        )
        XCTAssertEqual(result, ["c", "a", "b"])
    }


    // MARK: - badgeEligibleIDs = identity ∩ running − drawer (2026-08-23 badges decoupled from the messaging area)

    func testBadgeEligibleIDsUsesIdentityNotZone() {
        let identity: Set<String> = ["com.apple.MobileSMS", "com.tencent.xinWeChat", "com.slack"]
        let result = AppMembershipProjection.badgeEligibleIDs(
            isMessagingApp: { identity.contains($0) },
            drawerIDs: ["com.slack"],                      // those in the drawer aren't read
            runningIDs: ["com.apple.MobileSMS", "com.slack", "com.apple.Safari", "com.tencent.xinWeChat"]
        )
        // Message never entered the messaging area, but it's a messaging app and running -> badge-eligible; Safari is not a messaging app.
        XCTAssertEqual(result, ["com.apple.MobileSMS", "com.tencent.xinWeChat"])
    }

    func testBadgeEligibleIDsIsEmptyWhenNothingRuns() {
        let result = AppMembershipProjection.badgeEligibleIDs(
            isMessagingApp: { _ in true },
            drawerIDs: [],
            runningIDs: []
        )
        XCTAssertTrue(result.isEmpty, "没有消息应用在跑 → 空集 → BadgeStore 停轮询")
    }
}
