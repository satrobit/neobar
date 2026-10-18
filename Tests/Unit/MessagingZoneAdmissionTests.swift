import XCTest
@testable import NeoBar

final class MessagingZoneAdmissionTests: XCTestCase {

    /// Map the "app name" table onto the exact-equality semantics of `titleMatchesAppName`.
    private func matcher(_ names: [String: String]) -> (String, String) -> Bool {
        { title, bundleID in
            guard let name = names[bundleID] else { return false }
            return title.caseInsensitiveCompare(name) == .orderedSame
        }
    }

    private func win(_ bundleID: String, _ title: String, fallback: Bool = false) -> MessagingZoneAdmission.WindowFact {
        .init(bundleID: bundleID, title: title, isAppLevelFallback: fallback)
    }

    // MARK: - Apps whose main window can be recognized enter the admission set

    func testTitleMatchingWindowQualifiesItsApp() {
        let ids = MessagingZoneAdmission.mainWindowIdentifiableBundleIDs(
            windows: [win("com.tencent.xinWeChat", "微信")],
            titleMatchesAppName: matcher(["com.tencent.xinWeChat": "微信"])
        )
        XCTAssertEqual(ids, ["com.tencent.xinWeChat"])
    }

    func testAppWithBothMainAndOtherWindowsStillQualifies() {
        // WeChat main window + a "Notes" window coexist: matched by the main window.
        let ids = MessagingZoneAdmission.mainWindowIdentifiableBundleIDs(
            windows: [win("com.tencent.xinWeChat", "笔记"),
                      win("com.tencent.xinWeChat", "微信")],
            titleMatchesAppName: matcher(["com.tencent.xinWeChat": "微信"])
        )
        XCTAssertEqual(ids, ["com.tencent.xinWeChat"])
    }

    // MARK: - Unrecognizable ones are kept out (the core of this fix)

    func testCatalystStyleNumericTitleNeverQualifies() {
        // Apple "Messages": the title is a UIScene session number, which never equals the app name.
        let ids = MessagingZoneAdmission.mainWindowIdentifiableBundleIDs(
            windows: [win("com.apple.MobileSMS", "10691420171100425")],
            titleMatchesAppName: matcher(["com.apple.MobileSMS": "信息"])
        )
        XCTAssertTrue(ids.isEmpty, "认不出主窗口的应用不得进入消息区")
    }

    func testTerminalWithCommandTitleNeverQualifies() {
        // Ghostty: misjudged as looking like a messaging app because of its social category, but the window title is the command name.
        let ids = MessagingZoneAdmission.mainWindowIdentifiableBundleIDs(
            windows: [win("com.mitchellh.ghostty", "dev@mac: ~/Projects")],
            titleMatchesAppName: matcher(["com.mitchellh.ghostty": "Ghostty"])
        )
        XCTAssertTrue(ids.isEmpty)
    }

    func testWeChatWithOnlyNonMainWindowDoesNotQualifyThisRound() {
        // Main window closed, only "Notes" remains: unrecognizable at this moment. The caller avoids jitter via "once passed, permanently on the list",
        // and this decision only reports the current state faithfully.
        let ids = MessagingZoneAdmission.mainWindowIdentifiableBundleIDs(
            windows: [win("com.tencent.xinWeChat", "笔记")],
            titleMatchesAppName: matcher(["com.tencent.xinWeChat": "微信"])
        )
        XCTAssertTrue(ids.isEmpty)
    }

    // MARK: - Boundaries

    func testAppLevelFallbackCannotProveIdentifiability() {
        // An app-* fallback item is not a real window; even if its title happens to equal the app name it doesn't count.
        let ids = MessagingZoneAdmission.mainWindowIdentifiableBundleIDs(
            windows: [win("com.tencent.xinWeChat", "微信", fallback: true)],
            titleMatchesAppName: matcher(["com.tencent.xinWeChat": "微信"])
        )
        XCTAssertTrue(ids.isEmpty)
    }

    func testEmptyBundleIDIgnored() {
        let ids = MessagingZoneAdmission.mainWindowIdentifiableBundleIDs(
            windows: [win("", "微信")],
            titleMatchesAppName: { _, _ in true }
        )
        XCTAssertTrue(ids.isEmpty)
    }

    func testMultipleAppsResolveIndependently() {
        let ids = MessagingZoneAdmission.mainWindowIdentifiableBundleIDs(
            windows: [win("com.tencent.qq", "QQ"),
                      win("com.apple.MobileSMS", "10691420171100425"),
                      win("com.tencent.xinWeChat", "微信")],
            titleMatchesAppName: matcher(["com.tencent.qq": "QQ",
                                          "com.apple.MobileSMS": "信息",
                                          "com.tencent.xinWeChat": "微信"])
        )
        XCTAssertEqual(ids, ["com.tencent.qq", "com.tencent.xinWeChat"])
    }

    func testNoWindowsYieldsEmpty() {
        XCTAssertTrue(MessagingZoneAdmission.mainWindowIdentifiableBundleIDs(
            windows: [], titleMatchesAppName: { _, _ in true }
        ).isEmpty)
    }
}
