import XCTest

/// The pure decision layer for rescan admission (ScanAdmissionDecision).
///
/// The core negative case is the first one: when the raw AX list is non-empty but not a single eligible window remains after filtering, it must be rejected. The old implementation used
/// `!snaps.isEmpty`, which also admitted apps that only have fake windows -- and an AppEntry that is alive but has zero seats is never deleted,
/// leaving an un-erasable app-* card on the taskbar. The filtering must happen inside `prepare` (rather than the caller passing
/// a number in), otherwise the failure mode "production code mistakenly passes snaps.count" cannot be detected.
final class ScanAdmissionDecisionTests: XCTestCase {

    /// Fake window: a real AXWindowSnapshot contains a non-optional AXUIElement that unit tests cannot conjure up, so the pure decision layer goes generic.
    private struct FakeWindow: Equatable {
        let name: String
        let eligible: Bool
    }

    private func isEligible(_ w: FakeWindow) -> Bool { w.eligible }

    private let identityA = ScanAdmissionDecision.ProcessIdentity(
        pid: 4242, startTimeSec: 1_700_000_000, startTimeUsec: 123_456, bundleID: "com.example.app"
    )

    private func verdict(
        _ prepared: ScanAdmissionDecision.Prepared<FakeWindow>,
        probed: ScanAdmissionDecision.ProcessIdentity? = nil,
        current: ScanAdmissionDecision.ProcessIdentity? = nil,
        isRegularNonSelf: Bool = true,
        isTerminated: Bool = false,
        alreadyTracked: Bool = false
    ) -> ScanAdmissionDecision.Verdict {
        ScanAdmissionDecision.verdict(
            prepared,
            probedIdentity: probed ?? identityA,
            currentIdentity: current ?? identityA,
            isRegularNonSelf: isRegularNonSelf,
            isTerminated: isTerminated,
            alreadyTracked: alreadyTracked
        )
    }

    // MARK: - Filter wiring (core)

    /// 3 raw windows, none eligible -> eligible is empty -> rejected. What this locks is exactly the wiring fixed this time.
    func testRawWindowsPresentButNoneEligibleIsRejected() {
        let raw = [
            FakeWindow(name: "透明面板", eligible: false),
            FakeWindow(name: "扩展窗口", eligible: false),
            FakeWindow(name: "系统内部", eligible: false)
        ]
        let prepared = ScanAdmissionDecision.prepare(rawWindows: raw, isEligible: isEligible)

        XCTAssertEqual(prepared.rawCount, 3)
        XCTAssertTrue(prepared.eligible.isEmpty)
        XCTAssertFalse(prepared.readFailed)
        XCTAssertEqual(verdict(prepared), .skipNoEligible)
    }

    /// Mixed set: what is carried out must be the one window left after filtering, not the raw array.
    func testMixedWindowsCarryOnlyEligibleOnes() {
        let keeper = FakeWindow(name: "真窗口", eligible: true)
        let raw = [FakeWindow(name: "假窗口", eligible: false), keeper, FakeWindow(name: "假窗口2", eligible: false)]
        let prepared = ScanAdmissionDecision.prepare(rawWindows: raw, isEligible: isEligible)

        XCTAssertEqual(prepared.rawCount, 3)
        XCTAssertEqual(prepared.eligible, [keeper])
        XCTAssertEqual(verdict(prepared), .admit)
    }

    /// An AX read failure (.unread) and "read 0 windows" are two different things, each with its own conclusion.
    func testUnreadIsDistinctFromEmpty() {
        let unread = ScanAdmissionDecision.prepare(rawWindows: nil, isEligible: isEligible)
        XCTAssertTrue(unread.readFailed)
        XCTAssertEqual(unread.rawCount, 0)
        XCTAssertEqual(verdict(unread), .skipUnread)

        let empty = ScanAdmissionDecision.prepare(rawWindows: [FakeWindow](), isEligible: isEligible)
        XCTAssertFalse(empty.readFailed)
        XCTAssertEqual(verdict(empty), .skipNoEligible)
    }

    // MARK: - Process generation (pid reuse)

    private func eligiblePrepared() -> ScanAdmissionDecision.Prepared<FakeWindow> {
        ScanAdmissionDecision.prepare(
            rawWindows: [FakeWindow(name: "真窗口", eligible: true)],
            isEligible: isEligible
        )
    }

    func testSameIdentityAdmits() {
        XCTAssertEqual(verdict(eligiblePrepared(), probed: identityA, current: identityA), .admit)
    }

    func testDifferentPIDIsIdentityMismatch() {
        let other = ScanAdmissionDecision.ProcessIdentity(
            pid: 9999, startTimeSec: identityA.startTimeSec, startTimeUsec: identityA.startTimeUsec,
            bundleID: identityA.bundleID
        )
        XCTAssertEqual(verdict(eligiblePrepared(), probed: identityA, current: other), .skipIdentityMismatch)
    }

    func testDifferentBundleIDIsIdentityMismatch() {
        let other = ScanAdmissionDecision.ProcessIdentity(
            pid: identityA.pid, startTimeSec: identityA.startTimeSec, startTimeUsec: identityA.startTimeUsec,
            bundleID: "com.example.other"
        )
        XCTAssertEqual(verdict(eligiblePrepared(), probed: identityA, current: other), .skipIdentityMismatch)
    }

    /// The real signature of pid reuse: same pid and same bundleID, but a different launch time (a difference in either seconds or microseconds counts).
    func testDifferentStartTimeIsIdentityMismatch() {
        let laterSec = ScanAdmissionDecision.ProcessIdentity(
            pid: identityA.pid, startTimeSec: 1_700_000_099, startTimeUsec: identityA.startTimeUsec,
            bundleID: identityA.bundleID
        )
        XCTAssertEqual(verdict(eligiblePrepared(), probed: identityA, current: laterSec), .skipIdentityMismatch)

        let laterUsec = ScanAdmissionDecision.ProcessIdentity(
            pid: identityA.pid, startTimeSec: identityA.startTimeSec, startTimeUsec: 999_999,
            bundleID: identityA.bundleID
        )
        XCTAssertEqual(verdict(eligiblePrepared(), probed: identityA, current: laterUsec), .skipIdentityMismatch)
    }

    /// Launch time missing on one side only = the process is already gone; conservatively reject and wait for the next rescan.
    func testMissingStartTimeOnOneSideIsIdentityMismatch() {
        let missing = ScanAdmissionDecision.ProcessIdentity(
            pid: identityA.pid, startTimeSec: nil, startTimeUsec: nil, bundleID: identityA.bundleID
        )
        XCTAssertEqual(verdict(eligiblePrepared(), probed: identityA, current: missing), .skipIdentityMismatch)
        XCTAssertEqual(verdict(eligiblePrepared(), probed: missing, current: identityA), .skipIdentityMismatch)
    }

    /// Missing on both sides is not let through either -- "neither side knows" cannot be taken as evidence of the same process.
    func testMissingStartTimeOnBothSidesIsIdentityMismatch() {
        let missing = ScanAdmissionDecision.ProcessIdentity(
            pid: identityA.pid, startTimeSec: nil, startTimeUsec: nil, bundleID: identityA.bundleID
        )
        XCTAssertEqual(verdict(eligiblePrepared(), probed: missing, current: missing), .skipIdentityMismatch)
    }

    // MARK: - Process state (rechecked at callback time)

    func testAlreadyTrackedIsRejectedEvenWithEligibleWindows() {
        XCTAssertEqual(verdict(eligiblePrepared(), alreadyTracked: true), .skipAlreadyTracked)
    }

    func testTerminatedIsRejectedEvenWithEligibleWindows() {
        XCTAssertEqual(verdict(eligiblePrepared(), isTerminated: true), .skipTerminated)
    }

    func testNonRegularIsRejectedEvenWithEligibleWindows() {
        XCTAssertEqual(verdict(eligiblePrepared(), isRegularNonSelf: false), .skipNotRegular)
    }
}
