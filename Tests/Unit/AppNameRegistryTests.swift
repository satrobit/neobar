import XCTest
@testable import NeoBar

/// The name side of the messaging-area absorption criterion "window title == app name".
///
/// These tests exist because of a real-device bug (2026-08-11): the app name used to be looked up in LaunchServices on every frame,
/// and a single transient empty lookup made Feishu and WeChat drop out of absorption **at the same time** -> each of the two apps rendered a card in both the messaging area and the live area
/// -> the whole row widened and pushed the right side away, and the mismatch state stuck until the next unrelated reflow. QQ was never affected because its bundle-derived name already contains `qq`;
/// that asymmetry is exactly the evidence that located the root cause.
final class AppNameRegistryTests: XCTestCase {

    /// A controllable dual loader: the bundle name is fixed, and the running name can "glitch" at any time.
    private final class Env {
        var bundleNames: [String: Set<String>] = [:]
        var runningNames: [String: String] = [:]
        private(set) var bundleLoadCount = 0
        private(set) var runningLoadCount = 0

        func makeRegistry() -> AppNameRegistry {
            AppNameRegistry(
                bundleNamesLoader: { [unowned self] bid in
                    self.bundleLoadCount += 1
                    return self.bundleNames[bid] ?? []
                },
                runningNameLoader: { [unowned self] bid in
                    self.runningLoadCount += 1
                    return self.runningNames[bid]
                }
            )
        }
    }

    // MARK: - Product aliases (2026-08-23)

    /// The WeChat main window in the English UI is called `Weixin`: the bundle names only have wechat, the running name is the Chinese name of WeChat, and none of the three equals it.
    /// The alias table must take effect on **both** paths that create entries (matches first / observe first).
    func testProductAliasMatchesWeixinTitle() {
        let env = Env()
        env.bundleNames["com.tencent.xinWeChat"] = ["wechat"]
        env.runningNames["com.tencent.xinWeChat"] = "微信"
        let registry = env.makeRegistry()
        XCTAssertTrue(registry.matches(title: "Weixin", bundleID: "com.tencent.xinWeChat"))
        XCTAssertTrue(registry.matches(title: " weixin ", bundleID: "com.tencent.xinWeChat"), "别名同样走归一化")
        XCTAssertTrue(registry.matches(title: "微信", bundleID: "com.tencent.xinWeChat"), "别名是加法，原有名字不受影响")

        let observedFirst = env.makeRegistry()
        observedFirst.observe(name: "微信", for: "com.tencent.xinWeChat")
        XCTAssertTrue(observedFirst.matches(title: "Weixin", bundleID: "com.tencent.xinWeChat"))
    }

    func testProductAliasIsScopedToItsBundle() {
        let env = Env()
        env.bundleNames["com.electron.lark"] = ["feishu", "lark"]
        XCTAssertFalse(env.makeRegistry().matches(title: "Weixin", bundleID: "com.electron.lark"))
    }

    // MARK: - Regression lock for this bug

    /// Once a running name has been observed successfully, matching must continue no matter how LaunchServices glitches afterwards.
    /// If this one fails = the bug of Feishu/WeChat duplicate cards is back.
    func testObservedNameSurvivesLaterLookupFailure() {
        let env = Env()
        env.bundleNames["com.electron.lark"] = ["feishu", "lark"]   // Measured: the Chinese name is not in the bundle
        env.runningNames["com.electron.lark"] = "飞书"
        let registry = env.makeRegistry()

        XCTAssertTrue(registry.matches(title: "飞书", bundleID: "com.electron.lark"))

        // LaunchServices glitch: queries start returning nil.
        env.runningNames.removeValue(forKey: "com.electron.lark")

        XCTAssertTrue(registry.matches(title: "飞书", bundleID: "com.electron.lark"),
                      "已经记住的名字不能因为一次查询失败就丢掉")
    }

    /// No further queries after a successful observation: both part of the fix and the basis for zero LaunchServices I/O per frame.
    func testRunningLookupStopsAfterFirstSuccess() {
        let env = Env()
        env.bundleNames["com.tencent.xinWeChat"] = ["wechat"]
        env.runningNames["com.tencent.xinWeChat"] = "微信"
        let registry = env.makeRegistry()

        for _ in 0..<5 {
            XCTAssertTrue(registry.matches(title: "微信", bundleID: "com.tencent.xinWeChat"))
        }
        XCTAssertEqual(env.runningLoadCount, 1)
        XCTAssertEqual(env.bundleLoadCount, 1, "包内名也只读一次盘")
    }

    // MARK: - Self-healing: an incomplete set must not be treated as a complete cache

    /// If the first frame of a cold start happens to glitch, the incomplete set of "bundle names only" must not be pinned permanently --
    /// that would turn a transient fault into a permanent one, worse than before the fix. It must retry every time until an observation succeeds.
    func testKeepsRetryingUntilFirstSuccessfulObservation() {
        let env = Env()
        env.bundleNames["com.electron.lark"] = ["feishu", "lark"]
        let registry = env.makeRegistry()

        XCTAssertFalse(registry.matches(title: "飞书", bundleID: "com.electron.lark"))
        XCTAssertFalse(registry.matches(title: "飞书", bundleID: "com.electron.lark"))
        XCTAssertEqual(env.runningLoadCount, 2, "还没观测成功就得继续重试")

        env.runningNames["com.electron.lark"] = "飞书"
        XCTAssertTrue(registry.matches(title: "飞书", bundleID: "com.electron.lark"))
    }

    /// An empty or whitespace-only running name does not count as a successful observation, otherwise it would block the retry path.
    func testBlankRunningNameDoesNotCountAsObserved() {
        let env = Env()
        env.bundleNames["com.electron.lark"] = ["lark"]
        env.runningNames["com.electron.lark"] = "   "
        let registry = env.makeRegistry()

        XCTAssertFalse(registry.matches(title: "飞书", bundleID: "com.electron.lark"))
        env.runningNames["com.electron.lark"] = "飞书"
        XCTAssertTrue(registry.matches(title: "飞书", bundleID: "com.electron.lark"))
    }

    // MARK: - The independent path of bundle-derived names (why QQ never mismatches)

    func testBundleDerivedNameMatchesWithoutAnySuccessfulLookup() {
        let env = Env()
        env.bundleNames["com.tencent.qq"] = ["qq"]     // The running name can never be found
        let registry = env.makeRegistry()

        XCTAssertTrue(registry.matches(title: "QQ", bundleID: "com.tencent.qq"))
    }

    // MARK: - Direct external feeding (names obtained for free from the NSWorkspace launch notification)

    func testObserveSeedsBothBundleAndRunningNamesWithoutLookup() {
        let env = Env()
        env.bundleNames["com.electron.lark"] = ["feishu", "lark"]
        let registry = env.makeRegistry()

        registry.observe(name: "飞书", for: "com.electron.lark")

        XCTAssertEqual(registry.knownNames(for: "com.electron.lark"), ["feishu", "lark", "飞书"],
                       "投喂时必须把包内名一起带上，否则包内名再也补不回来")
        XCTAssertEqual(env.runningLoadCount, 0, "已经有权威名字了,不该再查")
    }

    func testObserveIsMonotonic() {
        let env = Env()
        env.bundleNames["com.foo.bar"] = []
        let registry = env.makeRegistry()

        registry.observe(name: "Foo", for: "com.foo.bar")
        registry.observe(name: "福", for: "com.foo.bar")

        XCTAssertEqual(registry.knownNames(for: "com.foo.bar"), ["foo", "福"])
    }

    func testObserveIgnoresBlankName() {
        let env = Env()
        env.bundleNames["com.foo.bar"] = ["bar"]
        env.runningNames["com.foo.bar"] = "Bar"
        let registry = env.makeRegistry()

        registry.observe(name: "  ", for: "com.foo.bar")
        // An empty feed must not count as a successful observation, otherwise the real name could never be filled in again.
        XCTAssertTrue(registry.matches(title: "Bar", bundleID: "com.foo.bar"))
    }

    // MARK: - Invalidation

    func testInvalidateClearsEverythingAndRelearns() {
        let env = Env()
        env.bundleNames["com.electron.lark"] = ["lark"]
        env.runningNames["com.electron.lark"] = "飞书"
        let registry = env.makeRegistry()
        XCTAssertTrue(registry.matches(title: "飞书", bundleID: "com.electron.lark"))

        // The app switched versions and its name changed too.
        registry.invalidate(bundleID: "com.electron.lark")
        env.runningNames["com.electron.lark"] = "Lark"

        XCTAssertEqual(registry.knownNames(for: "com.electron.lark"), ["lark"])
        XCTAssertFalse(registry.matches(title: "飞书", bundleID: "com.electron.lark"))
    }

    // MARK: - Normalization and empty titles

    func testEmptyOrBlankTitleNeverMatches() {
        let env = Env()
        env.bundleNames["com.foo.bar"] = ["bar", ""]
        let registry = env.makeRegistry()

        XCTAssertFalse(registry.matches(title: "", bundleID: "com.foo.bar"))
        XCTAssertFalse(registry.matches(title: "   \n ", bundleID: "com.foo.bar"))
    }

    func testMatchingTrimsAndLowercases() {
        let env = Env()
        env.bundleNames["com.foo.bar"] = []
        env.runningNames["com.foo.bar"] = "  MyApp  "
        let registry = env.makeRegistry()

        XCTAssertTrue(registry.matches(title: "myapp", bundleID: "com.foo.bar"))
        XCTAssertTrue(registry.matches(title: " MYAPP ", bundleID: "com.foo.bar"))
        XCTAssertFalse(registry.matches(title: "my app", bundleID: "com.foo.bar"))
    }

    func testUnknownBundleMatchesNothing() {
        let env = Env()
        let registry = env.makeRegistry()
        XCTAssertFalse(registry.matches(title: "Whatever", bundleID: "com.unknown"))
    }
}
