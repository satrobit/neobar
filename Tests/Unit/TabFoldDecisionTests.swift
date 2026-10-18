import CoreGraphics
import XCTest

/// Pass B "minimize folding" pure decision layer (TabFoldDecision).
/// Background: when Ghostty minimizes a multi-tab window it exposes all tabs as min=true AX windows; background tabs are order-out
/// windows whose AX geometry stays at stale values after move/resize. Four decision levels: membership -> shadow tab pool -> exact frame match
/// -> size fallback. Shadow pool = ids that were "in CG but not in AX" on the previous round (order-out tab signature, immune to dock restarts).
final class TabFoldDecisionTests: XCTestCase {

    // Test key isomorphic to AppTracker.frameKey (a fixed pid is enough)
    private func fk(_ b: CGRect?) -> String? {
        guard let b else { return nil }
        return "\(Int(b.origin.x.rounded())):\(Int(b.origin.y.rounded())):\(Int(b.size.width.rounded())):\(Int(b.size.height.rounded()))"
    }

    private func seat(
        cg: CGWindowID, bounds: CGRect?, min: Bool = true, former: Set<CGWindowID> = []
    ) -> TabFoldDecision.PlacedSeat {
        TabFoldDecision.PlacedSeat(activeCgID: cg, bounds: bounds, isMinimized: min, formerCgIDs: former)
    }

    private func verdict(
        cg: CGWindowID, bounds: CGRect?, min: Bool = true, onScreen: Bool = false,
        shadow: Bool = false, placed: [TabFoldDecision.PlacedSeat]
    ) -> TabFoldDecision.Verdict {
        TabFoldDecision.verdict(
            candidateCgID: cg, candidateBounds: bounds,
            candidateIsMinimized: min, candidateIsOnScreen: onScreen,
            candidateIsKnownShadow: shadow, placedSeats: placed, frameKey: fk
        )
    }

    private let frame = CGRect(x: 172, y: 87, width: 1191, height: 831)

    // MARK: - Locking existing behavior

    func testSameFrameBackgroundTabFolds() {
        // The window hasn't moved: the background tab has a pixel-identical frame to the seat -> folded by exact match
        let v = verdict(cg: 240522, bounds: frame, placed: [seat(cg: 249469, bounds: frame)])
        XCTAssertEqual(v, .fold(ownerActiveCgID: 249469, reason: .exactFrame))
    }

    func testMovedWindowFoldsBySizeFallback() {
        // The window was moved: the background tab's coordinates are stale (old position) but the size is unchanged -> folded by size fallback (6412015 behavior)
        let moved = frame.offsetBy(dx: 300, dy: -60)
        let v = verdict(cg: 240522, bounds: frame, placed: [seat(cg: 249469, bounds: moved)])
        XCTAssertEqual(v, .fold(ownerActiveCgID: 249469, reason: .sameSize))
    }

    func testNonMinimizedOverlappingWindowGetsNewSeat() {
        // Non-min windows with the same frame = the legitimate case of two independent windows overlapping -> new seats as usual
        let v = verdict(cg: 240522, bounds: frame, min: false, onScreen: true,
                        placed: [seat(cg: 249469, bounds: frame, min: false)])
        XCTAssertEqual(v, .newSeat)
    }

    func testOnScreenCandidateDoesNotSizeMatch() {
        // An on-screen window is not a background tab: even with the same size it doesn't take the size fallback (an independent window deserves its own seat)
        let moved = frame.offsetBy(dx: 300, dy: 0)
        let v = verdict(cg: 240522, bounds: frame, onScreen: true,
                        placed: [seat(cg: 249469, bounds: moved)])
        XCTAssertEqual(v, .newSeat)
    }

    // MARK: - Hole 1: geometry entirely stale after resize -> membership covers it

    func testResizedWindowSplitsWithoutMembership() {
        // A resized window: the background tab's coordinates and size are both stale -> exact match and size fallback both fail.
        // No membership and not in the shadow pool (e.g. the first round after a dock restart) -> can only create a new seat (locks the existence of this gap).
        let resized = CGRect(x: 172, y: 87, width: 900, height: 600)
        let v = verdict(cg: 240522, bounds: frame, placed: [seat(cg: 249469, bounds: resized)])
        XCTAssertEqual(v, .newSeat)
    }

    func testResizedWindowFoldsByMembership() {
        // Same as above, but the candidate was once this seat's active tab -> membership fold, independent of geometry (hole 1 fixed at the root)
        let resized = CGRect(x: 172, y: 87, width: 900, height: 600)
        let v = verdict(cg: 240522, bounds: frame,
                        placed: [seat(cg: 249469, bounds: resized, former: [240522])])
        XCTAssertEqual(v, .fold(ownerActiveCgID: 249469, reason: .membership))
    }

    // MARK: - Hole 2: min lag race -> membership ignores the min flag

    func testMinLagRaceFoldsByMembership() {
        // At the instant of minimizing: background tabs are already exposed (min=true), but the active seat's min hasn't flipped to true yet (AX lag),
        // and the window was moved (exact match has failed). The size fallback is blocked by the min gate -> old logic split;
        // membership folding ignores the seat's min flag -> folds (hole 2 fixed at the root)
        let moved = frame.offsetBy(dx: 300, dy: -60)
        let v = verdict(cg: 240522, bounds: frame,
                        placed: [seat(cg: 249469, bounds: moved, min: false, former: [240522])])
        XCTAssertEqual(v, .fold(ownerActiveCgID: 249469, reason: .membership))
    }

    func testMinLagRaceWithoutMembershipStillSplits() {
        // Same race, no membership, not in the shadow pool: size fallback still requires the seat to be marked min (conservative, to avoid wrongly merging independent windows) -> new seat
        let moved = frame.offsetBy(dx: 300, dy: -60)
        let v = verdict(cg: 240522, bounds: frame,
                        placed: [seat(cg: 249469, bounds: moved, min: false)])
        XCTAssertEqual(v, .newSeat)
    }

    // MARK: - Shadow tab pool (restart-safety layer after member history is wiped by a dock restart)

    func testShadowPoolFoldsDespiteStaleGeometryAndMinLag() {
        // Core of gap A: after a dock restart the history is empty + the window was moved and resized (geometry double failure) + min lag race
        //(seat min hasn't flipped to true yet). The candidate was "in CG but not in AX" on the previous round (shadow tab signature) -> pool fold,
        // unique seat owner + learning.
        let resized = CGRect(x: 500, y: 300, width: 900, height: 600)
        let v = verdict(cg: 240522, bounds: frame, shadow: true,
                        placed: [seat(cg: 249469, bounds: resized, min: false)])
        XCTAssertEqual(v, .fold(ownerActiveCgID: 249469, reason: .shadowPool))
    }

    func testShadowPoolRequiresMinimizedCandidate() {
        // A torn-out tab becomes visible: it was still a shadow on the previous round (order-out), now min=false -> it must split into its own card normally, and the pool doesn't block it
        let v = verdict(cg: 240522, bounds: frame.offsetBy(dx: 400, dy: 0), min: false,
                        onScreen: true, shadow: true,
                        placed: [seat(cg: 249469, bounds: frame, min: false)])
        XCTAssertEqual(v, .newSeat)
    }

    func testShadowPoolWithNoPlacedSeatsCreatesSeat() {
        // With zero placed seats the pool doesn't fold -- otherwise a truly minimized window group couldn't even create a single representative card
        let v = verdict(cg: 240522, bounds: frame, shadow: true, placed: [])
        XCTAssertEqual(v, .newSeat)
    }

    func testShadowPoolMultiSeatFoldsWithoutLearning() {
        // Multi-seat ownership ambiguity: still folds (no card split), but owner nil = no learning (better to learn too little than to record wrongly)
        let v = verdict(cg: 240522, bounds: CGRect(x: 1, y: 2, width: 300, height: 200), shadow: true,
                        placed: [seat(cg: 249469, bounds: frame),
                                 seat(cg: 253982, bounds: frame.offsetBy(dx: 40, dy: 40))])
        XCTAssertEqual(v, .fold(ownerActiveCgID: nil, reason: .shadowPool))
    }

    func testMembershipWinsOverShadowPool() {
        // Membership takes priority over the shadow pool: with multiple seats the pool can only fold, not attribute, while membership can attribute exactly -> check membership first
        let v = verdict(cg: 240522, bounds: frame, shadow: true,
                        placed: [seat(cg: 249469, bounds: frame.offsetBy(dx: 500, dy: 0), former: [240522]),
                                 seat(cg: 253982, bounds: frame)])
        XCTAssertEqual(v, .fold(ownerActiveCgID: 249469, reason: .membership))
    }

    func testRealMinimizedWindowNotInShadowPoolGetsSeat() {
        // An independent window that was truly minimized at seed time: min=true but in AX from the very beginning (not a shadow), geometry
        // doesn't match any existing seat -> new seat as usual (must not be folded away)
        let v = verdict(cg: 240522, bounds: CGRect(x: 50, y: 50, width: 400, height: 300),
                        placed: [seat(cg: 249469, bounds: frame)])
        XCTAssertEqual(v, .newSeat)
    }

    // MARK: - Guarding against wrong merges / ambiguity

    func testReusedCgIDAfterPurgeDoesNotFold() {
        // Decision-level guard against cgID reuse: after destruction the history/shadow pool has been purged (purgeFromSeatHistories/CG intersection),
        // so a reused cgID is in no seat's history -> it can only rely on geometry; a geometry mismatch creates a new seat, no wrong absorption
        let v = verdict(cg: 240522, bounds: CGRect(x: 50, y: 50, width: 400, height: 300),
                        placed: [seat(cg: 249469, bounds: frame)])
        XCTAssertEqual(v, .newSeat)
    }

    func testAmbiguousMembershipFoldsWithoutLearning() {
        // Two seats' histories both claim the same cgID (abnormal leftover) -> still folds (no card split), but owner nil = no learning
        let v = verdict(cg: 240522, bounds: frame,
                        placed: [seat(cg: 249469, bounds: frame, former: [240522]),
                                 seat(cg: 253982, bounds: frame.offsetBy(dx: 40, dy: 40), former: [240522])])
        XCTAssertEqual(v, .fold(ownerActiveCgID: nil, reason: .membership))
    }

    func testAmbiguousFrameMatchFoldsWithoutLearning() {
        // Two seats with the same frame (overlapping windows) -> folds but doesn't learn (better to learn too little than to record the owner wrongly)
        let v = verdict(cg: 240522, bounds: frame,
                        placed: [seat(cg: 249469, bounds: frame), seat(cg: 253982, bounds: frame)])
        XCTAssertEqual(v, .fold(ownerActiveCgID: nil, reason: .exactFrame))
    }

    func testMembershipWinsOverGeometry() {
        // Membership takes priority over exact match: the candidate is in seat A's history yet has the same frame as seat B -> attributed to A
        let v = verdict(cg: 240522, bounds: frame,
                        placed: [seat(cg: 249469, bounds: frame.offsetBy(dx: 500, dy: 0), former: [240522]),
                                 seat(cg: 253982, bounds: frame)])
        XCTAssertEqual(v, .fold(ownerActiveCgID: 249469, reason: .membership))
    }
}

/// Pure phantom-seat self-heal decision (PhantomSeatDecision): all five gates must pass to release; better not to heal than to delete wrongly.
/// A phantom seat = an extra seat split off a min=true burst candidate when a fold failed (typical: the window was already minimized at dock launch,
/// seed has no history and no shadow pool); after the window is restored it leaves AX, stays in CG, and is held forever by the min-keep rule.
final class PhantomSeatDecisionTests: XCTestCase {

    private func release(
        everSeenVisible: Bool = false,
        axAbsentFor: TimeInterval = 12,
        cgStillPresent: Bool = true,
        axReadSawWindows: Bool = true,
        siblings: Int = 1
    ) -> Bool {
        PhantomSeatDecision.shouldRelease(
            everSeenVisible: everSeenVisible, axAbsentFor: axAbsentFor, threshold: 10,
            cgStillPresent: cgStillPresent, axReadSawWindows: axReadSawWindows,
            axPresentSiblingCount: siblings
        )
    }

    func testReleasesWhenAllGatesPass() {
        XCTAssertTrue(release())
    }

    func testEverSeenVisibleProtectsRealWindow() {
        // Safari-style real window: has been visible -> even if it leaves AX entirely after minimizing, it never self-heals (not losing a card on minimize is a hard guardrail)
        XCTAssertFalse(release(everSeenVisible: true))
    }

    func testUnderThresholdDoesNotRelease() {
        // An occasional AX miss for a round or two doesn't count as a phantom
        XCTAssertFalse(release(axAbsentFor: 9.9))
    }

    func testHungAppDoesNotRelease() {
        // AX read no windows at all this round (app hung) -> hold still
        XCTAssertFalse(release(axReadSawWindows: false))
    }

    func testLoneSeatNeverReleases() {
        // A lone seat never self-heals: the app's only card must not be deleted by self-heal
        XCTAssertFalse(release(siblings: 0))
    }

    func testCgGoneIsNotHealingBusiness() {
        // Out of CG means truly closed; the existing deletion path handles it, self-heal stays out
        XCTAssertFalse(release(cgStillPresent: false))
    }

    func testEvaluationExportsAllFailedGates() {
        let evaluation = PhantomSeatDecision.evaluate(
            everSeenVisible: true,
            axAbsentFor: 9.9,
            threshold: 10,
            cgStillPresent: false,
            axReadSawWindows: false,
            axPresentSiblingCount: 0
        )

        XCTAssertFalse(evaluation.shouldRelease)
        XCTAssertEqual(evaluation.holdReasons, [
            .everSeenVisible,
            .absenceGraceNotElapsed,
            .cgMissing,
            .noEligibleWindows,
            .noAXPresentSibling,
        ])
    }

    func testEvaluationExportsEachFailedGate() {
        let cases: [(PhantomSeatDecision.HoldReason, PhantomSeatDecision.Evaluation)] = [
            (.everSeenVisible, PhantomSeatDecision.evaluate(
                everSeenVisible: true, axAbsentFor: 10, threshold: 10,
                cgStillPresent: true, axReadSawWindows: true, axPresentSiblingCount: 1
            )),
            (.absenceGraceNotElapsed, PhantomSeatDecision.evaluate(
                everSeenVisible: false, axAbsentFor: 9.9, threshold: 10,
                cgStillPresent: true, axReadSawWindows: true, axPresentSiblingCount: 1
            )),
            (.cgMissing, PhantomSeatDecision.evaluate(
                everSeenVisible: false, axAbsentFor: 10, threshold: 10,
                cgStillPresent: false, axReadSawWindows: true, axPresentSiblingCount: 1
            )),
            (.noEligibleWindows, PhantomSeatDecision.evaluate(
                everSeenVisible: false, axAbsentFor: 10, threshold: 10,
                cgStillPresent: true, axReadSawWindows: false, axPresentSiblingCount: 1
            )),
            (.noAXPresentSibling, PhantomSeatDecision.evaluate(
                everSeenVisible: false, axAbsentFor: 10, threshold: 10,
                cgStillPresent: true, axReadSawWindows: true, axPresentSiblingCount: 0
            )),
        ]

        for (reason, evaluation) in cases {
            XCTAssertFalse(evaluation.shouldRelease)
            XCTAssertEqual(evaluation.holdReasons, [reason])
        }
    }

    func testEvaluationHasNoHoldReasonsWhenAllGatesPass() {
        let evaluation = PhantomSeatDecision.evaluate(
            everSeenVisible: false,
            axAbsentFor: 10,
            threshold: 10,
            cgStillPresent: true,
            axReadSawWindows: true,
            axPresentSiblingCount: 1
        )

        XCTAssertTrue(evaluation.shouldRelease)
        XCTAssertTrue(evaluation.holdReasons.isEmpty)
    }
}

/// Pass A "merge into tab" pure decision layer (TabMergeDecision).
/// Background (2026-09-12 Finder measurement): after "Merge All Windows" / dragging a tab into another window, the original window becomes an order-out background tab --
/// it leaves AX, stays in CG, onscreen=false, and its CG bounds are changed to the owning window's frame. The old path unconditionally kept the seat -> one window
/// got two cards, and then two old seats with the same frame broke tab-switch replacement, splitting off another card on every switch.
final class TabMergeDecisionTests: XCTestCase {

    private func fk(_ b: CGRect?) -> String? {
        guard let b else { return nil }
        return "\(Int(b.origin.x.rounded())):\(Int(b.origin.y.rounded())):\(Int(b.size.width.rounded())):\(Int(b.size.height.rounded()))"
    }

    private func sibling(cg: CGWindowID, bounds: CGRect?, min: Bool = false) -> TabMergeDecision.AXPresentSeat {
        TabMergeDecision.AXPresentSeat(activeCgID: cg, bounds: bounds, isMinimized: min)
    }

    private let mergedFrame = CGRect(x: 297, y: 340, width: 1227, height: 504)
    private let oldFrame = CGRect(x: 268, y: 311, width: 1227, height: 504)

    func testMergedTabReleasesAndLearnsOwner() {
        // Measured shape: the AX frame stored in the seat is still the old window position, while the CG bounds already follow the owning window; a sibling seat is present in AX with the same frame.
        let v = TabMergeDecision.verdict(
            candidateIsOnScreen: false, candidateCGBounds: mergedFrame, candidateSeatBounds: oldFrame,
            axPresentSeats: [sibling(cg: 21637, bounds: mergedFrame)], frameKey: fk
        )
        XCTAssertEqual(v, .release(ownerActiveCgID: 21637))
    }

    func testOnScreenCandidateIsNeverReleased() {
        // A single AX miss of a truly visible window: CG says it's on screen -> keep the seat, even if a same-frame sibling exists (two overlapping windows is a legitimate case).
        let v = TabMergeDecision.verdict(
            candidateIsOnScreen: true, candidateCGBounds: mergedFrame, candidateSeatBounds: mergedFrame,
            axPresentSeats: [sibling(cg: 21637, bounds: mergedFrame)], frameKey: fk
        )
        XCTAssertEqual(v, .retain)
    }

    func testNoCoFramedVisibleSiblingRetains() {
        // Off-screen + no visible same-frame sibling: may be a closed window lingering in CG (goes via tombstone) or something else; not decided here.
        let v = TabMergeDecision.verdict(
            candidateIsOnScreen: false, candidateCGBounds: oldFrame, candidateSeatBounds: oldFrame,
            axPresentSeats: [sibling(cg: 21637, bounds: mergedFrame)], frameKey: fk
        )
        XCTAssertEqual(v, .retain)
    }

    func testMinimizedSiblingDoesNotOwn() {
        // A same-frame sibling that is itself min=true (a tab in the middle of a minimize burst) -> doesn't count as a visible owner; conservatively keep the seat.
        let v = TabMergeDecision.verdict(
            candidateIsOnScreen: false, candidateCGBounds: mergedFrame, candidateSeatBounds: mergedFrame,
            axPresentSeats: [sibling(cg: 21637, bounds: mergedFrame, min: true)], frameKey: fk
        )
        XCTAssertEqual(v, .retain)
    }

    func testAmbiguousOwnersReleaseWithoutLearning() {
        let v = TabMergeDecision.verdict(
            candidateIsOnScreen: false, candidateCGBounds: mergedFrame, candidateSeatBounds: nil,
            axPresentSeats: [sibling(cg: 1, bounds: mergedFrame), sibling(cg: 2, bounds: mergedFrame)], frameKey: fk
        )
        XCTAssertEqual(v, .release(ownerActiveCgID: nil))
    }

    func testFallsBackToSeatBoundsWhenCGHasNoRect() {
        let v = TabMergeDecision.verdict(
            candidateIsOnScreen: false, candidateCGBounds: nil, candidateSeatBounds: mergedFrame,
            axPresentSeats: [sibling(cg: 21637, bounds: mergedFrame)], frameKey: fk
        )
        XCTAssertEqual(v, .release(ownerActiveCgID: 21637))
    }

    func testNoBoundsAtAllRetains() {
        let v = TabMergeDecision.verdict(
            candidateIsOnScreen: false, candidateCGBounds: nil, candidateSeatBounds: nil,
            axPresentSeats: [sibling(cg: 21637, bounds: mergedFrame)], frameKey: fk
        )
        XCTAssertEqual(v, .retain)
    }
}
