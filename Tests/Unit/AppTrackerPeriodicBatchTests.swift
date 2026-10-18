import ApplicationServices
import CoreGraphics
import XCTest

/// Behavior locks for the periodic reconciliation batch background read (schedulePeriodicBatchRead / completePeriodicBatch):
/// each pid is read exactly once and landed, an in-flight event read suppresses the batch read, a generation change discards the landing, and `.unread` leaves seat state untouched.
@MainActor
final class AppTrackerPeriodicBatchTests: XCTestCase {
    private let pidA: pid_t = 4242
    private let pidB: pid_t = 4343
    private let cgWindowA: CGWindowID = 77
    private let cgWindowB: CGWindowID = 88

    func testBatchReadsEachTrackedPidOnceAndAppliesResult() async {
        let reader = PeriodicBatchReader(resultsByPID: [
            pidA: .success([makeSnapshot(pid: pidA, cgWindowID: cgWindowA, title: "Renamed A")]),
            pidB: .success([makeSnapshot(pid: pidB, cgWindowID: cgWindowB, title: "Renamed B")]),
        ])
        let tracker = AppTracker(
            reader: reader,
            processProvider: BatchFixedProcessProvider(),
            eventAXAsyncEnabled: true
        )
        tracker.installFixtureForTesting(makeApp(pid: pidA, cgWindowID: cgWindowA))
        tracker.installFixtureForTesting(makeApp(pid: pidB, cgWindowID: cgWindowB))

        tracker.runPeriodicBatchForTesting(cgSnapshot: cgSnapshot())
        XCTAssertTrue(tracker.hasPendingEventReadForTesting(pid: pidA))
        XCTAssertTrue(tracker.hasPendingEventReadForTesting(pid: pidB))

        await waitUntil {
            !tracker.hasPendingEventReadForTesting(pid: self.pidA)
                && !tracker.hasPendingEventReadForTesting(pid: self.pidB)
        }

        XCTAssertEqual(reader.readCount, 2)
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pidA)?.windowsByID[cgWindowA]?.title, "Renamed A")
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pidB)?.windowsByID[cgWindowB]?.title, "Renamed B")
    }

    func testInFlightEventReadSuppressesPeriodicBatchForThatPid() async {
        let reader = PeriodicBatchReader(
            resultsByPID: [pidA: .success([makeSnapshot(pid: pidA, cgWindowID: cgWindowA, title: "Window")])],
            blocksTimedReads: true
        )
        let tracker = AppTracker(
            reader: reader,
            processProvider: BatchFixedProcessProvider(),
            cgSnapshotProvider: { [snapshot = cgSnapshot()] in snapshot },
            eventAXAsyncEnabled: true
        )
        tracker.installFixtureForTesting(makeApp(pid: pidA, cgWindowID: cgWindowA))

        tracker.scheduleEventReadForTesting(pid: pidA, source: .windowCreated)
        XCTAssertTrue(tracker.hasPendingEventReadForTesting(pid: pidA))

        // Event read in flight -> this round's batch read must skip that pid and not register a second pending.
        tracker.runPeriodicBatchForTesting(cgSnapshot: cgSnapshot())

        reader.releaseOne()
        await waitUntil { !tracker.hasPendingEventReadForTesting(pid: self.pidA) }
        // Only the one event read; the batch read did not schedule a second one for the same pid.
        XCTAssertEqual(reader.readCount, 1)
    }

    func testGenerationBumpMidFlightDiscardsBatchLanding() async {
        let provider = BatchMutableProcessProvider()
        let reader = PeriodicBatchReader(
            resultsByPID: [pidA: .success([makeSnapshot(pid: pidA, cgWindowID: cgWindowA, title: "Renamed A")])],
            blocksTimedReads: true
        )
        let tracker = AppTracker(
            reader: reader,
            processProvider: provider,
            eventAXAsyncEnabled: true
        )
        tracker.installFixtureForTesting(makeApp(pid: pidA, cgWindowID: cgWindowA))

        tracker.runPeriodicBatchForTesting(cgSnapshot: cgSnapshot())
        // The read is still stuck in the probe and the generation changes now (pid reuse): the landing must be blocked by the identity check.
        provider.advanceGeneration()
        reader.releaseOne()
        await waitUntil { !tracker.hasPendingEventReadForTesting(pid: self.pidA) }

        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pidA)?.windowsByID[cgWindowA]?.title, "Window")
    }

    func testUnreadBatchRoundLeavesSeatStateUntouched() async {
        let absence = Date(timeIntervalSince1970: 10)
        let reader = PeriodicBatchReader(resultsByPID: [pidA: .unread(.cannotComplete)])
        let tracker = AppTracker(
            reader: reader,
            processProvider: BatchFixedProcessProvider(),
            eventAXAsyncEnabled: true
        )
        var app = makeApp(pid: pidA, cgWindowID: cgWindowA)
        app.windowsByID[cgWindowA]?.isMinimized = true
        app.windowsByID[cgWindowA]?.minAbsentSince = absence
        app.shadowTabCgIDs = [91, 92]
        tracker.installFixtureForTesting(app)

        tracker.runPeriodicBatchForTesting(cgSnapshot: cgSnapshot())
        await waitUntil { !tracker.hasPendingEventReadForTesting(pid: self.pidA) }

        let after = tracker.fixtureAppForTesting(pid: pidA)
        XCTAssertEqual(after?.windowOrder, [cgWindowA])
        XCTAssertEqual(after?.windowsByID[cgWindowA]?.title, "Window")
        XCTAssertEqual(after?.windowsByID[cgWindowA]?.minAbsentSince, absence)
        XCTAssertEqual(after?.shadowTabCgIDs, [91, 92])
        XCTAssertEqual(reader.readCount, 1)
    }

    // MARK: - Skip-read gate integration (DOCK_RECONCILE_SKIP on by default)

    func testQuiescentPidIsSkippedOnSecondBatch() async {
        let reader = PeriodicBatchReader(resultsByPID: [
            pidA: .success([makeSnapshot(pid: pidA, cgWindowID: cgWindowA, title: "Window")]),
        ])
        let tracker = AppTracker(
            reader: reader,
            processProvider: BatchFixedProcessProvider(),
            eventAXAsyncEnabled: true
        )
        tracker.installFixtureForTesting(makeApp(pid: pidA, cgWindowID: cgWindowA))
        tracker.setObserverActiveForTesting(pid: pidA, active: true)

        tracker.runPeriodicBatchForTesting(cgSnapshot: cgSnapshot())
        await waitUntil { !tracker.hasPendingEventReadForTesting(pid: self.pidA) }
        XCTAssertEqual(reader.readCount, 1)

        // Second round: no events, CG set unchanged, no change in the previous round -> skip, not even registering a pending.
        tracker.runPeriodicBatchForTesting(cgSnapshot: cgSnapshot())
        XCTAssertFalse(tracker.hasPendingEventReadForTesting(pid: pidA))
        await waitUntil(timeoutNanoseconds: 300_000_000) { reader.readCount > 1 }   // Short wait to prove that no read actually happened
        XCTAssertEqual(reader.readCount, 1)
    }

    func testMinimizeEventReopensGate() async {
        let reader = PeriodicBatchReader(resultsByPID: [
            pidA: .success([makeSnapshot(pid: pidA, cgWindowID: cgWindowA, title: "Window")]),
        ])
        let tracker = AppTracker(
            reader: reader,
            processProvider: BatchFixedProcessProvider(),
            cgSnapshotProvider: { [snapshot = cgSnapshot()] in snapshot },
            eventAXAsyncEnabled: true
        )
        tracker.installFixtureForTesting(makeApp(pid: pidA, cgWindowID: cgWindowA))
        tracker.setObserverActiveForTesting(pid: pidA, active: true)

        tracker.runPeriodicBatchForTesting(cgSnapshot: cgSnapshot())
        await waitUntil { !tracker.hasPendingEventReadForTesting(pid: self.pidA) }
        tracker.runPeriodicBatchForTesting(cgSnapshot: cgSnapshot())
        XCTAssertEqual(reader.readCount, 1)

        // AX minimize event marks it dirty -> the next round must do a full read.
        tracker.minimizeForTesting(pid: pidA, cgWindowID: cgWindowA)
        tracker.runPeriodicBatchForTesting(cgSnapshot: cgSnapshot())
        await waitUntil { !tracker.hasPendingEventReadForTesting(pid: self.pidA) }
        XCTAssertEqual(reader.readCount, 2)
    }

    func testCGSetChangeReopensGate() async {
        let reader = PeriodicBatchReader(resultsByPID: [
            pidA: .success([makeSnapshot(pid: pidA, cgWindowID: cgWindowA, title: "Window")]),
        ])
        let tracker = AppTracker(
            reader: reader,
            processProvider: BatchFixedProcessProvider(),
            eventAXAsyncEnabled: true
        )
        tracker.installFixtureForTesting(makeApp(pid: pidA, cgWindowID: cgWindowA))
        tracker.setObserverActiveForTesting(pid: pidA, active: true)

        tracker.runPeriodicBatchForTesting(cgSnapshot: cgSnapshot())
        await waitUntil { !tracker.hasPendingEventReadForTesting(pid: self.pidA) }
        tracker.runPeriodicBatchForTesting(cgSnapshot: cgSnapshot())
        XCTAssertEqual(reader.readCount, 1)

        // The pid's CG layer-0 set gained a window -> must do a full read.
        let grown = AppTrackerCGWindowSnapshot(
            allWindowIDs: [cgWindowA, cgWindowB, 99],
            onScreenWindowIDs: [cgWindowA, cgWindowB, 99],
            windowIDsByPID: [pidA: [cgWindowA, 99], pidB: [cgWindowB]],
            alphaByWindowID: [:]
        )
        tracker.runPeriodicBatchForTesting(cgSnapshot: grown)
        await waitUntil { !tracker.hasPendingEventReadForTesting(pid: self.pidA) }
        XCTAssertEqual(reader.readCount, 2)
    }

    func testAbsenceClockKeepsReadingEveryBatch() async {
        // Phantom evidence must be sampled at the original cadence: a pid with an absence clock is read every round and never skipped.
        let reader = PeriodicBatchReader(resultsByPID: [pidA: .success([])])
        let tracker = AppTracker(
            reader: reader,
            processProvider: BatchFixedProcessProvider(),
            eventAXAsyncEnabled: true
        )
        var app = makeApp(pid: pidA, cgWindowID: cgWindowA)
        app.windowsByID[cgWindowA]?.isMinimized = true
        app.windowsByID[cgWindowA]?.isFocused = false
        app.windowsByID[cgWindowA]?.minAbsentSince = Date(timeIntervalSince1970: 10)
        app.windowsByID[cgWindowA]?.absenceEpisodeID = UUID()
        tracker.installFixtureForTesting(app)
        tracker.setObserverActiveForTesting(pid: pidA, active: true)

        tracker.runPeriodicBatchForTesting(cgSnapshot: cgSnapshot())
        await waitUntil { !tracker.hasPendingEventReadForTesting(pid: self.pidA) }
        XCTAssertEqual(reader.readCount, 1)

        tracker.runPeriodicBatchForTesting(cgSnapshot: cgSnapshot())
        await waitUntil { !tracker.hasPendingEventReadForTesting(pid: self.pidA) }
        XCTAssertEqual(reader.readCount, 2)
    }

    func testRefreshDueForcesReadAfterMaxSkipInterval() async {
        let uptime = UptimeBox(value: 1000)
        let reader = PeriodicBatchReader(resultsByPID: [
            pidA: .success([makeSnapshot(pid: pidA, cgWindowID: cgWindowA, title: "Window")]),
        ])
        let tracker = AppTracker(
            reader: reader,
            processProvider: BatchFixedProcessProvider(),
            eventAXAsyncEnabled: true,
            uptimeProvider: { uptime.value }
        )
        tracker.installFixtureForTesting(makeApp(pid: pidA, cgWindowID: cgWindowA))
        tracker.setObserverActiveForTesting(pid: pidA, active: true)

        tracker.runPeriodicBatchForTesting(cgSnapshot: cgSnapshot())
        await waitUntil { !tracker.hasPendingEventReadForTesting(pid: self.pidA) }
        tracker.runPeriodicBatchForTesting(cgSnapshot: cgSnapshot())
        XCTAssertEqual(reader.readCount, 1)

        // Past the 30s monotonic-clock backstop -> force a full read.
        uptime.value = 1031
        tracker.runPeriodicBatchForTesting(cgSnapshot: cgSnapshot())
        await waitUntil { !tracker.hasPendingEventReadForTesting(pid: self.pidA) }
        XCTAssertEqual(reader.readCount, 2)
    }

    func testUnreadRoundIsAlwaysRetried() async {
        let reader = PeriodicBatchReader(resultsByPID: [pidA: .unread(.cannotComplete)])
        let tracker = AppTracker(
            reader: reader,
            processProvider: BatchFixedProcessProvider(),
            eventAXAsyncEnabled: true
        )
        tracker.installFixtureForTesting(makeApp(pid: pidA, cgWindowID: cgWindowA))
        tracker.setObserverActiveForTesting(pid: pidA, active: true)

        tracker.runPeriodicBatchForTesting(cgSnapshot: cgSnapshot())
        await waitUntil { !tracker.hasPendingEventReadForTesting(pid: self.pidA) }
        tracker.runPeriodicBatchForTesting(cgSnapshot: cgSnapshot())
        await waitUntil { !tracker.hasPendingEventReadForTesting(pid: self.pidA) }
        XCTAssertEqual(reader.readCount, 2)
    }

    // MARK: - Foreground cache (next round A)

    func testFrontmostCacheDrivesActiveHighlightWithoutWorkspaceQuery() {
        let tracker = AppTracker(
            reader: PeriodicBatchReader(resultsByPID: [:]),
            processProvider: BatchFixedProcessProvider(),
            eventAXAsyncEnabled: true
        )
        tracker.installFixtureForTesting(makeApp(pid: pidA, cgWindowID: cgWindowA))

        // The cache says pidA is frontmost -> that window is active (the real frontmostApplication in the test process is someone else).
        tracker.setFrontmostPIDForTesting(pidA)
        tracker.rebuildSnapshotForTesting()
        XCTAssertEqual(tracker.snapshot.windows[WindowID(rawValue: "cgw-\(cgWindowA)")]?.status, .active)

        // The cache points to another process -> the same seat is immediately demoted to inactive.
        tracker.setFrontmostPIDForTesting(pidB)
        tracker.rebuildSnapshotForTesting()
        XCTAssertEqual(tracker.snapshot.windows[WindowID(rawValue: "cgw-\(cgWindowA)")]?.status, .inactive)
    }

    func testFrontmostCacheKillSwitchIgnoresCachedValue() {
        let tracker = AppTracker(
            reader: PeriodicBatchReader(resultsByPID: [:]),
            processProvider: BatchFixedProcessProvider(),
            eventAXAsyncEnabled: true,
            frontmostCacheEnabled: false
        )
        tracker.installFixtureForTesting(makeApp(pid: pidA, cgWindowID: cgWindowA))

        // DOCK_FRONTMOST_CACHE=0: NSWorkspace is genuinely queried every time and the cached value doesn't take part in the decision;
        // the test process's real foreground is not pidA, so the seat won't be lit.
        tracker.setFrontmostPIDForTesting(pidA)
        tracker.rebuildSnapshotForTesting()
        XCTAssertEqual(tracker.snapshot.windows[WindowID(rawValue: "cgw-\(cgWindowA)")]?.status, .inactive)
    }

    // MARK: - CG full-table reuse gate (DOCK_CG_SNAPSHOT_REUSE on by default)

    private func makeCountingTracker(
        reuseEnabled: Bool = true,
        probeBox: ProbeBox,
        counters: CGCallCounters,
        uptime: UptimeBox? = nil
    ) -> AppTracker {
        let reader = PeriodicBatchReader(resultsByPID: [
            pidA: .success([makeSnapshot(pid: pidA, cgWindowID: cgWindowA, title: "Window")]),
        ])
        let snapshot = cgSnapshot()
        let box = uptime
        return AppTracker(
            reader: reader,
            processProvider: BatchFixedProcessProvider(),
            cgSnapshotProvider: { counters.noteCapture(); return snapshot },
            onScreenWindowIDsProvider: { counters.noteProbe(); return probeBox.value },
            eventAXAsyncEnabled: true,
            cgSnapshotReuseEnabled: reuseEnabled,
            uptimeProvider: { box?.value ?? 1000 }
        )
    }

    private func runEventRead(_ tracker: AppTracker) async {
        tracker.scheduleEventReadForTesting(pid: pidA, source: .frontmostPoll)
        await waitUntil { !tracker.hasPendingEventReadForTesting(pid: self.pidA) }
    }

    func testQuietSecondEventReadReusesCachedTable() async {
        let counters = CGCallCounters()
        let tracker = makeCountingTracker(probeBox: ProbeBox(value: [cgWindowA]), counters: counters)
        tracker.installFixtureForTesting(makeApp(pid: pidA, cgWindowID: cgWindowA))
        tracker.setObserverActiveForTesting(pid: pidA, active: true)

        await runEventRead(tracker)          // No cache -> probe + fresh capture, cache hooked up
        XCTAssertNotNil(tracker.cgSnapshotCacheForTesting())
        let capturesAfterFirst = counters.captures

        await runEventRead(tracker)          // Quiet tick: probe identical -> reuse, total capture count doesn't increase
        XCTAssertEqual(counters.captures, capturesAfterFirst)
    }

    func testProbeChangeForcesFreshCapture() async {
        let counters = CGCallCounters()
        let probeBox = ProbeBox(value: [cgWindowA])
        let tracker = makeCountingTracker(probeBox: probeBox, counters: counters)
        tracker.installFixtureForTesting(makeApp(pid: pidA, cgWindowID: cgWindowA))
        tracker.setObserverActiveForTesting(pid: pidA, active: true)

        await runEventRead(tracker)
        let capturesAfterFirst = counters.captures

        probeBox.value = [cgWindowA, cgWindowB]   // the on-screen set changed (e.g. switched tabs)
        await runEventRead(tracker)
        XCTAssertEqual(counters.captures, capturesAfterFirst + 1)
    }

    func testEventGenerationBumpForcesFreshCapture() async {
        let counters = CGCallCounters()
        let tracker = makeCountingTracker(probeBox: ProbeBox(value: [cgWindowA]), counters: counters)
        tracker.installFixtureForTesting(makeApp(pid: pidA, cgWindowID: cgWindowA))
        tracker.setObserverActiveForTesting(pid: pidA, active: true)

        await runEventRead(tracker)
        let capturesAfterFirst = counters.captures

        tracker.bumpCGEventGenerationForTesting()  // an AX/workspace event arrived in the meantime
        await runEventRead(tracker)
        XCTAssertEqual(counters.captures, capturesAfterFirst + 1)
    }

    func testCacheExpiryForcesFreshCapture() async {
        let counters = CGCallCounters()
        let uptime = UptimeBox(value: 1000)
        let tracker = makeCountingTracker(
            probeBox: ProbeBox(value: [cgWindowA]), counters: counters, uptime: uptime
        )
        tracker.installFixtureForTesting(makeApp(pid: pidA, cgWindowID: cgWindowA))
        tracker.setObserverActiveForTesting(pid: pidA, active: true)

        await runEventRead(tracker)
        let capturesAfterFirst = counters.captures

        uptime.value = 1000 + CGSnapshotReuseDecision.defaultMaxCacheAge + 0.1
        await runEventRead(tracker)
        XCTAssertEqual(counters.captures, capturesAfterFirst + 1)
    }

    func testKillSwitchCapturesEveryTimeAndNeverProbes() async {
        let counters = CGCallCounters()
        let tracker = makeCountingTracker(
            reuseEnabled: false, probeBox: ProbeBox(value: [cgWindowA]), counters: counters
        )
        tracker.installFixtureForTesting(makeApp(pid: pidA, cgWindowID: cgWindowA))
        tracker.setObserverActiveForTesting(pid: pidA, active: true)

        await runEventRead(tracker)
        await runEventRead(tracker)
        // Bit-for-bit identical to before the gate: each event read takes one fresh capture. The probe count could only come from rebuildSnapshot's
        // on-screen fallback (in this case the seats don't change and nothing is rebuilt), so the event read path must not have taken a single probe.
        XCTAssertEqual(counters.captures, 2)
        XCTAssertEqual(counters.probes, 0)
        XCTAssertNil(tracker.cgSnapshotCacheForTesting())
    }

    /// A cached table may not veto: once AX lists an id the cache holds as below-normal-layer, the
    /// read captures fresh. Every other reuse condition holds here (observer active, fixed uptime,
    /// no event, unchanged probe), so only that check can cause the extra capture.
    func testCachedBelowLayerVetoForcesFreshCaptureAndSeatsRaisedWindow() async {
        let counters = CGCallCounters()
        let reader = PeriodicBatchReader(resultsByPID: [
            pidA: .success([
                makeSnapshot(pid: pidA, cgWindowID: cgWindowA, title: "Window"),
                makeSnapshot(pid: pidA, cgWindowID: cgWindowB, title: "Raised"),
            ]),
        ])
        let table = SnapshotBox(value: AppTrackerCGWindowSnapshot(
            allWindowIDs: [cgWindowA], onScreenWindowIDs: [cgWindowA],
            windowIDsByPID: [pidA: [cgWindowA]], alphaByWindowID: [:],
            belowNormalLayerWindowIDs: [cgWindowB]
        ))
        let onScreen: Set<CGWindowID> = [cgWindowA]
        let tracker = AppTracker(
            reader: reader,
            processProvider: BatchFixedProcessProvider(),
            cgSnapshotProvider: { counters.noteCapture(); return table.value },
            onScreenWindowIDsProvider: { counters.noteProbe(); return onScreen },
            eventAXAsyncEnabled: true,
            cgSnapshotReuseEnabled: true,
            uptimeProvider: { 1000 }
        )
        tracker.installFixtureForTesting(makeApp(pid: pidA, cgWindowID: cgWindowA))
        tracker.setObserverActiveForTesting(pid: pidA, active: true)

        await runEventRead(tracker)          // primes the cache; B is on the desktop layer → no seat
        XCTAssertNil(tracker.fixtureAppForTesting(pid: pidA)?.windowsByID[cgWindowB])
        let tokenA = tracker.fixtureAppForTesting(pid: pidA)?.windowsByID[cgWindowA]?.token
        let capturesAfterFirst = counters.captures

        // B rises to layer 0 while off-screen: the layer-0 on-screen probe does not change.
        table.value = AppTrackerCGWindowSnapshot(
            allWindowIDs: [cgWindowA, cgWindowB], onScreenWindowIDs: [cgWindowA],
            windowIDsByPID: [pidA: [cgWindowA, cgWindowB]], alphaByWindowID: [:]
        )
        await runEventRead(tracker)

        XCTAssertEqual(counters.captures, capturesAfterFirst + 1)
        XCTAssertNotNil(tracker.fixtureAppForTesting(pid: pidA)?.windowsByID[cgWindowB])
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pidA)?.windowsByID[cgWindowA]?.token, tokenA)
    }

    /// Accepted cost, pinned: a failed capture cannot veto, so a desktop-layer window is seated for
    /// that round and released by the next successful one.
    func testFailedCaptureSeatsDesktopLayerWindowUntilNextSuccessfulRound() async {
        let reader = PeriodicBatchReader(resultsByPID: [
            pidA: .success([
                makeSnapshot(pid: pidA, cgWindowID: cgWindowA, title: "Window"),
                makeSnapshot(pid: pidA, cgWindowID: cgWindowB, title: ""),
            ]),
        ])
        let tracker = AppTracker(
            reader: reader,
            processProvider: BatchFixedProcessProvider(),
            eventAXAsyncEnabled: true
        )
        tracker.installFixtureForTesting(makeApp(pid: pidA, cgWindowID: cgWindowA))

        tracker.runPeriodicBatchForTesting(cgSnapshot: .failed)
        await waitUntil { !tracker.hasPendingEventReadForTesting(pid: self.pidA) }
        XCTAssertNotNil(tracker.fixtureAppForTesting(pid: pidA)?.windowsByID[cgWindowB])

        tracker.runPeriodicBatchForTesting(cgSnapshot: AppTrackerCGWindowSnapshot(
            allWindowIDs: [cgWindowA], onScreenWindowIDs: [cgWindowA],
            windowIDsByPID: [pidA: [cgWindowA]], alphaByWindowID: [:],
            belowNormalLayerWindowIDs: [cgWindowB]
        ))
        await waitUntil { !tracker.hasPendingEventReadForTesting(pid: self.pidA) }
        XCTAssertNil(tracker.fixtureAppForTesting(pid: pidA)?.windowsByID[cgWindowB])
        XCTAssertNotNil(tracker.fixtureAppForTesting(pid: pidA)?.windowsByID[cgWindowA])
    }

    // MARK: - Fixtures

    /// Window-close events must go through the time-limited background read and must not trigger an unlimited read on the main actor (when the closed window's app hangs, the main thread would freeze for ~12s).
    func testWindowDestroyedUsesTimedBackgroundReadNeverUntimedMainActorRead() async {
        let reader = PeriodicBatchReader(resultsByPID: [pidA: .success([])])
        let emptyCG = AppTrackerCGWindowSnapshot(
            allWindowIDs: [], onScreenWindowIDs: [], windowIDsByPID: [:], alphaByWindowID: [:]
        )
        let tracker = AppTracker(
            reader: reader,
            processProvider: BatchFixedProcessProvider(),
            cgSnapshotProvider: { emptyCG },
            eventAXAsyncEnabled: true
        )
        tracker.installFixtureForTesting(makeApp(pid: pidA, cgWindowID: cgWindowA))

        tracker.destroyForTesting(pid: pidA, cgWindowID: cgWindowA)

        XCTAssertEqual(reader.untimedReadCount, 0, "destroy 处理器不得在主 actor 上做不限时 AX 读")
        XCTAssertTrue(tracker.hasPendingEventReadForTesting(pid: pidA))
        await waitUntil { !tracker.hasPendingEventReadForTesting(pid: self.pidA) }
        XCTAssertEqual(reader.readCount, 1)
        XCTAssertEqual(reader.untimedReadCount, 0)
        // AX empty + CG full list no longer has the window -> the seat is truly deleted.
        XCTAssertNil(tracker.fixtureAppForTesting(pid: pidA)?.windowsByID[cgWindowA])
    }

    /// A window is ordered out (destroy notification, still in CG) and, before its follow-up read
    /// lands, another window of the same app is minimized. The minimize invalidates the in-flight
    /// read; a fresh read must still follow, or the destroy's 3s tombstone expires unreconciled and
    /// the hidden window's seat is held for the app's lifetime.
    func testMinimizeDuringDestroyFollowUpReadStillReconcilesTheDestroy() async {
        let hidden: CGWindowID = 91
        let minimized: CGWindowID = 92
        let reader = PeriodicBatchReader(
            resultsByPID: [pidA: .success([makeSnapshot(pid: pidA, cgWindowID: minimized, title: "Other")])],
            blocksTimedReads: true
        )
        let bothInCG = AppTrackerCGWindowSnapshot(
            allWindowIDs: [hidden, minimized],
            onScreenWindowIDs: [minimized],
            windowIDsByPID: [pidA: [hidden, minimized]],
            alphaByWindowID: [:]
        )
        let tracker = AppTracker(
            reader: reader,
            processProvider: BatchFixedProcessProvider(),
            cgSnapshotProvider: { bothInCG },
            eventAXAsyncEnabled: true
        )
        var app = makeApp(pid: pidA, cgWindowID: hidden)
        app.windowsByID[minimized] = WindowEntry(
            cgWindowID: minimized, token: "tabgrp-\(pidA)-s2", title: "Other",
            bounds: CGRect(x: 10, y: 20, width: 500, height: 400),
            isMinimized: false, isFocused: false, everSeenVisible: true
        )
        app.windowOrder.append(minimized)
        tracker.installFixtureForTesting(app)

        tracker.destroyForTesting(pid: pidA, cgWindowID: hidden)
        XCTAssertTrue(tracker.hasPendingEventReadForTesting(pid: pidA))
        tracker.minimizeForTesting(pid: pidA, cgWindowID: minimized)

        reader.releaseOne()   // the destroy's read lands as skipped (generation moved)
        await waitUntil { reader.readCount == 2 }
        reader.releaseOne()   // the follow-up read
        await waitUntil { !tracker.hasPendingEventReadForTesting(pid: self.pidA) }

        XCTAssertNil(tracker.fixtureAppForTesting(pid: pidA)?.windowsByID[hidden])
        XCTAssertNotNil(tracker.fixtureAppForTesting(pid: pidA)?.windowsByID[minimized])
    }

    private func cgSnapshot() -> AppTrackerCGWindowSnapshot {
        AppTrackerCGWindowSnapshot(
            allWindowIDs: [cgWindowA, cgWindowB],
            onScreenWindowIDs: [cgWindowA, cgWindowB],
            windowIDsByPID: [pidA: [cgWindowA], pidB: [cgWindowB]],
            alphaByWindowID: [:]
        )
    }

    private func makeApp(pid: pid_t, cgWindowID: CGWindowID) -> AppEntry {
        let seat = WindowEntry(
            cgWindowID: cgWindowID,
            token: "tabgrp-\(pid)-s1",
            title: "Window",
            bounds: CGRect(x: 10, y: 20, width: 500, height: 400),
            isMinimized: false,
            isFocused: true,
            everSeenVisible: true
        )
        return AppEntry(
            pid: pid,
            bundleIdentifier: "com.example.fixture\(pid)",
            appName: "Fixture\(pid)",
            activationPolicy: .regular,
            executablePath: "/Applications/Fixture.app",
            windowsByID: [cgWindowID: seat],
            windowOrder: [cgWindowID],
            isHidden: false
        )
    }

    private func makeSnapshot(pid: pid_t, cgWindowID: CGWindowID, title: String) -> AXWindowSnapshot {
        AXWindowSnapshot(
            pid: pid,
            cgWindowID: cgWindowID,
            titleRead: .value(title),
            bounds: CGRect(x: 10, y: 20, width: 500, height: 400),
            role: kAXWindowRole as String,
            subrole: kAXStandardWindowSubrole as String,
            isMinimized: false,
            isFocusedWindow: true,
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

/// A time-limited read probe whose result can be customized per pid; optionally blocks mid-read (simulating the window where a batch read is in flight).
private final class PeriodicBatchReader: AppTrackerWindowReading, @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var count = 0
    private var untimedCount = 0
    private let resultsByPID: [pid_t: AXWindowReadResult]
    private let blocksTimedReads: Bool

    init(resultsByPID: [pid_t: AXWindowReadResult], blocksTimedReads: Bool = false) {
        self.resultsByPID = resultsByPID
        self.blocksTimedReads = blocksTimedReads
    }

    var readCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func releaseOne() {
        semaphore.signal()
    }

    func windows(forPID pid: pid_t) -> [AXWindowSnapshot] { [] }

    var untimedReadCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return untimedCount
    }

    func windowReadResult(forPID pid: pid_t) -> AXWindowReadResult {
        lock.lock()
        untimedCount += 1
        lock.unlock()
        return resultsByPID[pid] ?? .unread(.cannotComplete)
    }

    func inventoryWindows(forPID pid: pid_t, messagingTimeout: TimeInterval) -> AXWindowReadResult {
        lock.lock()
        count += 1
        lock.unlock()
        if blocksTimedReads { semaphore.wait() }
        return resultsByPID[pid] ?? .unread(.cannotComplete)
    }
}

private final class CGCallCounters: @unchecked Sendable {
    private let lock = NSLock()
    private var captureCount = 0
    private var probeCount = 0

    func noteCapture() { lock.lock(); captureCount += 1; lock.unlock() }
    func noteProbe() { lock.lock(); probeCount += 1; lock.unlock() }

    var captures: Int { lock.lock(); defer { lock.unlock() }; return captureCount }
    var probes: Int { lock.lock(); defer { lock.unlock() }; return probeCount }
}

private final class ProbeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Set<CGWindowID>

    init(value: Set<CGWindowID>) { self.storage = value }

    var value: Set<CGWindowID> {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}

private final class SnapshotBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: AppTrackerCGWindowSnapshot

    init(value: AppTrackerCGWindowSnapshot) { self.storage = value }

    var value: AppTrackerCGWindowSnapshot {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}

private final class UptimeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: TimeInterval

    init(value: TimeInterval) {
        self.storage = value
    }

    var value: TimeInterval {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}

private struct BatchFixedProcessProvider: AppTrackerProcessProviding {
    func isAlive(pid: pid_t) -> Bool { true }

    func identity(pid: pid_t, bundleID: String?) -> ScanAdmissionDecision.ProcessIdentity {
        ScanAdmissionDecision.ProcessIdentity(pid: pid, startTimeSec: 1, startTimeUsec: 2, bundleID: bundleID)
    }
}

private final class BatchMutableProcessProvider: AppTrackerProcessProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var generation: Int64 = 1

    func advanceGeneration() {
        lock.lock()
        generation += 1
        lock.unlock()
    }

    func isAlive(pid: pid_t) -> Bool { true }

    func identity(pid: pid_t, bundleID: String?) -> ScanAdmissionDecision.ProcessIdentity {
        lock.lock()
        let current = generation
        lock.unlock()
        return ScanAdmissionDecision.ProcessIdentity(
            pid: pid,
            startTimeSec: current,
            startTimeUsec: 0,
            bundleID: bundleID
        )
    }
}
