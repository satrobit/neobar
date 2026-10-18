import CoreGraphics
import XCTest

/// Skip-read gate decision matrix: each force-full-read condition is flipped once on its own, plus the all-quiet skip.
final class PeriodicReconcileSkipDecisionTests: XCTestCase {
    /// Baseline input where all conditions are satisfied and skipping is allowed.
    private func quietInput() -> PeriodicReconcileSkipDecision.Input {
        PeriodicReconcileSkipDecision.Input(
            captureFailed: false,
            currentCGIDs: [77, 78],
            lastObservedCGIDs: [77, 78],
            dirtySinceLastRead: false,
            hasAbsenceClock: false,
            hasPhantomCandidate: false,
            lastReadWasUnread: false,
            lastRoundChanged: false,
            observerActive: true,
            allSeatsSubscribed: true,
            uptimeSinceLastFullRead: 5
        )
    }

    func testAllQuietSkips() {
        XCTAssertEqual(PeriodicReconcileSkipDecision.verdict(quietInput()), .skip)
    }

    /// A seated window hidden without any AX notification keeps the CG id set and the dirty flag;
    /// only its on-screen change can reopen the gate.
    func testSeatOnScreenChangeForcesFullRead() {
        var input = quietInput()
        input.seatOnScreenChanged = true
        XCTAssertEqual(PeriodicReconcileSkipDecision.verdict(input), .fullRead(.seatOnScreenChanged))
    }

    func testCaptureFailureForcesFullRead() {
        var input = quietInput()
        input.captureFailed = true
        // When CG fails, a full read is required even if the sets "look" consistent: failure is indistinguishable from an empty set (hard constraint in Docs/26).
        XCTAssertEqual(PeriodicReconcileSkipDecision.verdict(input), .fullRead(.captureFailed))
    }

    func testNeverReadForcesFullRead() {
        var input = quietInput()
        input.lastObservedCGIDs = nil
        XCTAssertEqual(PeriodicReconcileSkipDecision.verdict(input), .fullRead(.neverRead))
    }

    func testRefreshDueAtBoundaryForcesFullRead() {
        var input = quietInput()
        input.uptimeSinceLastFullRead = input.maxSkipInterval   // the boundary counts as "read when due"
        XCTAssertEqual(PeriodicReconcileSkipDecision.verdict(input), .fullRead(.refreshDue))
        input.uptimeSinceLastFullRead = input.maxSkipInterval - 0.001
        XCTAssertEqual(PeriodicReconcileSkipDecision.verdict(input), .skip)
    }

    func testInactiveObserverForcesFullRead() {
        var input = quietInput()
        input.observerActive = false
        XCTAssertEqual(PeriodicReconcileSkipDecision.verdict(input), .fullRead(.observerInactive))
    }

    func testIncompleteSubscriptionForcesFullRead() {
        var input = quietInput()
        input.allSeatsSubscribed = false
        XCTAssertEqual(PeriodicReconcileSkipDecision.verdict(input), .fullRead(.subscriptionIncomplete))
    }

    func testUnreadLastRoundForcesFullRead() {
        var input = quietInput()
        input.lastReadWasUnread = true
        XCTAssertEqual(PeriodicReconcileSkipDecision.verdict(input), .fullRead(.lastReadUnread))
    }

    func testDirtyEventsForceFullRead() {
        var input = quietInput()
        input.dirtySinceLastRead = true
        XCTAssertEqual(PeriodicReconcileSkipDecision.verdict(input), .fullRead(.dirtyEvents))
    }

    func testCGSetChangeForcesFullRead() {
        var input = quietInput()
        input.currentCGIDs = [77]
        XCTAssertEqual(PeriodicReconcileSkipDecision.verdict(input), .fullRead(.cgSetChanged))
        // More and fewer trigger it equally.
        input.currentCGIDs = [77, 78, 79]
        XCTAssertEqual(PeriodicReconcileSkipDecision.verdict(input), .fullRead(.cgSetChanged))
    }

    func testAbsenceClockForcesFullRead() {
        var input = quietInput()
        input.hasAbsenceClock = true
        XCTAssertEqual(PeriodicReconcileSkipDecision.verdict(input), .fullRead(.absenceClockRunning))
    }

    func testPhantomCandidateForcesFullRead() {
        var input = quietInput()
        input.hasPhantomCandidate = true
        XCTAssertEqual(PeriodicReconcileSkipDecision.verdict(input), .fullRead(.phantomCandidate))
    }

    func testUnstableLastRoundForcesFullRead() {
        var input = quietInput()
        input.lastRoundChanged = true
        XCTAssertEqual(PeriodicReconcileSkipDecision.verdict(input), .fullRead(.lastRoundChanged))
    }
}
