import XCTest

final class FinderTaskbarPolicyTests: XCTestCase {

    func testIsFinderMatchesOnlyFinder() {
        XCTAssertTrue(FinderTaskbarPolicy.isFinder("com.apple.finder"))
        XCTAssertFalse(FinderTaskbarPolicy.isFinder("com.apple.finder.helper"))
        XCTAssertFalse(FinderTaskbarPolicy.isFinder(nil))
        XCTAssertFalse(FinderTaskbarPolicy.isFinder(""))
    }

    /// After unticking "Keep in Dock", Finder's app-level entry is no longer shown -- this is the gate for the whole feature.
    func testAppLevelEntryFollowsKept() {
        XCTAssertTrue(FinderTaskbarPolicy.showsAppLevelEntry(isKept: true))
        XCTAssertFalse(FinderTaskbarPolicy.showsAppLevelEntry(isKept: false))
    }

    /// With both drawer and keep opened up, the messaging zone is still not opened up.
    func testMessagingStaysClosedToFinder() {
        XCTAssertFalse(FinderTaskbarPolicy.canMarkMessaging(FinderTaskbarPolicy.bundleID))
        XCTAssertFalse(FinderTaskbarPolicy.canMarkMessaging(""))
        XCTAssertTrue(FinderTaskbarPolicy.canMarkMessaging("com.example.chat"))
    }
}
