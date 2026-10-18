import XCTest
@testable import NeoBar

final class LauncherChipVisualPlanTests: XCTestCase {

    // The running dot is the **only** state signal (after the icon dimming was removed on 2026-08-02): running = dot, quit = no dot.
    // Independent of the section it is in -- the messaging area, the lower drawer, and kept icons are treated alike.
    func testRunningDotFollowsProcessStateOnly() {
        XCTAssertTrue(LauncherChipVisualPlan.visual(isRunning: true).showsRunningDot)
        XCTAssertFalse(LauncherChipVisualPlan.visual(isRunning: false).showsRunningDot)
    }
}

final class AppDisplayNameCacheTests: XCTestCase {
    func testSuccessfulResolutionIsCached() {
        let cache = AppDisplayNameCache()
        var loads = 0

        XCTAssertEqual(cache.value(for: "com.example.app") { loads += 1; return "Example" }, "Example")
        XCTAssertEqual(cache.value(for: "com.example.app") { loads += 1; return "Changed" }, "Example")
        XCTAssertEqual(loads, 1)
    }

    func testFailedResolutionIsNotCached() {
        let cache = AppDisplayNameCache()
        var loads = 0

        XCTAssertEqual(cache.value(for: "com.example.app") { loads += 1; return nil }, "com.example.app")
        XCTAssertEqual(cache.value(for: "com.example.app") { loads += 1; return "Example" }, "Example")
        XCTAssertEqual(loads, 2)
    }

    func testInvalidationOnlyClearsTheNamedBundle() {
        let cache = AppDisplayNameCache()
        _ = cache.value(for: "com.example.a") { "A" }
        _ = cache.value(for: "com.example.b") { "B" }
        cache.invalidate(bundleID: "com.example.a")

        XCTAssertEqual(cache.value(for: "com.example.a") { "A2" }, "A2")
        XCTAssertEqual(cache.value(for: "com.example.b") { "B2" }, "B")
    }
}
