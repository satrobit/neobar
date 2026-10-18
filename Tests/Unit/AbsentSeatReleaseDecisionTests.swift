import CoreGraphics
import XCTest

/// Verdict matrix of the absence fallback: only a dead element on a current / no Space, confirmed
/// 2–10s later for the same cgID and subscription instance, releases.
final class AbsentSeatReleaseDecisionTests: XCTestCase {
    private func input(
        element: AbsentSeatReleaseDecision.ElementState = .dead,
        spaces: AbsentSeatReleaseDecision.SpaceClass = .onlyCurrent,
        firstHiddenAt: TimeInterval? = nil,
        firstCgID: CGWindowID = 20,
        firstInstance: UInt64 = 7,
        matches: Bool = true,
        now: TimeInterval = 100
    ) -> AbsentSeatReleaseDecision.Input {
        AbsentSeatReleaseDecision.Input(
            evidenceMatchesSeat: matches,
            element: element,
            spaces: spaces,
            firstHidden: firstHiddenAt.map {
                AbsentSeatProbeState.FirstHiddenMark(uptime: $0, cgWindowID: firstCgID, instanceID: firstInstance)
            },
            cgWindowID: 20,
            instanceID: 7,
            now: now
        )
    }

    func testFirstHiddenProbeOnlyMarks() {
        XCTAssertEqual(AbsentSeatReleaseDecision.verdict(input()), .markFirst)
        XCTAssertEqual(AbsentSeatReleaseDecision.verdict(input(spaces: .none)), .markFirst)
    }

    func testConfirmationWindowIsTwoToTenSeconds() {
        XCTAssertEqual(AbsentSeatReleaseDecision.verdict(input(firstHiddenAt: 98.5)), .holdMark)
        XCTAssertEqual(AbsentSeatReleaseDecision.verdict(input(firstHiddenAt: 98)), .release)
        XCTAssertEqual(AbsentSeatReleaseDecision.verdict(input(firstHiddenAt: 90)), .release)
        XCTAssertEqual(AbsentSeatReleaseDecision.verdict(input(firstHiddenAt: 89.9)), .markFirst)
    }

    func testMarkForAnotherCgIDOrInstanceDoesNotConfirm() {
        XCTAssertEqual(AbsentSeatReleaseDecision.verdict(input(firstHiddenAt: 97, firstCgID: 21)), .markFirst)
        XCTAssertEqual(AbsentSeatReleaseDecision.verdict(input(firstHiddenAt: 97, firstInstance: 9)), .markFirst)
    }

    /// The other-Space case: a live element answering `min == false` must never count as hidden.
    func testLiveElementIsNeverHidden() {
        XCTAssertEqual(
            AbsentSeatReleaseDecision.verdict(input(element: .alive(minimized: false), firstHiddenAt: 97)),
            .notHidden(.elementAlive)
        )
        XCTAssertEqual(
            AbsentSeatReleaseDecision.verdict(input(element: .alive(minimized: true))),
            .notHidden(.elementAlive)
        )
    }

    func testUnknownElementOrSpaceIsNotHidden() {
        XCTAssertEqual(
            AbsentSeatReleaseDecision.verdict(input(element: .unknown(errorCode: -25204), firstHiddenAt: 97)),
            .notHidden(.elementUnknown)
        )
        XCTAssertEqual(
            AbsentSeatReleaseDecision.verdict(input(spaces: .unknown, firstHiddenAt: 97)),
            .notHidden(.spaceUnknown)
        )
    }

    func testDeadElementOnAnotherSpaceIsNotHidden() {
        XCTAssertEqual(
            AbsentSeatReleaseDecision.verdict(input(spaces: .includesNonCurrent, firstHiddenAt: 97)),
            .notHidden(.onNonCurrentSpace)
        )
    }

    func testMismatchedEvidenceIsNotHidden() {
        XCTAssertEqual(
            AbsentSeatReleaseDecision.verdict(input(firstHiddenAt: 97, matches: false)),
            .notHidden(.evidenceMismatch)
        )
    }

    func testSpaceClassification() {
        typealias C = AbsentSeatReleaseDecision.SpaceClass
        XCTAssertEqual(C.classify(windowSpaceIDs: nil, currentSpaceIDs: [1]), .unknown)
        XCTAssertEqual(C.classify(windowSpaceIDs: [1], currentSpaceIDs: nil), .unknown)
        XCTAssertEqual(C.classify(windowSpaceIDs: [], currentSpaceIDs: [1]), .none)
        XCTAssertEqual(C.classify(windowSpaceIDs: [1, 14255], currentSpaceIDs: [1, 14255]), .onlyCurrent)
        XCTAssertEqual(C.classify(windowSpaceIDs: [6013], currentSpaceIDs: [1, 14255]), .includesNonCurrent)
        XCTAssertEqual(C.classify(windowSpaceIDs: [1, 6013], currentSpaceIDs: [1]), .includesNonCurrent)
    }

    func testBackoffSchedule() {
        XCTAssertEqual(AbsentSeatReleaseDecision.backoff(afterDispatch: 1), 2)
        XCTAssertEqual(AbsentSeatReleaseDecision.backoff(afterDispatch: 2), 5)
        XCTAssertEqual(AbsentSeatReleaseDecision.backoff(afterDispatch: 3), 15)
        XCTAssertEqual(AbsentSeatReleaseDecision.backoff(afterDispatch: 4), 60)
        XCTAssertEqual(AbsentSeatReleaseDecision.backoff(afterDispatch: 40), 60)
    }
}
