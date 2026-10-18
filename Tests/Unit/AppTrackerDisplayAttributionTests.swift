import ApplicationServices
import CoreGraphics
import XCTest

/// Inventory side of multi-screen case 4: when a seat's coarse-grained ownership key (`WindowEntry.displayUUID`) changes and when it is published.
/// Locks down three things: moving across screens publishes (moving within a screen does not); minimized / hidden seats freeze on the last visible screen;
/// a pid skipped by the skip-read gate can still change screens via the 5s tick's CG bounds traversal.
@MainActor
final class AppTrackerDisplayAttributionTests: XCTestCase {
    private let pid: pid_t = 5151
    private let cgWindow: CGWindowID = 91

    private let frameOnA = CGRect(x: 100, y: 100, width: 500, height: 400)
    private let frameOnAMoved = CGRect(x: 300, y: 150, width: 500, height: 400)
    private let frameOnB = CGRect(x: 1200, y: 100, width: 500, height: 400)

    private let tableAB = WindowDisplayAttribution.Table(
        displays: [
            .init(uuid: "A", cgFrame: CGRect(x: 0, y: 0, width: 1000, height: 800)),
            .init(uuid: "B", cgFrame: CGRect(x: 1000, y: 0, width: 1000, height: 800)),
        ],
        primaryUUID: "A"
    )

    func testMovingAcrossDisplaysChangesTheSignatureAndPublishes() {
        let tracker = makeTracker()
        tracker.installFixtureForTesting(makeApp(displayUUID: "A"))
        tracker.rebuildSnapshotForTesting()
        XCTAssertEqual(tracker.snapshot.windows[WindowID(rawValue: "cgw-\(cgWindow)")]?.displayUUID, "A")

        let changed = tracker.reconcileFixtureForTesting(
            pid: pid, cgSnapshot: cgSnapshot(), now: Date(),
            eligible: [makeSnapshot(bounds: frameOnB, isMinimized: false)],
            readOutcome: .success(count: 1)
        )

        XCTAssertTrue(changed, "跨屏移动必须算作座位变化，否则清单永远不发布新位置")
        tracker.rebuildSnapshotForTesting()
        XCTAssertEqual(tracker.snapshot.windows[WindowID(rawValue: "cgw-\(cgWindow)")]?.displayUUID, "B")
    }

    func testMovingWithinOneDisplayIsNotAChange() {
        let tracker = makeTracker()
        tracker.installFixtureForTesting(makeApp(displayUUID: "A"))
        tracker.rebuildSnapshotForTesting()
        let before = tracker.snapshot

        let changed = tracker.reconcileFixtureForTesting(
            pid: pid, cgSnapshot: cgSnapshot(), now: Date(),
            eligible: [makeSnapshot(bounds: frameOnAMoved, isMinimized: false)],
            readOutcome: .success(count: 1)
        )

        XCTAssertFalse(changed, "同屏内移动不能触发重建（指纹只含粗粒度键，不含坐标）")
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.displayUUID, "A")
        XCTAssertEqual(tracker.snapshot, before)
    }

    func testMinimizedSeatKeepsItsLastVisibleDisplay() {
        let tracker = makeTracker()
        tracker.installFixtureForTesting(makeApp(displayUUID: "A", isMinimized: true))

        // AX path: a minimized window reads its frame on another screen; the key does not move.
        let changed = tracker.reconcileFixtureForTesting(
            pid: pid, cgSnapshot: cgSnapshot(), now: Date(),
            eligible: [makeSnapshot(bounds: frameOnB, isMinimized: true)],
            readOutcome: .success(count: 1)
        )
        XCTAssertFalse(changed)
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.displayUUID, "A")

        // CG path: the tick's bounds traversal likewise skips minimized seats.
        let cgChanged = tracker.refreshDisplayAttributionFromCGForTesting(
            cgSnapshot: cgSnapshot(bounds: [cgWindow: frameOnB])
        )
        XCTAssertFalse(cgChanged)
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.displayUUID, "A")
    }

    func testHiddenAppKeepsItsLastVisibleDisplay() {
        let tracker = makeTracker()
        tracker.installFixtureForTesting(makeApp(displayUUID: "A", isHidden: true))

        let changed = tracker.reconcileFixtureForTesting(
            pid: pid, cgSnapshot: cgSnapshot(), now: Date(),
            eligible: [makeSnapshot(bounds: frameOnB, isMinimized: false)],
            readOutcome: .success(count: 1)
        )
        XCTAssertFalse(changed)
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.displayUUID, "A")
    }

    func testPeriodicCGPassMovesVisibleSeatsWithoutAnAXRead() {
        let tracker = makeTracker()
        tracker.installFixtureForTesting(makeApp(displayUUID: "A"))

        XCTAssertFalse(tracker.refreshDisplayAttributionFromCGForTesting(
            cgSnapshot: cgSnapshot(bounds: [cgWindow: frameOnAMoved])
        ))
        // The first tick that sees the new display only proposes it; the second agreeing tick applies it.
        XCTAssertFalse(tracker.refreshDisplayAttributionFromCGForTesting(
            cgSnapshot: cgSnapshot(bounds: [cgWindow: frameOnB])
        ))
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.displayUUID, "A")
        XCTAssertTrue(tracker.refreshDisplayAttributionFromCGForTesting(
            cgSnapshot: cgSnapshot(bounds: [cgWindow: frameOnB])
        ))
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.displayUUID, "B")
        // Change only the key, leave the AX frame alone (`frameKey` / `seatsAtFrame` rely on it).
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.bounds, frameOnA)
    }

    /// The minimize animation drives the CG bounds across to the system Dock's display before the AX
    /// `min=true` read lands. A tick that samples it mid-flight must not move the seat — the minimize
    /// would then freeze it on the wrong display.
    func testATickDuringTheMinimizeAnimationDoesNotMoveTheSeat() {
        let tracker = makeTracker()
        tracker.installFixtureForTesting(makeApp(displayUUID: "A"))
        let midAnimation = CGRect(x: 1400, y: 500, width: 120, height: 90)

        XCTAssertFalse(tracker.refreshDisplayAttributionFromCGForTesting(
            cgSnapshot: cgSnapshot(bounds: [cgWindow: midAnimation])
        ))
        _ = tracker.reconcileFixtureForTesting(
            pid: pid, cgSnapshot: cgSnapshot(), now: Date(),
            eligible: [makeSnapshot(bounds: frameOnA, isMinimized: true)],
            readOutcome: .success(count: 1)
        )
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.displayUUID, "A")

        // Restored and sampled mid-flight again: the earlier proposal is gone, so this is a first sighting.
        _ = tracker.reconcileFixtureForTesting(
            pid: pid, cgSnapshot: cgSnapshot(), now: Date(),
            eligible: [makeSnapshot(bounds: frameOnA, isMinimized: false)],
            readOutcome: .success(count: 1)
        )
        XCTAssertFalse(tracker.refreshDisplayAttributionFromCGForTesting(
            cgSnapshot: cgSnapshot(bounds: [cgWindow: frameOnA])
        ))
        XCTAssertFalse(tracker.refreshDisplayAttributionFromCGForTesting(
            cgSnapshot: cgSnapshot(bounds: [cgWindow: midAnimation])
        ))
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.displayUUID, "A")
    }

    func testUnknownCGBoundsLeaveTheKeyAlone() {
        let tracker = makeTracker()
        tracker.installFixtureForTesting(makeApp(displayUUID: "A"))
        XCTAssertFalse(tracker.refreshDisplayAttributionFromCGForTesting(cgSnapshot: cgSnapshot()))
        XCTAssertFalse(tracker.refreshDisplayAttributionFromCGForTesting(
            cgSnapshot: cgSnapshot(bounds: [cgWindow: CGRect(x: 9000, y: 9000, width: 10, height: 10)])
        ))
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.displayUUID, "A")
    }

    func testScreenParametersChangeReattributesFromStoredBounds() {
        let box = TableBox(tableAB)
        let tracker = makeTracker(tableProvider: { box.table })
        // The AX frame stored on the seat is in region B, but when installed the key still says A (simulating a screen table that has just changed).
        tracker.installFixtureForTesting(makeApp(bounds: frameOnB, displayUUID: "A"))
        tracker.rebuildSnapshotForTesting()

        // The screen table changes to "region B is now called C".
        box.table = WindowDisplayAttribution.Table(
            displays: [
                .init(uuid: "A", cgFrame: CGRect(x: 0, y: 0, width: 1000, height: 800)),
                .init(uuid: "C", cgFrame: CGRect(x: 1000, y: 0, width: 1000, height: 800)),
            ],
            primaryUUID: "A"
        )
        tracker.screenParametersChangedForTesting()

        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.displayUUID, "C")
        XCTAssertEqual(tracker.snapshot.windows[WindowID(rawValue: "cgw-\(cgWindow)")]?.displayUUID, "C")
    }

    func testNewSeatTakesItsDisplayFromTheAXFrame() {
        let tracker = makeTracker()
        tracker.installFixtureForTesting(AppEntry(
            pid: pid,
            bundleIdentifier: "com.example.fixture",
            appName: "Fixture",
            activationPolicy: .regular,
            executablePath: "/Applications/Fixture.app",
            windowsByID: [:],
            windowOrder: [],
            isHidden: false
        ))
        let changed = tracker.reconcileFixtureForTesting(
            pid: pid, cgSnapshot: cgSnapshot(), now: Date(),
            eligible: [makeSnapshot(bounds: frameOnB, isMinimized: false)],
            readOutcome: .success(count: 1)
        )
        XCTAssertTrue(changed)
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.displayUUID, "B")
    }

    /// Optimistic update for dragging a window across screens: the key changes and publishes on the spot; during the freeze period, stale positions read via AX / CG do not pull it back; rollback does not freeze.
    func testNoteWindowMovedPublishesAndHoldsAgainstStaleReads() {
        let tracker = makeTracker()
        tracker.installFixtureForTesting(makeApp(displayUUID: "A"))
        tracker.rebuildSnapshotForTesting()

        XCTAssertTrue(tracker.noteWindowMoved(pid: pid, cgWindowID: cgWindow, displayUUID: "B"))
        XCTAssertEqual(tracker.snapshot.windows[WindowID(rawValue: "cgw-\(cgWindow)")]?.displayUUID, "B")

        // During the freeze period: the frame read via AX is still in A -> no movement; the CG traversal likewise does not move.
        let changed = tracker.reconcileFixtureForTesting(
            pid: pid, cgSnapshot: cgSnapshot(), now: Date(),
            eligible: [makeSnapshot(bounds: frameOnA, isMinimized: false)],
            readOutcome: .success(count: 1)
        )
        XCTAssertFalse(changed)
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.displayUUID, "B")
        XCTAssertFalse(tracker.refreshDisplayAttributionFromCGForTesting(cgSnapshot: cgSnapshot(bounds: [cgWindow: frameOnA])))

        // After the freeze period (the read's now is past the hold): the ground truth corrects back to A.
        let later = Date().addingTimeInterval(AppTracker.displayMoveHold + 1)
        let corrected = tracker.reconcileFixtureForTesting(
            pid: pid, cgSnapshot: cgSnapshot(), now: later,
            eligible: [makeSnapshot(bounds: frameOnA, isMinimized: false)],
            readOutcome: .success(count: 1)
        )
        XCTAssertTrue(corrected)
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.displayUUID, "A")

        // Rollback (hold: .none) takes effect immediately and does not freeze.
        XCTAssertTrue(tracker.noteWindowMoved(pid: pid, cgWindowID: cgWindow, displayUUID: "B"))
        XCTAssertTrue(tracker.noteWindowMoved(pid: pid, cgWindowID: cgWindow, displayUUID: "A", hold: .none))
        XCTAssertFalse(tracker.refreshDisplayAttributionFromCGForTesting(cgSnapshot: cgSnapshot(bounds: [cgWindow: frameOnB])))
        XCTAssertTrue(tracker.refreshDisplayAttributionFromCGForTesting(cgSnapshot: cgSnapshot(bounds: [cgWindow: frameOnB])))
        XCTAssertFalse(tracker.noteWindowMoved(pid: pid, cgWindowID: 999, displayUUID: "B"), "不在册的座位不认")
    }

    /// An off-screen / ghost window whose AX handle cannot be obtained: dragging it to another strip = changing its address, and the key is pinned until it is next visible in AX;
    /// the old coordinates in CG and screen-parameter recomputation do not count; only when AX really reads a visible frame does it follow the frame and release.
    func testUntilVisibleHoldSurvivesCGAndStaleReadsUntilAXShowsTheWindow() {
        let tracker = makeTracker()
        tracker.installFixtureForTesting(makeApp(displayUUID: "A"))
        XCTAssertTrue(tracker.noteWindowMoved(pid: pid, cgWindowID: cgWindow, displayUUID: "B", hold: .untilVisible))

        XCTAssertFalse(tracker.refreshDisplayAttributionFromCGForTesting(cgSnapshot: cgSnapshot(bounds: [cgWindow: frameOnA])))
        tracker.screenParametersChangedForTesting()
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.displayUUID, "B")

        // Long afterward AX still has not read it as visible (minimized state) -> still pinned (a change of the minimized flag itself counts as a change, independent of the key).
        let later = Date().addingTimeInterval(3600)
        _ = tracker.reconcileFixtureForTesting(
            pid: pid, cgSnapshot: cgSnapshot(), now: later,
            eligible: [makeSnapshot(bounds: frameOnA, isMinimized: true)],
            readOutcome: .success(count: 1)
        )
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.displayUUID, "B")

        // AX reads a visible frame in A -> follow the frame, release the pin.
        XCTAssertTrue(tracker.reconcileFixtureForTesting(
            pid: pid, cgSnapshot: cgSnapshot(), now: later,
            eligible: [makeSnapshot(bounds: frameOnA, isMinimized: false)],
            readOutcome: .success(count: 1)
        ))
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.displayUUID, "A")
        XCTAssertNil(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.displayUUIDHoldUntil)
    }

    /// During the freeze period of a cross-screen window move, the seat follows the moved window and is not "torn" away by another window on the old frame; otherwise the old seat inherits the just-written B key,
    /// the moved window builds a new seat -> both cards are in B, and once the freeze ends the old one jumps back to A (owner 2026-09-03, multi-tab Finder).
    func testMoveHoldKeepsTheSeatOnTheMovedWindowInsteadOfTearingItOut() {
        let tracker = makeTracker()
        // The fixture seat uses s9: the sequence counter for newly created seats starts from s1, otherwise it collides with the fixture token and the assertion cannot tell which is which.
        tracker.installFixtureForTesting(makeApp(displayUUID: "A", token: "tabgrp-\(pid)-s9"))
        XCTAssertTrue(tracker.noteWindowMoved(pid: pid, cgWindowID: cgWindow, displayUUID: "B"))
        let other: CGWindowID = 92
        let cg = AppTrackerCGWindowSnapshot(
            allWindowIDs: [cgWindow, other], onScreenWindowIDs: [cgWindow, other],
            windowIDsByPID: [pid: [cgWindow, other]], alphaByWindowID: [:], boundsByWindowID: [:]
        )
        _ = tracker.reconcileFixtureForTesting(
            pid: pid, cgSnapshot: cg, now: Date(),
            eligible: [makeSnapshot(bounds: frameOnB, isMinimized: false),
                       makeSnapshot(bounds: frameOnA, isMinimized: false, cgWindowID: other)],
            readOutcome: .success(count: 2)
        )
        let app = tracker.fixtureAppForTesting(pid: pid)
        XCTAssertEqual(app?.windowsByID[cgWindow]?.token, "tabgrp-\(pid)-s9", "座位跟着被搬的窗口")
        XCTAssertEqual(app?.windowsByID[cgWindow]?.displayUUID, "B")
        XCTAssertNotEqual(app?.windowsByID[other]?.token, "tabgrp-\(pid)-s9", "旧帧上的窗口自成座位")
        XCTAssertEqual(app?.windowsByID[other]?.displayUUID, "A")
    }

    /// Verdict after an AX frame write fails: window on screen -> roll back; not on screen -> pin to the target screen; seat not registered -> do nothing.
    func testFailedMoveRollsBackOnScreenWindowsAndPinsOffScreenOnes() {
        let tracker = makeTracker()
        tracker.installFixtureForTesting(makeApp(displayUUID: "A"))

        tracker.rebuildSnapshotForTesting(onScreenCGIDs: [cgWindow])
        XCTAssertTrue(tracker.noteWindowMoved(pid: pid, cgWindowID: cgWindow, displayUUID: "B"))
        XCTAssertEqual(tracker.resolveFailedWindowMove(pid: pid, cgWindowID: cgWindow, target: "B", previous: "A"), .rolledBack)
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.displayUUID, "A")
        XCTAssertNil(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.displayUUIDHoldUntil)

        tracker.rebuildSnapshotForTesting(onScreenCGIDs: [])
        XCTAssertTrue(tracker.noteWindowMoved(pid: pid, cgWindowID: cgWindow, displayUUID: "B"))
        XCTAssertEqual(tracker.resolveFailedWindowMove(pid: pid, cgWindowID: cgWindow, target: "B", previous: "A"), .pinnedToTarget)
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.displayUUID, "B")
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.displayUUIDHoldUntil, .distantFuture)

        XCTAssertEqual(tracker.resolveFailedWindowMove(pid: pid, cgWindowID: 999, target: "B", previous: "A"), .seatGone)
    }

    /// The fallback card for "running but no window" lands on the screen where the window last was; dragging it to another strip (`noteNoWindowHome`) changes that.
    func testFallbackCardRemembersLastWindowDisplayAndAcceptsANewHome() {
        let tracker = makeTracker()
        tracker.installFixtureForTesting(makeApp(bounds: frameOnB, displayUUID: "B"))
        tracker.rebuildSnapshotForTesting()

        // Window closed (gone from AX and from CG too) -> seat released -> the fallback card carries "last in B".
        let empty = AppTrackerCGWindowSnapshot(allWindowIDs: [], onScreenWindowIDs: [], windowIDsByPID: [:], alphaByWindowID: [:])
        XCTAssertTrue(tracker.reconcileFixtureForTesting(
            pid: pid, cgSnapshot: empty, now: Date(), eligible: [], readOutcome: .success(count: 0)
        ))
        tracker.rebuildSnapshotForTesting()
        let fallbackID = WindowID(rawValue: "app-com.example.fixture")
        XCTAssertEqual(tracker.snapshot.windows[fallbackID]?.displayUUID, "B")

        tracker.noteNoWindowHome(bundleID: "com.example.fixture", displayUUID: "A")
        XCTAssertEqual(tracker.snapshot.windows[fallbackID]?.displayUUID, "A")
        tracker.noteNoWindowHome(bundleID: "com.other", displayUUID: "B")
        XCTAssertEqual(tracker.snapshot.windows[fallbackID]?.displayUUID, "A", "别的 bundle 不受影响")
    }

    // MARK: - Fixtures

    private final class TableBox {
        var table: WindowDisplayAttribution.Table
        init(_ table: WindowDisplayAttribution.Table) { self.table = table }
    }

    private func makeTracker(
        tableProvider: (@MainActor () -> WindowDisplayAttribution.Table)? = nil
    ) -> AppTracker {
        let table = tableAB
        return AppTracker(
            reader: DisplayAttributionNoopReader(),
            processProvider: DisplayAttributionFixedProcessProvider(),
            eventAXAsyncEnabled: true,
            displayTableProvider: tableProvider ?? { table }
        )
    }

    private func cgSnapshot(bounds: [CGWindowID: CGRect] = [:]) -> AppTrackerCGWindowSnapshot {
        AppTrackerCGWindowSnapshot(
            allWindowIDs: [cgWindow],
            onScreenWindowIDs: [cgWindow],
            windowIDsByPID: [pid: [cgWindow]],
            alphaByWindowID: [:],
            boundsByWindowID: bounds
        )
    }

    private func makeApp(
        bounds: CGRect? = nil,
        displayUUID: String?,
        isMinimized: Bool = false,
        isHidden: Bool = false,
        token: String? = nil
    ) -> AppEntry {
        let seat = WindowEntry(
            cgWindowID: cgWindow,
            token: token ?? "tabgrp-\(pid)-s1",
            title: "Window",
            bounds: bounds ?? frameOnA,
            isMinimized: isMinimized,
            isFocused: false,
            everSeenVisible: true,
            displayUUID: displayUUID
        )
        return AppEntry(
            pid: pid,
            bundleIdentifier: "com.example.fixture",
            appName: "Fixture",
            activationPolicy: .regular,
            executablePath: "/Applications/Fixture.app",
            windowsByID: [cgWindow: seat],
            windowOrder: [cgWindow],
            isHidden: isHidden
        )
    }

    private func makeSnapshot(bounds: CGRect, isMinimized: Bool, cgWindowID: CGWindowID? = nil) -> AXWindowSnapshot {
        AXWindowSnapshot(
            pid: pid,
            cgWindowID: cgWindowID ?? cgWindow,
            titleRead: .value("Window"),
            bounds: bounds,
            role: kAXWindowRole as String,
            subrole: kAXStandardWindowSubrole as String,
            isMinimized: isMinimized,
            isFocusedWindow: false,
            element: AXUIElementCreateApplication(pid)
        )
    }
}

private struct DisplayAttributionNoopReader: AppTrackerWindowReading {
    func windows(forPID pid: pid_t) -> [AXWindowSnapshot] { [] }
    func windowReadResult(forPID pid: pid_t) -> AXWindowReadResult { .success([]) }
    func inventoryWindows(forPID pid: pid_t, messagingTimeout: TimeInterval) -> AXWindowReadResult { .success([]) }
}

private struct DisplayAttributionFixedProcessProvider: AppTrackerProcessProviding {
    func isAlive(pid: pid_t) -> Bool { true }

    func identity(pid: pid_t, bundleID: String?) -> ScanAdmissionDecision.ProcessIdentity {
        ScanAdmissionDecision.ProcessIdentity(pid: pid, startTimeSec: 1, startTimeUsec: 2, bundleID: bundleID)
    }
}
