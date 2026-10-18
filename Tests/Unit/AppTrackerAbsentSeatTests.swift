import ApplicationServices
import CoreGraphics
import XCTest

/// The absence fallback wired into `AppTracker`: a seat whose window left AX while staying in CG,
/// not minimized, not hidden. Mirrors the Bilibili 1.18 player window (`main` stays, `player` is hidden
/// without a destroy notification).
@MainActor
final class AppTrackerAbsentSeatTests: XCTestCase {
    private let pid: pid_t = 5151
    private let main: CGWindowID = 10
    private let player: CGWindowID = 20
    private let instance: UInt64 = 7

    // MARK: - Synchronous reconcile path

    func testHiddenPlayerIsReleasedAfterTwoProbesTwoSecondsApart() {
        let (tracker, clock) = makeTracker()
        reconcile(tracker)
        XCTAssertEqual(probe(tracker)?.nextProbeUptime, 1000, "a fresh candidate is due at once")

        reconcile(tracker, evidence: evidence(.dead))
        XCTAssertNotNil(seat(tracker, player), "one probe never releases")
        XCTAssertEqual(probe(tracker)?.firstHidden?.uptime, 1000)
        XCTAssertEqual(probe(tracker)?.nextProbeUptime, 1002)

        clock.value = 1002.5
        reconcile(tracker, evidence: evidence(.dead))
        XCTAssertNil(seat(tracker, player))
        XCTAssertNotNil(seat(tracker, main))
    }

    func testSecondProbeTooSoonHoldsTheMarkThenConfirms() {
        let (tracker, clock) = makeTracker()
        reconcile(tracker, evidence: evidence(.dead))
        clock.value = 1001
        reconcile(tracker, evidence: evidence(.dead))
        XCTAssertNotNil(seat(tracker, player))
        XCTAssertEqual(probe(tracker)?.firstHidden?.uptime, 1000)
        XCTAssertEqual(probe(tracker)?.nextProbeUptime, 1002)

        clock.value = 1002
        reconcile(tracker, evidence: evidence(.dead))
        XCTAssertNil(seat(tracker, player))
    }

    func testReappearanceBetweenProbesRestartsConfirmation() {
        let (tracker, clock) = makeTracker()
        reconcile(tracker, evidence: evidence(.dead))
        clock.value = 1001
        reconcile(tracker, ax: [main, player], onScreen: [main, player])
        XCTAssertNil(probe(tracker), "a seat rebuilt from AX carries no probe state")

        clock.value = 1003
        reconcile(tracker, evidence: evidence(.dead))
        XCTAssertNotNil(seat(tracker, player))
        XCTAssertEqual(probe(tracker)?.firstHidden?.uptime, 1003)
    }

    func testMinimizeEventBetweenProbesRestartsConfirmation() {
        let (tracker, clock) = makeTracker()
        reconcile(tracker, evidence: evidence(.dead))
        tracker.minimizeForTesting(pid: pid, cgWindowID: main)
        XCTAssertNil(probe(tracker)?.firstHidden)

        clock.value = 1003
        reconcile(tracker, evidence: evidence(.dead))
        XCTAssertNotNil(seat(tracker, player))
        XCTAssertEqual(probe(tracker)?.firstHidden?.uptime, 1003)
    }

    func testHideEventDropsTheMark() {
        let (tracker, _) = makeTracker()
        reconcile(tracker, evidence: evidence(.dead))
        tracker.clearFirstHiddenMarksViaHideForTesting(pid: pid)
        XCTAssertNil(probe(tracker)?.firstHidden)
    }

    /// The other-Space window: live element, non-current Space → held, mark cleared.
    func testLiveElementOnAnotherSpaceIsHeld() {
        let (tracker, clock) = makeTracker()
        reconcile(tracker, evidence: evidence(.dead))
        clock.value = 1003
        reconcile(tracker, evidence: evidence(.alive(minimized: false), spaces: [6013]))
        XCTAssertNotNil(seat(tracker, player))
        XCTAssertNil(probe(tracker)?.firstHidden)
    }

    /// Still in raw AXWindows but filtered out (an AppKit window turns `AXDialog` when minimized):
    /// never a candidate, even with dead-element evidence.
    func testWindowStillInRawAXIsNeverACandidate() {
        let (tracker, clock) = makeTracker()
        reconcile(tracker, evidence: evidence(.dead))
        clock.value = 1003
        reconcile(tracker, rawAX: [main, player], evidence: evidence(.dead))
        XCTAssertNotNil(seat(tracker, player))
        XCTAssertNil(probe(tracker))
    }

    func testOnScreenWindowIsNeverACandidate() {
        let (tracker, _) = makeTracker()
        reconcile(tracker, onScreen: [main, player], evidence: evidence(.dead))
        XCTAssertNotNil(seat(tracker, player))
        XCTAssertNil(probe(tracker))
    }

    func testNeverSubscribedWindowIsNeverACandidate() {
        let (tracker, _) = makeTracker(subscribed: false)
        reconcile(tracker)
        XCTAssertNil(probe(tracker))
        XCTAssertTrue(tracker.takeDueAbsenceProbesForTesting(pid: pid).isEmpty)
    }

    /// Seed / scan / legacy reads carry no raw AX set: they neither create nor consume probes.
    func testReadWithoutRawAXSetCreatesNoCandidate() {
        let (tracker, _) = makeTracker()
        reconcile(tracker, withoutRawAX: true, evidence: evidence(.dead))
        XCTAssertNil(probe(tracker))
    }

    func testMinimizedSeatTakesTheMinimizedBranch() {
        let (tracker, _) = makeTracker(playerMinimized: true)
        reconcile(tracker, evidence: evidence(.dead))
        XCTAssertNotNil(seat(tracker, player))
        XCTAssertNil(probe(tracker))
    }

    func testEvidenceForAnotherSubscriptionInstanceIsDiscarded() {
        let (tracker, clock) = makeTracker()
        reconcile(tracker, evidence: evidence(.dead))
        clock.value = 1003
        reconcile(tracker, evidence: evidence(.dead, instanceID: 9))
        XCTAssertNotNil(seat(tracker, player))
        XCTAssertNil(probe(tracker)?.firstHidden)
    }

    func testKillSwitchOffDoesNothing() {
        let (tracker, clock) = makeTracker(enabled: false)
        reconcile(tracker, evidence: evidence(.dead))
        clock.value = 1003
        reconcile(tracker, evidence: evidence(.dead))
        XCTAssertNotNil(seat(tracker, player))
        XCTAssertNil(probe(tracker))
    }

    func testDispatchChargesTheBudget() {
        let (tracker, clock) = makeTracker()
        reconcile(tracker)
        let first = tracker.takeDueAbsenceProbesForTesting(pid: pid)
        XCTAssertEqual(first.map(\.cgWindowID), [player])
        XCTAssertEqual(first.first?.instanceID, instance)
        XCTAssertEqual(probe(tracker)?.probeCount, 1)
        XCTAssertEqual(probe(tracker)?.nextProbeUptime, 1002)
        XCTAssertTrue(tracker.takeDueAbsenceProbesForTesting(pid: pid).isEmpty)

        clock.value = 1002
        _ = tracker.takeDueAbsenceProbesForTesting(pid: pid)
        XCTAssertEqual(probe(tracker)?.nextProbeUptime, 1007)
    }

    // MARK: - Event-read path (probes ride the background read)

    func testEventReadsProbeAndReleaseEndToEnd() async {
        let prober = FakeProber(element: .dead, spaces: [1])
        let (tracker, clock) = makeTracker(prober: prober, reader: FixedReader(.success([axWindow(main)])))
        tracker.scheduleEventReadForTesting(pid: pid, source: .focusChanged)
        // Landing creates the candidate and dispatches the probe read immediately.
        await waitUntil { prober.calls == 1 && !tracker.hasPendingEventReadForTesting(pid: self.pid) }
        XCTAssertEqual(probe(tracker)?.firstHidden?.uptime, 1000)
        XCTAssertTrue(tracker.absenceProbeTimerPIDsForTesting.contains(pid), "confirmation timer armed")

        clock.value = 1002.5
        tracker.scheduleEventReadForTesting(pid: pid, source: .absenceProbe)
        await waitUntil { !tracker.hasPendingEventReadForTesting(pid: self.pid) && prober.calls == 2 }
        await waitUntil { self.seat(tracker, self.player) == nil }
        XCTAssertNil(seat(tracker, player))
        XCTAssertNotNil(seat(tracker, main))
    }

    func testUnreadRoundRunsNoProbeButKeepsTheCharge() async {
        let prober = FakeProber(element: .dead, spaces: [1])
        let (tracker, _) = makeTracker(prober: prober, reader: FixedReader(.unread(.cannotComplete)))
        reconcile(tracker)
        tracker.scheduleEventReadForTesting(pid: pid, source: .absenceProbe)
        await waitUntil { !tracker.hasPendingEventReadForTesting(pid: self.pid) }
        XCTAssertEqual(prober.calls, 0)
        XCTAssertEqual(probe(tracker)?.probeCount, 1)
        XCTAssertEqual(probe(tracker)?.nextProbeUptime, 1002)
    }

    // MARK: - Fixtures

    private func makeTracker(
        enabled: Bool = true,
        subscribed: Bool = true,
        playerMinimized: Bool = false,
        prober: FakeProber = FakeProber(element: .dead, spaces: [1]),
        reader: FixedReader? = nil
    ) -> (AppTracker, Clock) {
        let clock = Clock(1000)
        let snapshot = cg(onScreen: [main])
        let tracker = AppTracker(
            reader: reader ?? FixedReader(.success([axWindow(main)])),
            processProvider: FixedProcessProvider(),
            cgSnapshotProvider: { snapshot },
            eventAXAsyncEnabled: true,
            absentSeatReleaseEnabled: enabled,
            absentSeatProber: prober,
            uptimeProvider: { clock.value }
        )
        var app = AppEntry(
            pid: pid, bundleIdentifier: "tv.danmaku.bili", appName: "哔哩哔哩",
            activationPolicy: .regular, executablePath: "/Applications/哔哩哔哩.app",
            windowsByID: [:], windowOrder: [main, player], isHidden: false
        )
        app.windowsByID[main] = WindowEntry(
            cgWindowID: main, token: "tabgrp-\(pid)-s1", title: "哔哩哔哩", bounds: frame(main),
            isMinimized: false, isFocused: true, everSeenVisible: true
        )
        app.windowsByID[player] = WindowEntry(
            cgWindowID: player, token: "tabgrp-\(pid)-s2", title: "Player", bounds: frame(player),
            isMinimized: playerMinimized, isFocused: false, everSeenVisible: true
        )
        tracker.installFixtureForTesting(app)
        if subscribed {
            tracker.setSubscribedElementForTesting(
                pid: pid, cgWindowID: player, element: AXUIElementCreateApplication(pid), instanceID: instance
            )
        }
        tracker.setSubscribedElementForTesting(
            pid: pid, cgWindowID: main, element: AXUIElementCreateApplication(pid), instanceID: 3
        )
        return (tracker, clock)
    }

    @discardableResult
    private func reconcile(
        _ tracker: AppTracker,
        ax: [CGWindowID]? = nil,
        rawAX: Set<CGWindowID>? = nil,
        withoutRawAX: Bool = false,
        onScreen: Set<CGWindowID>? = nil,
        evidence: AbsentSeatProbeEvidence? = nil
    ) -> Bool {
        let axIDs = ax ?? [main]
        let raw: Set<CGWindowID>? = withoutRawAX ? nil : (rawAX ?? Set(axIDs))
        return tracker.reconcileFixtureForTesting(
            pid: pid,
            cgSnapshot: cg(onScreen: onScreen ?? [main]),
            now: Date(),
            eligible: axIDs.map(axWindow),
            readOutcome: .success(count: axIDs.count),
            rawAXCgIDs: raw,
            absenceEvidence: evidence.map { [player: $0] } ?? [:]
        )
    }

    private func evidence(
        _ element: AbsentSeatReleaseDecision.ElementState,
        spaces: [Int] = [1],
        instanceID: UInt64? = nil
    ) -> AbsentSeatProbeEvidence {
        AbsentSeatProbeEvidence(
            request: AbsentSeatProbeRequest(
                cgWindowID: player, seatToken: "tabgrp-\(pid)-s2",
                element: AXUIElementCreateApplication(pid), instanceID: instanceID ?? instance, probeCount: 1
            ),
            element: element,
            windowSpaceIDs: spaces,
            currentSpaceIDs: [1, 14255]
        )
    }

    private func seat(_ tracker: AppTracker, _ cgID: CGWindowID) -> WindowEntry? {
        tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgID]
    }

    private func probe(_ tracker: AppTracker) -> AbsentSeatProbeState? {
        seat(tracker, player)?.absentProbe
    }

    private func frame(_ cgID: CGWindowID) -> CGRect {
        cgID == main ? CGRect(x: 40, y: 160, width: 1268, height: 704) : CGRect(x: 30, y: 200, width: 951, height: 718)
    }

    private func cg(onScreen: Set<CGWindowID>) -> AppTrackerCGWindowSnapshot {
        AppTrackerCGWindowSnapshot(
            allWindowIDs: [main, player],
            onScreenWindowIDs: onScreen,
            windowIDsByPID: [pid: [main, player]],
            alphaByWindowID: [:]
        )
    }

    private func axWindow(_ cgID: CGWindowID) -> AXWindowSnapshot {
        AXWindowSnapshot(
            pid: pid,
            cgWindowID: cgID,
            titleRead: .value(cgID == main ? "哔哩哔哩" : "Player"),
            bounds: frame(cgID),
            role: kAXWindowRole as String,
            subrole: kAXStandardWindowSubrole as String,
            isMinimized: false,
            isFocusedWindow: cgID == main,
            element: AXUIElementCreateApplication(pid)
        )
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 2_000_000_000,
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        let start = DispatchTime.now().uptimeNanoseconds
        while !condition(), DispatchTime.now().uptimeNanoseconds - start < timeoutNanoseconds {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: TimeInterval
    init(_ value: TimeInterval) { storage = value }
    var value: TimeInterval {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}

private final class FakeProber: AbsentSeatProbing, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let element: AbsentSeatReleaseDecision.ElementState
    private let spaces: [Int]

    init(element: AbsentSeatReleaseDecision.ElementState, spaces: [Int]) {
        self.element = element
        self.spaces = spaces
    }

    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }

    func probe(_ request: AbsentSeatProbeRequest, messagingTimeout: TimeInterval) -> AbsentSeatProbeEvidence {
        lock.lock(); count += 1; lock.unlock()
        return AbsentSeatProbeEvidence(request: request, element: element, windowSpaceIDs: spaces, currentSpaceIDs: [1])
    }
}

private final class FixedReader: AppTrackerWindowReading, @unchecked Sendable {
    private let result: AXWindowReadResult
    init(_ result: AXWindowReadResult) { self.result = result }
    func windows(forPID pid: pid_t) -> [AXWindowSnapshot] { [] }
    func windowReadResult(forPID pid: pid_t) -> AXWindowReadResult { result }
    func inventoryWindows(forPID pid: pid_t, messagingTimeout: TimeInterval) -> AXWindowReadResult { result }
}

private struct FixedProcessProvider: AppTrackerProcessProviding {
    func isAlive(pid: pid_t) -> Bool { true }
    func identity(pid: pid_t, bundleID: String?) -> ScanAdmissionDecision.ProcessIdentity {
        ScanAdmissionDecision.ProcessIdentity(pid: pid, startTimeSec: 1, startTimeUsec: 2, bundleID: bundleID)
    }
}
