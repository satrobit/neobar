import XCTest

final class AppFallbackChipDecisionTests: XCTestCase {
    private func process(
        _ pid: pid_t,
        bundleID: String? = "com.example.app",
        appName: String = "Example",
        hasSeats: Bool,
        isFrontmost: Bool = false
    ) -> AppFallbackChipDecision.Process {
        .init(
            pid: pid,
            bundleID: bundleID,
            appName: appName,
            hasSeats: hasSeats,
            isFrontmost: isFrontmost
        )
    }

    func testAnyRealSeatSuppressesFallbackForEntireBundle() {
        let result = AppFallbackChipDecision.fallbacks(for: [
            process(10, hasSeats: false),
            process(20, hasSeats: true),
            process(30, hasSeats: false),
        ])

        XCTAssertEqual(result, [])
    }

    func testAllZeroSeatProcessesProduceOneFallbackUsingLastProcess() {
        let result = AppFallbackChipDecision.fallbacks(for: [
            process(10, hasSeats: false),
            process(20, hasSeats: false),
        ])

        XCTAssertEqual(result, [.init(pid: 20, windowID: "app-com.example.app")])
    }

    func testFrontmostZeroSeatProcessWinsRepresentativeSelection() {
        let result = AppFallbackChipDecision.fallbacks(for: [
            process(10, hasSeats: false, isFrontmost: true),
            process(20, hasSeats: false),
        ])

        XCTAssertEqual(result, [.init(pid: 10, windowID: "app-com.example.app")])
    }

    func testFallbackReturnsWhenLastRealSeatDisappears() {
        let before = AppFallbackChipDecision.fallbacks(for: [
            process(10, hasSeats: true),
            process(20, hasSeats: false),
        ])
        let after = AppFallbackChipDecision.fallbacks(for: [
            process(20, hasSeats: false),
        ])

        XCTAssertEqual(before, [])
        XCTAssertEqual(after, [.init(pid: 20, windowID: "app-com.example.app")])
    }

    func testSingleZeroSeatProcessKeepsFallback() {
        XCTAssertEqual(
            AppFallbackChipDecision.fallbacks(for: [process(10, hasSeats: false)]),
            [.init(pid: 10, windowID: "app-com.example.app")]
        )
    }

    func testUnbundledProcessesNeverMergeOrCollideByAppName() {
        let result = AppFallbackChipDecision.fallbacks(for: [
            process(10, bundleID: nil, appName: "Same Name", hasSeats: false),
            process(20, bundleID: nil, appName: "Same Name", hasSeats: false),
        ])

        XCTAssertEqual(result, [
            .init(pid: 10, windowID: "app-unbundled-10"),
            .init(pid: 20, windowID: "app-unbundled-20"),
        ])
    }

    func testFallbackOrderFollowsRepresentativePositions() {
        let result = AppFallbackChipDecision.fallbacks(for: [
            process(10, bundleID: nil, appName: "No Bundle", hasSeats: false),
            process(20, bundleID: "com.example.a", hasSeats: false),
            process(30, bundleID: "com.example.a", hasSeats: false),
            process(40, bundleID: "com.example.b", hasSeats: false),
        ])

        XCTAssertEqual(result.map(\.pid), [10, 30, 40])
    }
}
