import Foundation
import XCTest

final class DockSnapshotEqualityTests: XCTestCase {
    func testEquivalentSnapshotsCompareEqual() {
        let id = WindowID(rawValue: "cgw-1")
        let record = WindowRecord(
            id: id,
            appID: AppID(rawValue: "com.example.app"),
            pid: 42,
            bundleIdentifier: "com.example.app",
            title: "Window",
            bounds: CGRect(x: 1, y: 2, width: 300, height: 200),
            status: .inactive,
            cgWindowID: 10,
            isOnDesktop: true,
            groupID: "seat-1"
        )
        let lhs = DockSnapshot(windows: [id: record], orderedWindowIDs: [id])
        let rhs = DockSnapshot(windows: [id: record], orderedWindowIDs: [id])

        XCTAssertEqual(lhs, rhs)
        XCTAssertNotEqual(lhs, .empty)
    }
}

/// Truth table for running the feedback timer on demand.
///
/// Background: this timer used to be a 0.5s loop started unconditionally in `start()`, writing the feedback state back to `@Published` twice a second during idle,
/// making the whole strip recompute -- while most of the time that dictionary is empty. After changing it to run on demand,
/// "when it should tick" became a load-bearing rule, locked here.
final class FeedbackTickPolicyTests: XCTestCase {

    // MARK: - Four-cell truth table (runtime is running)

    func testIdleDoesNotTick() {
        XCTAssertFalse(
            FeedbackTickPolicy.shouldTick(
                isRunning: true,
                hasFeedbackEntries: false,
                hasOptimisticStates: false
            )
        )
    }

    func testFeedbackOnlyTicks() {
        XCTAssertTrue(
            FeedbackTickPolicy.shouldTick(
                isRunning: true,
                hasFeedbackEntries: true,
                hasOptimisticStates: false
            )
        )
    }

    /// Optimistic tail: the feedback entry has been cleared (the 1.5s result display expired), but the optimistic overlay is still waiting
    /// to be fulfilled or to time out at 4s and snap back -- it must still keep ticking, otherwise that chip's predicted state would never snap back.
    func testOptimisticOnlyTicks() {
        XCTAssertTrue(
            FeedbackTickPolicy.shouldTick(
                isRunning: true,
                hasFeedbackEntries: false,
                hasOptimisticStates: true
            )
        )
    }

    func testBothPresentTicks() {
        XCTAssertTrue(
            FeedbackTickPolicy.shouldTick(
                isRunning: true,
                hasFeedbackEntries: true,
                hasOptimisticStates: true
            )
        )
    }

    // MARK: - Load-bearing rule: never tick once the runtime has stopped

    /// The detached execution callback of `AppRuntime.trigger()` can return to the main thread after `stop()` and write the
    /// feedback state. Without this gate, that callback would revive the already-stopped timer -- the runtime has stopped,
    /// the timer still spins idle every 0.5s, and nobody is left to turn it off.
    func testStoppedRuntimeNeverTicksEvenWithPendingWork() {
        XCTAssertFalse(
            FeedbackTickPolicy.shouldTick(
                isRunning: false,
                hasFeedbackEntries: true,
                hasOptimisticStates: true
            )
        )
        XCTAssertFalse(
            FeedbackTickPolicy.shouldTick(
                isRunning: false,
                hasFeedbackEntries: true,
                hasOptimisticStates: false
            )
        )
        XCTAssertFalse(
            FeedbackTickPolicy.shouldTick(
                isRunning: false,
                hasFeedbackEntries: false,
                hasOptimisticStates: true
            )
        )
    }

    func testStoppedRuntimeIdleDoesNotTick() {
        XCTAssertFalse(
            FeedbackTickPolicy.shouldTick(
                isRunning: false,
                hasFeedbackEntries: false,
                hasOptimisticStates: false
            )
        )
    }
}

/// The lifecycle of the feedback state itself -- once the timer runs on demand, "will the entries empty out on their own" directly decides
/// whether the timer stops. These cases lock down that the retention semantics were not changed.
final class IntentFeedbackStateRetentionTests: XCTestCase {

    private let windowID = "cgw-1"

    private func snapshot(status: WindowStatus) -> DockSnapshot {
        let id = WindowID(rawValue: windowID)
        let record = WindowRecord(
            id: id,
            appID: AppID(rawValue: "com.example.app"),
            pid: 1234,
            bundleIdentifier: "com.example.app",
            title: "窗口",
            bounds: nil,
            status: status,
            isOnDesktop: true,
            groupID: windowID
        )
        return DockSnapshot(windows: [id: record], orderedWindowIDs: [id])
    }

    /// A pending entry not fulfilled after 4s -> turns to failure (rather than staying in pending forever).
    func testPendingBecomesFailureAfterRetention() {
        var state = IntentFeedbackState()
        let start = Date()
        state.begin(windowID: windowID, action: .minimize, at: start)

        state.reconcile(snapshot: snapshot(status: .inactive), now: start.addingTimeInterval(4.5))

        XCTAssertEqual(state.entriesByWindowID[windowID]?.phase, .failure)
    }

    /// **Immediate failure, then the snapshot fulfills it**: `AccessibilitySource.minimize` reads back
    /// `kAXMinimizedAttribute` right after pressing the minimize button, but minimizing is an animated operation -- that read often has not caught up yet, so the executor reports
    /// failure. The real snapshot then shows the window really was minimized, and it must be able to correct that to success.
    ///
    /// This is a regression guardrail: to let the on-demand timer stop, "skip reconciliation for all terminal states" was once adopted as the fix,
    /// and written that way it deleted this upgrade path along with it.
    func testFailureIsUpgradedToSuccessWhenSnapshotLaterConfirms() {
        var state = IntentFeedbackState()
        let start = Date()
        state.begin(windowID: windowID, action: .minimize, at: start)

        // The executor's immediate read-back fails -> failure
        state.markFailed(windowID: windowID, action: .minimize, at: start.addingTimeInterval(0.05))
        XCTAssertEqual(state.entriesByWindowID[windowID]?.phase, .failure)

        // Later the real snapshot shows the window is minimized -> corrected to success
        state.reconcile(snapshot: snapshot(status: .minimized), now: start.addingTimeInterval(0.4))
        XCTAssertEqual(
            state.entriesByWindowID[windowID]?.phase,
            .success,
            "failure 必须能被后续真实快照纠正——AX 动作可能已生效而即时回读没跟上"
        )
    }

    /// Do not refresh the timestamp within the same phase: while the window stays in the target state, every reconciliation round judges success again, but it must not
    /// overwrite `updatedAt` with now round after round, otherwise the entry never expires and the on-demand timer can never stop.
    func testSuccessIsNotRestampedWhileWindowStaysInTargetState() {
        var state = IntentFeedbackState()
        let start = Date()
        state.begin(windowID: windowID, action: .minimize, at: start)
        state.reconcile(snapshot: snapshot(status: .minimized), now: start.addingTimeInterval(0.2))
        let firstSuccessAt = state.entriesByWindowID[windowID]?.updatedAt
        XCTAssertNotNil(firstSuccessAt)

        // Another round passed, and the window is still minimized
        state.reconcile(snapshot: snapshot(status: .minimized), now: start.addingTimeInterval(0.7))

        XCTAssertEqual(
            state.entriesByWindowID[windowID]?.updatedAt,
            firstSuccessAt,
            "同相位重复对账不能刷新 updatedAt，否则 1.5s retention 永远走不到"
        )
    }

    /// A terminal state (success / failure) is cleared after being displayed for 1.5s -- this is the precondition for the timer to be able to stop.
    func testTerminalEntryIsDroppedAfterRetentionSoTheTimerCanStop() {
        var state = IntentFeedbackState()
        let start = Date()
        state.begin(windowID: windowID, action: .minimize, at: start)

        // Fulfilled: the window really was minimized -> success
        state.reconcile(snapshot: snapshot(status: .minimized), now: start.addingTimeInterval(0.5))
        XCTAssertEqual(state.entriesByWindowID[windowID]?.phase, .success)

        // The 1.5s result display expired -> the entry disappears, the dictionary becomes empty
        state.reconcile(snapshot: snapshot(status: .minimized), now: start.addingTimeInterval(2.2))
        XCTAssertTrue(
            state.entriesByWindowID.isEmpty,
            "terminal 条目没被清掉的话，按需计时器就永远停不下来"
        )
    }
}
