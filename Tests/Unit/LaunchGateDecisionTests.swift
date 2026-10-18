import Foundation
import XCTest

final class LaunchGateDecisionTests: XCTestCase {
    private func process(
        alive: Bool = true,
        generationMatches: Bool = true,
        policy: LaunchGateDecision.ActivationPolicy = .regular,
        finished: Bool = true,
        declaresNoWindow: Bool = false
    ) -> LaunchGateDecision.ProcessObservation {
        LaunchGateDecision.ProcessObservation(
            isAlive: alive,
            generationMatches: generationMatches,
            activationPolicy: policy,
            isFinishedLaunching: finished,
            bundleDeclaresNoWindow: declaresNoWindow
        )
    }

    private func verdict(
        openFailed: Bool = false,
        hasNewRealWindow: Bool = false,
        process: LaunchGateDecision.ProcessObservation? = nil,
        hasOtherRegularProcess: Bool = false,
        elapsed: TimeInterval = 0
    ) -> LaunchGateDecision.Verdict {
        LaunchGateDecision.evaluate(
            LaunchGateDecision.Observation(
                openFailed: openFailed,
                hasNewRealWindow: hasNewRealWindow,
                launchedProcess: process,
                hasOtherRegularProcess: hasOtherRegularProcess,
                elapsed: elapsed
            )
        )
    }

    func testRunningAccessoryProcessNeedsNoSessionOnceFinishedLaunching() {
        XCTAssertTrue(
            LaunchGateDecision.runningProcessNeedsNoSession(
                activationPolicy: .accessory, isFinishedLaunching: true, bundleDeclaresNoWindow: false
            )
        )
        XCTAssertFalse(
            LaunchGateDecision.runningProcessNeedsNoSession(
                activationPolicy: .accessory, isFinishedLaunching: false, bundleDeclaresNoWindow: false
            )
        )
    }

    func testRunningProhibitedProcessNeedsNoSessionOnlyWithNoWindowDeclaration() {
        XCTAssertTrue(
            LaunchGateDecision.runningProcessNeedsNoSession(
                activationPolicy: .prohibited, isFinishedLaunching: true, bundleDeclaresNoWindow: true
            )
        )
        XCTAssertFalse(
            LaunchGateDecision.runningProcessNeedsNoSession(
                activationPolicy: .prohibited, isFinishedLaunching: true, bundleDeclaresNoWindow: false
            )
        )
    }

    func testRunningRegularOrUnknownProcessStillGetsASession() {
        for policy in [LaunchGateDecision.ActivationPolicy.regular, .unknown] {
            XCTAssertFalse(
                LaunchGateDecision.runningProcessNeedsNoSession(
                    activationPolicy: policy, isFinishedLaunching: true, bundleDeclaresNoWindow: true
                ),
                "\(policy)"
            )
        }
    }

    func testOpenFailureWinsOverEveryOtherReleaseReason() {
        XCTAssertEqual(
            verdict(
                openFailed: true,
                hasNewRealWindow: true,
                process: process(alive: false),
                elapsed: 20
            ),
            .release(.openFailed)
        )
    }

    func testNewRealWindowWinsOverProcessAndTimeoutFacts() {
        XCTAssertEqual(
            verdict(hasNewRealWindow: true, process: process(alive: false), elapsed: 20),
            .release(.realWindow)
        )
    }

    func testDeadProcessReleasesOnlyWithoutAnotherRegularProcess() {
        let dead = process(alive: false)
        XCTAssertEqual(verdict(process: dead, elapsed: 2), .release(.processGone))
        XCTAssertEqual(
            verdict(process: dead, hasOtherRegularProcess: true, elapsed: 2),
            .hold
        )
    }

    func testGenerationMismatchUsesTheProcessGoneRule() {
        let reusedPID = process(generationMatches: false)
        XCTAssertEqual(verdict(process: reusedPID, elapsed: 2), .release(.processGone))
        XCTAssertEqual(
            verdict(process: reusedPID, hasOtherRegularProcess: true, elapsed: 2),
            .hold
        )
    }

    func testAccessoryRequiresElapsedAndFinishedLaunchingGates() {
        let unfinished = process(policy: .accessory, finished: false)
        let finished = process(policy: .accessory, finished: true)

        XCTAssertEqual(verdict(process: unfinished, elapsed: 1.49), .hold)
        XCTAssertEqual(verdict(process: unfinished, elapsed: 1.5), .hold)
        XCTAssertEqual(verdict(process: finished, elapsed: 0.2), .hold)
        XCTAssertEqual(
            verdict(process: finished, elapsed: 1.5),
            .release(.accessoryProcess)
        )
    }

    func testAccessoryDoesNotReleaseWhileAnotherRegularProcessExists() {
        XCTAssertEqual(
            verdict(
                process: process(policy: .accessory),
                hasOtherRegularProcess: true,
                elapsed: 3
            ),
            .hold
        )
    }

    func testProhibitedRequiresExplicitNoWindowDeclaration() {
        XCTAssertEqual(
            verdict(process: process(policy: .prohibited), elapsed: 3),
            .hold
        )
        XCTAssertEqual(
            verdict(
                process: process(policy: .prohibited, declaresNoWindow: true),
                elapsed: 3
            ),
            .release(.accessoryProcess)
        )
    }

    func testProhibitedAlsoRequiresElapsedFinishedAndNoOtherRegularProcess() {
        XCTAssertEqual(
            verdict(
                process: process(policy: .prohibited, finished: false, declaresNoWindow: true),
                elapsed: 3
            ),
            .hold
        )
        XCTAssertEqual(
            verdict(
                process: process(policy: .prohibited, declaresNoWindow: true),
                elapsed: 1.49
            ),
            .hold
        )
        XCTAssertEqual(
            verdict(
                process: process(policy: .prohibited, declaresNoWindow: true),
                hasOtherRegularProcess: true,
                elapsed: 3
            ),
            .hold
        )
    }

    func testRegularAndUnknownPoliciesHoldBeforeTimeout() {
        XCTAssertEqual(verdict(process: process(policy: .regular), elapsed: 19.99), .hold)
        XCTAssertEqual(verdict(process: process(policy: .unknown), elapsed: 19.99), .hold)
    }

    func testTimeoutBoundaryWithNoTerminalProcessFact() {
        XCTAssertEqual(verdict(elapsed: 19.99), .hold)
        XCTAssertEqual(verdict(elapsed: 20), .release(.timeout))
        XCTAssertEqual(
            verdict(process: process(policy: .regular), elapsed: 20),
            .release(.timeout)
        )
    }

    func testEvaluationIsPureForTheSameObservation() {
        let observation = LaunchGateDecision.Observation(
            openFailed: false,
            hasNewRealWindow: false,
            launchedProcess: process(policy: .regular),
            hasOtherRegularProcess: false,
            elapsed: 3
        )

        XCTAssertEqual(
            LaunchGateDecision.evaluate(observation),
            LaunchGateDecision.evaluate(observation)
        )
    }
}

final class LaunchWindowBaselineDecisionTests: XCTestCase {
    func testUnchangedBaselineHasNoNewWindow() {
        let baseline: Set = ["seat-1", "seat-2"]

        XCTAssertFalse(
            LaunchWindowBaselineDecision.hasNewWindow(
                baseline: baseline,
                current: baseline
            )
        )
    }

    func testNewSameBundleIdentityIsDetectedWithoutProcessMatching() {
        let baseline: Set = ["seat-host-process"]
        let current: Set = ["seat-host-process", "seat-window-process"]

        XCTAssertTrue(
            LaunchWindowBaselineDecision.hasNewWindow(
                baseline: baseline,
                current: current
            )
        )
    }
}

final class LaunchSessionTokenRegistryTests: XCTestCase {
    private struct Session: Equatable {
        var marker: String
    }

    func testDuplicateBeginIsRejectedWithoutCallingFactory() {
        var registry = LaunchSessionTokenRegistry<Session>()
        var factoryCallCount = 0

        let first = registry.begin(bundleID: "com.example.app") { token in
            factoryCallCount += 1
            return Session(marker: "first-\(token)")
        }
        let duplicate = registry.begin(bundleID: "com.example.app") { _ in
            factoryCallCount += 1
            return Session(marker: "duplicate")
        }

        XCTAssertNotNil(first)
        XCTAssertNil(duplicate)
        XCTAssertEqual(factoryCallCount, 1)
        XCTAssertEqual(registry.bundleIDs, ["com.example.app"])
    }

    func testStaleUpdateAndReleaseCannotAffectNewSession() {
        var registry = LaunchSessionTokenRegistry<Session>()
        let oldToken = registry.begin(bundleID: "com.example.app") { _ in
            Session(marker: "old")
        }!
        XCTAssertEqual(
            registry.remove(bundleID: "com.example.app", token: oldToken),
            Session(marker: "old")
        )

        let currentToken = registry.begin(bundleID: "com.example.app") { _ in
            Session(marker: "current")
        }!
        XCTAssertNotEqual(oldToken, currentToken)

        XCTAssertFalse(
            registry.update(bundleID: "com.example.app", token: oldToken) {
                $0.marker = "stale-update"
            }
        )
        XCTAssertNil(registry.remove(bundleID: "com.example.app", token: oldToken))
        XCTAssertEqual(registry.entry(for: "com.example.app")?.token, currentToken)
        XCTAssertEqual(registry.entry(for: "com.example.app")?.value.marker, "current")
    }

    func testCurrentTokenCanUpdateAndReleaseSession() {
        var registry = LaunchSessionTokenRegistry<Session>()
        let token = registry.begin(bundleID: "com.example.app") { _ in
            Session(marker: "initial")
        }!

        XCTAssertTrue(
            registry.update(bundleID: "com.example.app", token: token) {
                $0.marker = "updated"
            }
        )
        XCTAssertEqual(
            registry.remove(bundleID: "com.example.app", token: token),
            Session(marker: "updated")
        )
        XCTAssertNil(registry.entry(for: "com.example.app"))
        XCTAssertTrue(registry.bundleIDs.isEmpty)
    }

    func testRemoveAllReturnsEveryValueAndClearsRegistry() {
        var registry = LaunchSessionTokenRegistry<Session>()
        _ = registry.begin(bundleID: "com.example.z") { _ in Session(marker: "z") }
        _ = registry.begin(bundleID: "com.example.a") { _ in Session(marker: "a") }

        XCTAssertEqual(
            registry.currentEntries.map { $0.bundleID },
            ["com.example.a", "com.example.z"]
        )
        XCTAssertEqual(
            registry.removeAll(),
            [Session(marker: "a"), Session(marker: "z")]
        )
        XCTAssertTrue(registry.currentEntries.isEmpty)
        XCTAssertTrue(registry.bundleIDs.isEmpty)
    }
}
