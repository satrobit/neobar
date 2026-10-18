import XCTest
@testable import NeoBar

/// Three rules for how the messaging area identifies the main window (2026-08-23). Each corresponds to the shape of a real app; do not delete.
final class MessagingMainWindowDecisionTests: XCTestCase {
    private typealias W = MessagingMainWindowDecision.WindowFact
    private let wechat = "com.tencent.xinWeChat"
    private let telegram = "ru.keepcoder.Telegram"

    /// Rule 1: title match takes priority, even if there are other windows (Feishu main window + a standalone chat window).
    func testTitleMatchWinsOverEverything() {
        let id = MessagingMainWindowDecision.mainWindowID(
            bundleID: "com.electron.lark",
            windows: [W(id: "chat", title: "张三"), W(id: "main", title: "飞书")],
            titleMatchesAppName: { $0 == "飞书" }
        )
        XCTAssertEqual(id, "main")
    }

    /// Shape of WeChat's cold start (measured 2026-08-23): the login window (700x640, the seat remains after order-out) and the main window are both named "WeChat",
    /// and the login window is created first. The main window must be picked; the first window by creation order must not be taken.
    func testAmongSeveralTitleMatchesTheLargestVisibleWins() {
        let id = MessagingMainWindowDecision.mainWindowID(
            bundleID: wechat,
            windows: [W(id: "login", title: "微信", area: 700 * 640),
                      W(id: "main", title: "微信", area: 1220 * 870)],
            titleMatchesAppName: { $0 == "微信" }
        )
        XCTAssertEqual(id, "main")
    }

    /// Main window minimized, login window not: still can't bind the icon to the login window? No -- a minimized main window yields to a non-minimized one:
    /// when several windows share the name, "not minimized" takes priority over "area", otherwise clicking the icon would "restore" a window that is never visible.
    func testNonMinimizedTitleMatchBeatsLargerMinimizedOne() {
        let id = MessagingMainWindowDecision.mainWindowID(
            bundleID: wechat,
            windows: [W(id: "big-minimized", title: "微信", isMinimized: true, area: 1220 * 870),
                      W(id: "small-visible", title: "微信", area: 700 * 640)],
            titleMatchesAppName: { $0 == "微信" }
        )
        XCTAssertEqual(id, "small-visible")
    }

    /// When all are identical, keep the one that appeared first (stable, no jitter between the two windows).
    func testEqualTitleMatchesKeepFirst() {
        let id = MessagingMainWindowDecision.mainWindowID(
            bundleID: wechat,
            windows: [W(id: "a", title: "微信"), W(id: "b", title: "微信")],
            titleMatchesAppName: { $0 == "微信" }
        )
        XCTAssertEqual(id, "a")
    }

    /// Rule 2: a single-window app whose title is not the app name (the shape of Telegram / Messages / Slack).
    func testSingleWindowIsMainEvenWithoutTitleMatch() {
        let id = MessagingMainWindowDecision.mainWindowID(
            bundleID: telegram,
            windows: [W(id: "only", title: "Saved Messages")],
            titleMatchesAppName: { _ in false }
        )
        XCTAssertEqual(id, "only")
    }

    /// Origin on 2026-07-21: after WeChat's main window was closed only "Notes" was left -> it must be "no main window", so clicking the icon will bring the main window back.
    func testWeChatNotesAloneIsNotMain() {
        let id = MessagingMainWindowDecision.mainWindowID(
            bundleID: wechat,
            windows: [W(id: "notes", title: "笔记")],
            titleMatchesAppName: { _ in false }
        )
        XCTAssertNil(id)
    }

    /// The exclusion table only removes: Notes + a window with an unrecognizable name -> the remaining one is the main window (WeChat when the alias is ineffective).
    func testExclusionLeavesTheOtherWindowAsMain() {
        let id = MessagingMainWindowDecision.mainWindowID(
            bundleID: wechat,
            windows: [W(id: "notes", title: " 笔记 "), W(id: "main", title: "Weixin")],
            titleMatchesAppName: { _ in false }
        )
        XCTAssertEqual(id, "main", "排除表按归一化标题比较")
    }

    /// Rule 3: two or more windows that can't be recognized -> nil, and the caller falls back to the app-level switch, with no guessing.
    func testAmbiguousWindowsYieldNil() {
        let id = MessagingMainWindowDecision.mainWindowID(
            bundleID: "com.example.chat",
            windows: [W(id: "a", title: "Alice"), W(id: "b", title: "Bob")],
            titleMatchesAppName: { _ in false }
        )
        XCTAssertNil(id)
    }

    func testNoWindowsYieldNil() {
        XCTAssertNil(MessagingMainWindowDecision.mainWindowID(
            bundleID: telegram, windows: [], titleMatchesAppName: { _ in true }))
    }

    /// The exclusion table only applies to its own bundle: the sole window of another app named "Notes" is still the main window.
    func testExclusionIsScopedToItsBundle() {
        let id = MessagingMainWindowDecision.mainWindowID(
            bundleID: "com.example.notesapp",
            windows: [W(id: "n", title: "笔记")],
            titleMatchesAppName: { _ in false }
        )
        XCTAssertEqual(id, "n")
    }
}
