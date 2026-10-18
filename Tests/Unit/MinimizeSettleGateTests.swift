import XCTest
@testable import NeoBar

final class MinimizeSettleGateTests: XCTestCase {
    /// Anchor is taken at reference epoch 0: `addingTimeInterval(x)` and `timeIntervalSince(anchor)` both equal x exactly,
    /// so boundary-equality cases won't be made flaky by Double rounding (1000 + 0.65 != exactly 0.65).
    private let anchor = Date(timeIntervalSinceReferenceDate: 0)

    private func verdict(
        kind: PlatformActionRequest.ActionKind = .activateWindow,
        hasAnchor: Bool = true,
        confirmed: Bool,
        elapsed: TimeInterval
    ) -> MinimizeSettleGate.Verdict {
        MinimizeSettleGate.verdict(
            requestKind: kind,
            minimizeDispatchedAt: hasAnchor ? anchor : nil,
            snapshotConfirmsMinimized: confirmed,
            now: anchor.addingTimeInterval(elapsed)
        )
    }

    /// Non-activate actions always dispatch, even if the anchor is still alive.
    func testNonActivateKindsAlwaysDispatch() {
        let kinds: [PlatformActionRequest.ActionKind] = [.minimizeWindow, .hideApp, .closeWindow, .quitApp, .newWindow]
        for kind in kinds {
            XCTAssertEqual(verdict(kind: kind, confirmed: false, elapsed: 0.1), .dispatchNow)
        }
    }

    /// No minimize anchor -> no defense.
    func testNoAnchorDispatches() {
        XCTAssertEqual(verdict(hasAnchor: false, confirmed: false, elapsed: 0.1), .dispatchNow)
    }

    /// [Load-bearing, v2 semantics reversed] A snapshot confirming `.minimized` dispatches immediately, with no time floor any more.
    /// v1 once locked "confirmation must also wait 0.65s" here, and it was vetoed twice by the owner's measurements (feel + Finder's 887ms missing a sibling):
    /// waiting is not a source of safety -- the dangerous branch during the animation has already been sealed by the execution layer's prior check (forcing knownMinimized to follow the 07-05 v3
    /// measured sequence, skipping earlyFocus, sealing the app fallback), and confirmation itself only carries the write-order proof against a concurrent minimize.
    func testConfirmedDispatchesImmediately() {
        for elapsed in [0.05, 0.2, 0.5, 0.99] {
            XCTAssertEqual(verdict(confirmed: true, elapsed: elapsed), .dispatchNow, "elapsed=\(elapsed)")
        }
    }

    /// Not confirmed -> hold up to the hard cap (the only deadline tier).
    func testUnconfirmedHoldsToMaxHold() {
        for elapsed in [0.1, 0.5, 0.9] {
            XCTAssertEqual(
                verdict(confirmed: false, elapsed: elapsed),
                .hold(until: anchor.addingTimeInterval(MinimizeSettleGate.maxHold)),
                "elapsed=\(elapsed)"
            )
        }
    }

    /// [Load-bearing] Past the hard cap it dispatches even if unconfirmed: a click must not be held indefinitely (the execution layer still carries the prior-check fallback).
    func testPastMaxHoldDispatchesEvenUnconfirmed() {
        XCTAssertEqual(verdict(confirmed: false, elapsed: 1.1), .dispatchNow)
    }

    /// Confirmed + past the hard cap -> still dispatches (boundary completeness).
    func testConfirmedPastMaxHoldStillDispatches() {
        XCTAssertEqual(verdict(confirmed: true, elapsed: 1.2), .dispatchNow)
    }

    /// deadline is monotonic: re-running the decision as time advances, the deadline doesn't retreat; once dispatchNow, it never returns to hold.
    func testDeadlineMonotonicAcrossReevaluation() {
        var lastDeadline = Date.distantPast
        var dispatched = false
        for elapsed in stride(from: 0.05, through: 1.3, by: 0.05) {
            switch verdict(confirmed: false, elapsed: elapsed) {
            case .hold(let until):
                XCTAssertFalse(dispatched, "dispatchNow 之后不得回到 hold(elapsed=\(elapsed))")
                XCTAssertGreaterThanOrEqual(until, lastDeadline)
                lastDeadline = until
            case .dispatchNow:
                dispatched = true
            }
        }
        XCTAssertTrue(dispatched)
    }

    /// Clock anomaly (anchor in the future) -> conservatively dispatch, returning to the old behavior.
    func testNegativeElapsedDispatches() {
        XCTAssertEqual(verdict(confirmed: false, elapsed: -0.5), .dispatchNow)
    }

    /// Boundary equality: elapsed == maxHold unconfirmed -> dispatch.
    func testBoundaryEquality() {
        XCTAssertEqual(verdict(confirmed: false, elapsed: MinimizeSettleGate.maxHold), .dispatchNow)
    }

    /// Prior-check window: anchor within [0, priorWindow) -> true; at the boundary, with no anchor, or with a clock anomaly -> false.
    func testDispatchPrior() {
        func prior(_ elapsed: TimeInterval, hasAnchor: Bool = true) -> Bool {
            MinimizeSettleGate.dispatchPrior(
                minimizeDispatchedAt: hasAnchor ? anchor : nil,
                now: anchor.addingTimeInterval(elapsed)
            )
        }
        XCTAssertTrue(prior(0))
        XCTAssertTrue(prior(0.1))
        XCTAssertTrue(prior(1.5))
        XCTAssertTrue(prior(1.99))
        XCTAssertFalse(prior(MinimizeSettleGate.priorWindow))
        XCTAssertFalse(prior(2.5))
        XCTAssertFalse(prior(-0.5))
        XCTAssertFalse(prior(0.1, hasAnchor: false))
    }
}
