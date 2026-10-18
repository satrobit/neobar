import ApplicationServices
import CoreGraphics
import XCTest

final class WindowSubscriptionLedgerTests: XCTestCase {
    private typealias Ledger = WindowSubscriptionLedger<String>
    private let all: [WindowSubscriptionItem] = WindowSubscriptionItem.allCases

    /// Runs one attempt with the given per-item results (missing item = not sent).
    @discardableResult
    private func attempt(
        _ ledger: inout Ledger,
        cg: CGWindowID = 7,
        element: String,
        kind: WindowSubscriptionAttemptKind,
        now: TimeInterval,
        results: [WindowSubscriptionItem: AXError] = [:],
        defaultResult: AXError = .success
    ) -> (instanceID: UInt64, previousInstanceID: UInt64?, items: [WindowSubscriptionItem]) {
        let begun = ledger.beginAttempt(cgWindowID: cg, element: element, kind: kind, now: now)
        var sawFailure = false
        for item in begun.items {
            let result = results[item] ?? defaultResult
            ledger.record(cgWindowID: cg, item: item, result: result)
            switch result {
            case .success, .notificationAlreadyRegistered, .notificationUnsupported: break
            default: sawFailure = true
            }
            if result == .invalidUIElement { break }
        }
        ledger.finishAttempt(cgWindowID: cg, now: now, sawFailure: sawFailure)
        return begun
    }

    func testFreshWindowIsInitialAndThenFastPath() {
        var ledger = Ledger()
        XCTAssertEqual(ledger.attemptKind(cgWindowID: 7, element: "E1", now: 0), .initial)
        let begun = attempt(&ledger, element: "E1", kind: .initial, now: 0)
        XCTAssertEqual(begun.items, all)
        XCTAssertTrue(ledger.isCovered(cgWindowID: 7))
        XCTAssertNil(ledger.attemptKind(cgWindowID: 7, element: "E1", now: 100))
    }

    func testNewElementRenewsWithFreshInstanceAndResetItems() {
        var ledger = Ledger()
        let first = attempt(&ledger, element: "E1", kind: .initial, now: 0)
        XCTAssertEqual(ledger.attemptKind(cgWindowID: 7, element: "E2", now: 0.1), .renewal)
        let renewed = attempt(&ledger, element: "E2", kind: .renewal, now: 0.1)
        XCTAssertEqual(renewed.items, all)
        XCTAssertEqual(renewed.previousInstanceID, first.instanceID)
        XCTAssertNotEqual(renewed.instanceID, first.instanceID)
        XCTAssertEqual(ledger.record(for: 7)?.element, "E2")
        XCTAssertNil(ledger.cgWindowID(forElement: "E1"))
    }

    /// Blink order 1: the old element's destroy lands first and removes the record; the window then
    /// comes back with a new element, which must subscribe as `.initial` with an unused instance id.
    func testDestroyOfCurrentElementRemovesRecordAndNeverReusesInstance() {
        var ledger = Ledger()
        let first = attempt(&ledger, element: "E1", kind: .initial, now: 0)
        let hit = ledger.noteDestroyed(element: "E1")
        XCTAssertEqual(hit?.cgWindowID, 7)
        XCTAssertEqual(hit?.removedInstanceID, first.instanceID)
        XCTAssertNil(ledger.record(for: 7))
        XCTAssertEqual(ledger.attemptKind(cgWindowID: 7, element: "E2", now: 0.1), .initial)
        let second = attempt(&ledger, element: "E2", kind: .initial, now: 0.1)
        XCTAssertGreaterThan(second.instanceID, first.instanceID)
    }

    /// Code review 1-1: the old element's subscription failed and the window comes back with a new
    /// element right away. The new element must be subscribed now — delaying it leaves the window
    /// with no live destroy subscription if it is hidden again in the meantime.
    func testNewElementAfterAFailedSubscriptionRenewsImmediately() {
        var ledger = Ledger()
        attempt(&ledger, element: "E1", kind: .initial, now: 0, results: [.destroyed: .cannotComplete])
        XCTAssertEqual(ledger.attemptKind(cgWindowID: 7, element: "E2", now: 0.05), .renewal)
        attempt(&ledger, element: "E2", kind: .renewal, now: 0.05)
        XCTAssertTrue(ledger.isCovered(cgWindowID: 7))
    }

    /// Code review 1-3: a process's observer can be dropped and recreated; instance ids come from one
    /// session-wide source so diagnostics never see the same id twice.
    func testInstanceIDsAreUniqueAcrossLedgersSharingASource() {
        let ids = WindowSubscriptionInstanceIDs()
        var first = Ledger(instanceIDs: ids)
        let a = attempt(&first, element: "E1", kind: .initial, now: 0)
        var second = Ledger(instanceIDs: ids)
        let b = attempt(&second, element: "E1", kind: .initial, now: 0)
        XCTAssertNotEqual(a.instanceID, b.instanceID)
    }

    /// Blink order 2: the new element was renewed first; the old element's late destroy must not
    /// remove the new registration.
    func testLateDestroyOfReplacedElementKeepsNewRegistration() {
        var ledger = Ledger()
        attempt(&ledger, element: "E1", kind: .initial, now: 0)
        attempt(&ledger, element: "E2", kind: .renewal, now: 5)
        XCTAssertNil(ledger.noteDestroyed(element: "E1"))
        XCTAssertEqual(ledger.record(for: 7)?.element, "E2")
        XCTAssertTrue(ledger.isCovered(cgWindowID: 7))
    }

    func testTimeoutBacksOffAndNeverGivesUp() {
        var ledger = Ledger()
        attempt(&ledger, element: "E1", kind: .initial, now: 0, results: [.destroyed: .cannotComplete])
        XCTAssertFalse(ledger.isCovered(cgWindowID: 7))
        var now: TimeInterval = 0
        for expectedDelay in [1.0, 5, 15, 60, 60, 60] {
            let retryAt = ledger.record(for: 7)!.retryAt
            XCTAssertEqual(retryAt - now, expectedDelay, accuracy: 0.0001)
            XCTAssertNil(ledger.attemptKind(cgWindowID: 7, element: "E1", now: retryAt - 0.01))
            XCTAssertEqual(ledger.attemptKind(cgWindowID: 7, element: "E1", now: retryAt), .retry)
            now = retryAt
            attempt(&ledger, element: "E1", kind: .retry, now: now, results: [.destroyed: .cannotComplete])
        }
        attempt(&ledger, element: "E1", kind: .retry, now: now + 60)
        XCTAssertTrue(ledger.isCovered(cgWindowID: 7))
    }

    /// Review 5-2: "first item failed, the other three still pending" is a retry, gated by retryAt.
    func testFailedPlusPendingIsRetryOnlyWhenDue() {
        var ledger = Ledger()
        let begun = ledger.beginAttempt(cgWindowID: 7, element: "E1", kind: .initial, now: 0)
        XCTAssertEqual(begun.items.first, .destroyed)
        ledger.record(cgWindowID: 7, item: .destroyed, result: .cannotComplete)
        ledger.finishAttempt(cgWindowID: 7, now: 0, sawFailure: true)
        XCTAssertNil(ledger.attemptKind(cgWindowID: 7, element: "E1", now: 0.5))
        XCTAssertEqual(ledger.attemptKind(cgWindowID: 7, element: "E1", now: 1), .retry)
        let retry = ledger.beginAttempt(cgWindowID: 7, element: "E1", kind: .retry, now: 1)
        XCTAssertEqual(retry.items, all)
        XCTAssertEqual(retry.instanceID, begun.instanceID)
    }

    func testNonCriticalGapIsNotCoveredAndRetried() {
        var ledger = Ledger()
        attempt(&ledger, element: "E1", kind: .initial, now: 0, results: [.titleChanged: .cannotComplete])
        XCTAssertFalse(ledger.isCovered(cgWindowID: 7))
        XCTAssertEqual(ledger.attemptKind(cgWindowID: 7, element: "E1", now: 1), .retry)
        let retry = attempt(&ledger, element: "E1", kind: .retry, now: 1)
        XCTAssertEqual(retry.items, [.titleChanged])
        XCTAssertTrue(ledger.isCovered(cgWindowID: 7))
    }

    func testRetryTimeLimitStopStaysDueWithoutBackoff() {
        var ledger = Ledger()
        attempt(&ledger, element: "E1", kind: .initial, now: 0, results: [.deminiaturized: .cannotComplete])
        let stepBefore = ledger.record(for: 7)!.step
        _ = ledger.beginAttempt(cgWindowID: 7, element: "E1", kind: .retry, now: 1)
        // Budget ran out before the call: nothing new failed.
        ledger.finishAttempt(cgWindowID: 7, now: 1.06, sawFailure: false)
        XCTAssertEqual(ledger.record(for: 7)!.retryAt, 1.06, accuracy: 0.0001)
        XCTAssertEqual(ledger.record(for: 7)!.step, stepBefore)
        XCTAssertEqual(ledger.attemptKind(cgWindowID: 7, element: "E1", now: 1.06), .retry)
    }

    func testInvalidElementIsDeadUntilANewElementAppears() {
        var ledger = Ledger()
        attempt(&ledger, element: "E1", kind: .initial, now: 0, results: [.destroyed: .invalidUIElement])
        XCTAssertTrue(ledger.record(for: 7)!.isDead)
        XCTAssertFalse(ledger.isCovered(cgWindowID: 7))
        XCTAssertNil(ledger.attemptKind(cgWindowID: 7, element: "E1", now: 100))
        XCTAssertEqual(ledger.attemptKind(cgWindowID: 7, element: "E2", now: 0.1), .renewal)
    }

    func testUnsupportedCountsAsCoveredAndIsNotRetried() {
        var ledger = Ledger()
        attempt(&ledger, element: "E1", kind: .initial, now: 0, results: [.titleChanged: .notificationUnsupported])
        XCTAssertTrue(ledger.isCovered(cgWindowID: 7))
        XCTAssertNil(ledger.attemptKind(cgWindowID: 7, element: "E1", now: 100))
    }

    func testRetainDropsOnlyWindowsOutsideKeep() {
        var ledger = Ledger()
        attempt(&ledger, cg: 7, element: "E7", kind: .initial, now: 0)
        attempt(&ledger, cg: 8, element: "E8", kind: .initial, now: 0)
        let dropped = ledger.retain(keep: [7])
        XCTAssertEqual(dropped.map(\.cgWindowID), [8])
        XCTAssertNotNil(ledger.record(for: 7))
        XCTAssertNil(ledger.cgWindowID(forElement: "E8"))
        ledger.removeAll()
        XCTAssertNil(ledger.record(for: 7))
    }

    // MARK: - Attempt policy

    func testInitialAttemptStillSendsCriticalItemsAfterATimeout() {
        typealias Policy = WindowSubscriptionAttemptPolicy
        XCTAssertEqual(Policy.step(item: .miniaturized, index: 1, sawTimeout: true, elapsed: 0.1, timeLimit: nil), .send)
        XCTAssertEqual(Policy.step(item: .deminiaturized, index: 2, sawTimeout: true, elapsed: 0.2, timeLimit: nil), .skip)
        XCTAssertEqual(Policy.step(item: .titleChanged, index: 3, sawTimeout: false, elapsed: 0.3, timeLimit: nil), .send)
    }

    func testRetryStopsAtTimeoutAndAtTimeLimitButAlwaysSendsFirst() {
        typealias Policy = WindowSubscriptionAttemptPolicy
        XCTAssertEqual(Policy.step(item: .destroyed, index: 0, sawTimeout: false, elapsed: 0.2, timeLimit: 0.05), .send)
        XCTAssertEqual(Policy.step(item: .miniaturized, index: 1, sawTimeout: false, elapsed: 0.06, timeLimit: 0.05),
                       .stop(.retryTimeLimit))
        XCTAssertEqual(Policy.step(item: .miniaturized, index: 1, sawTimeout: true, elapsed: 0.01, timeLimit: 0.05), .stop(nil))
    }

    // MARK: - Retry scheduling

    private typealias Candidate = WindowSubscriptionRetryCandidate<String>

    func testPickIsEarliestDueAndSkipsInvalid() {
        let candidates = [
            Candidate(pid: 1, cgWindowID: 10, element: "a", retryAt: 5),
            Candidate(pid: 2, cgWindowID: 20, element: "b", retryAt: 1),
            Candidate(pid: 1, cgWindowID: 11, element: "c", retryAt: 3),
        ]
        XCTAssertEqual(WindowSubscriptionRetryScheduler.pick(candidates) { _ in true }.picked?.cgWindowID, 20)
        // Review 6-1: the earliest one can no longer run (filtered, replaced) → the slot moves on.
        let choice = WindowSubscriptionRetryScheduler.pick(candidates) { $0.cgWindowID != 20 }
        XCTAssertEqual(choice.picked?.cgWindowID, 11)
        XCTAssertEqual(choice.skippedInvalid, 1)
    }

    /// Simulates one flush every 5s over 600s. `keepsFailing` windows back off 60s after each run.
    private func simulate(
        _ start: [Candidate],
        keepsFailing: Set<CGWindowID>
    ) -> [CGWindowID: Int] {
        var pending = start
        var served: [CGWindowID: Int] = [:]
        var now: TimeInterval = 0
        while now <= 600 {
            let due = pending.filter { $0.retryAt <= now }
            if let picked = WindowSubscriptionRetryScheduler.pick(due, isValid: { _ in true }).picked {
                served[picked.cgWindowID, default: 0] += 1
                pending.removeAll { $0 == picked }
                if keepsFailing.contains(picked.cgWindowID) {
                    pending.append(Candidate(pid: picked.pid, cgWindowID: picked.cgWindowID,
                                             element: picked.element, retryAt: now + 60))
                }
            }
            now += 5
        }
        return served
    }

    /// Review 4-3: twelve front seats keep failing; the thirteenth, due all along, still gets served.
    func testFrontSeatsThatKeepFailingCannotStarveALaterSeat() {
        var start = (0..<12).map { Candidate(pid: 1, cgWindowID: CGWindowID(100 + $0), element: "a\($0)",
                                             retryAt: TimeInterval($0) * 5 - 60) }
        start.append(Candidate(pid: 1, cgWindowID: 999, element: "late", retryAt: 0))
        let served = simulate(start, keepsFailing: Set((0..<12).map { CGWindowID(100 + $0) }))
        XCTAssertEqual(served[999], 1)
    }

    /// Review 5-3: pid A's twelve failing windows cannot starve pid B's due one.
    func testFailingAppCannotStarveAnotherApp() {
        var start = (0..<12).map { Candidate(pid: 1, cgWindowID: CGWindowID(100 + $0), element: "a\($0)",
                                             retryAt: TimeInterval($0) * 5 - 60) }
        start.append(Candidate(pid: 2, cgWindowID: 200, element: "b", retryAt: 0))
        let served = simulate(start, keepsFailing: Set((0..<12).map { CGWindowID(100 + $0) }))
        XCTAssertEqual(served[200], 1)
    }
}
