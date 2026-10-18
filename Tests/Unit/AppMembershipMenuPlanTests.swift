import XCTest
@testable import NeoBar

final class AppMembershipMenuPlanTests: XCTestCase {

    func testStripPlainAppShowsKeepAndUncheckedMessaging() {
        let items = AppMembershipMenuPlan.items(surface: .strip, isFinder: false, isKept: false, isMessaging: false)
        XCTAssertEqual(items, [.keep(isChecked: false), .messaging(isChecked: false)])
    }

    func testStripMessagingAppShowsKeepAndCheckedMessaging() {
        let items = AppMembershipMenuPlan.items(surface: .strip, isFinder: false, isKept: true, isMessaging: true)
        XCTAssertEqual(items, [.keep(isChecked: true), .messaging(isChecked: true)])
    }

    func testDrawerPlainAppShowsOnlyKeep() {
        let items = AppMembershipMenuPlan.items(surface: .drawer, isFinder: false, isKept: false, isMessaging: false)
        XCTAssertEqual(items, [.keep(isChecked: false)])
    }

    func testDrawerMessagingAppShowsKeepAndCheckedMessaging() {
        let items = AppMembershipMenuPlan.items(surface: .drawer, isFinder: false, isKept: true, isMessaging: true)
        XCTAssertEqual(items, [.keep(isChecked: true), .messaging(isChecked: true)])
    }

    /// 2026-08-20: Finder is included in the unified keep checkbox, but the messaging item is still not offered (on both surfaces).
    func testFinderShowsOnlyKeep() {
        XCTAssertEqual(
            AppMembershipMenuPlan.items(surface: .strip, isFinder: true, isKept: true, isMessaging: false),
            [.keep(isChecked: true)]
        )
        XCTAssertEqual(
            AppMembershipMenuPlan.items(surface: .drawer, isFinder: true, isKept: false, isMessaging: false),
            [.keep(isChecked: false)]
        )
    }

    func testKeepCheckStateReflectsKept() {
        let unchecked = AppMembershipMenuPlan.items(surface: .strip, isFinder: false, isKept: false, isMessaging: false)
        XCTAssertEqual(unchecked.first, .keep(isChecked: false))
        let checked = AppMembershipMenuPlan.items(surface: .strip, isFinder: false, isKept: true, isMessaging: false)
        XCTAssertEqual(checked.first, .keep(isChecked: true))
    }

    func testKeepAlwaysPrecedesMessagingCommand() {
        let items = AppMembershipMenuPlan.items(surface: .strip, isFinder: false, isKept: false, isMessaging: true)
        XCTAssertEqual(items.first, .keep(isChecked: false))
        XCTAssertEqual(items.last, .messaging(isChecked: true))
    }

    func testMessagingCheckStateReflectsMembership() {
        XCTAssertEqual(
            AppMembershipMenuPlan.items(surface: .strip, isFinder: false, isKept: false, isMessaging: false).last,
            .messaging(isChecked: false)
        )
        XCTAssertEqual(
            AppMembershipMenuPlan.items(surface: .strip, isFinder: false, isKept: false, isMessaging: true).last,
            .messaging(isChecked: true)
        )
    }
}
