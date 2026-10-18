import XCTest
@testable import NeoBar

final class RunningStateSweepDecisionTests: XCTestCase {
    private typealias Decision = RunningStateSweepDecision

    private func generation(_ pid: pid_t, second: Int64 = 1) -> Decision.Generation {
        Decision.Generation(pid: pid, startTimeSeconds: second, startTimeMicroseconds: 0)
    }

    func testDeadTrackedProcessIsRemovedWhenWorkspaceObservationIsMissing() {
        let old = generation(10)
        let plan = Decision.plan(
            trackedByPID: [10: .init(generation: old, bundleID: "com.dead", isHidden: false)],
            observationsByPID: [:],
            currentGenerationsByPID: [10: nil]
        )
        XCTAssertEqual(plan.removals, [.init(pid: 10, generation: old, reason: .processGone)])
    }

    func testMissingWorkspaceObservationForLiveProcessIsUnknownAndPreserved() {
        let live = generation(11)
        let plan = Decision.plan(
            trackedByPID: [11: .init(generation: live, bundleID: "com.live", isHidden: false)],
            observationsByPID: [:],
            currentGenerationsByPID: [11: live]
        )
        XCTAssertTrue(plan.removals.isEmpty)
        XCTAssertTrue(plan.nonRegularConfirmations.isEmpty)
    }

    func testPIDReuseRemovesOldGenerationAndAddsCurrentRegularGeneration() {
        let old = generation(12)
        let replacement = generation(12, second: 2)
        let observation = Decision.Observation(
            generation: replacement, bundleID: "com.new", isHidden: false, activationPolicy: .regular
        )
        let plan = Decision.plan(
            trackedByPID: [12: .init(generation: old, bundleID: "com.old", isHidden: false)],
            observationsByPID: [12: observation],
            currentGenerationsByPID: [12: replacement]
        )
        XCTAssertEqual(plan.removals, [.init(pid: 12, generation: old, reason: .generationChanged)])
        XCTAssertEqual(plan.regularUpserts, [observation])
    }

    func testRegularObservationAddsOrUpdatesHiddenState() {
        let live = generation(13)
        let observation = Decision.Observation(
            generation: live, bundleID: "com.app", isHidden: true, activationPolicy: .regular
        )
        let plan = Decision.plan(
            trackedByPID: [:],
            observationsByPID: [13: observation],
            currentGenerationsByPID: [13: live]
        )
        XCTAssertEqual(plan.regularUpserts, [observation])
    }

    func testExplicitNonRegularObservationRequestsConfirmationOnlyForTrackedGeneration() {
        let live = generation(14)
        let observation = Decision.Observation(
            generation: live, bundleID: "com.app", isHidden: false, activationPolicy: .nonRegular
        )
        let plan = Decision.plan(
            trackedByPID: [14: .init(generation: live, bundleID: "com.app", isHidden: false)],
            observationsByPID: [14: observation],
            currentGenerationsByPID: [14: live]
        )
        XCTAssertEqual(plan.nonRegularConfirmations, [observation])
        XCTAssertTrue(plan.removals.isEmpty)
    }
}

@MainActor
final class RunningApplicationStoreSweepTests: XCTestCase {
    private final class Box {
        var observations: [RunningStateSweepDecision.Observation] = []
        var generations: [pid_t: RunningStateSweepDecision.Generation] = [:]
    }

    func testInjectedSweepClearsAStaleRunningProjectionWithoutTerminationNotification() {
        let box = Box()
        let generation = RunningStateSweepDecision.Generation(
            pid: 91, startTimeSeconds: 100, startTimeMicroseconds: 0
        )
        box.generations[91] = generation
        box.observations = [.init(
            generation: generation,
            bundleID: "com.example.stale",
            isHidden: false,
            activationPolicy: .regular
        )]
        let store = RunningApplicationStore(
            generationProvider: { box.generations[$0] },
            workspaceObservationProvider: { box.observations }
        )

        store.start()
        XCTAssertEqual(store.runningBundleIDs, ["com.example.stale"])

        box.observations = []
        box.generations[91] = nil
        store.reconcileWithWorkspace()
        XCTAssertTrue(store.runningBundleIDs.isEmpty)
        store.stop()
    }

    func testConfirmedNonRegularRemovalCanRecoverFromLaterRegularSweep() {
        let box = Box()
        let generation = RunningStateSweepDecision.Generation(
            pid: 92, startTimeSeconds: 200, startTimeMicroseconds: 0
        )
        box.generations[92] = generation
        box.observations = [.init(
            generation: generation,
            bundleID: "com.example.policy",
            isHidden: false,
            activationPolicy: .regular
        )]
        let store = RunningApplicationStore(
            generationProvider: { box.generations[$0] },
            workspaceObservationProvider: { box.observations }
        )
        store.start()

        store.confirmNonRegular(pid: 92, generation: generation, bundleID: "com.example.policy")
        XCTAssertTrue(store.runningBundleIDs.isEmpty)

        store.reconcileWithWorkspace()
        XCTAssertEqual(store.runningBundleIDs, ["com.example.policy"])
        store.stop()
    }
}
