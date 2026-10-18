import ApplicationServices
import CoreGraphics
import XCTest

/// Locks the gate order of `NonRegularEvictionDecision` and the tracker wiring that drops a
/// zero-seat entry once its process is no longer `.regular` (the Ice settings-window case).
@MainActor
final class NonRegularEvictionDecisionTests: XCTestCase {
    private let pid: pid_t = 5151
    private let cgWindowID: CGWindowID = 99

    func testEvictsOnlyWhenTrackedSeatlessSameGenerationAndKnownNonRegular() {
        XCTAssertEqual(verdict(), .evict)
        XCTAssertEqual(verdict(isTracked: false), .keepUntracked)
        XCTAssertEqual(verdict(isFinder: true), .keepFinder)
        XCTAssertEqual(verdict(hasSeats: true), .keepHasSeats)
        XCTAssertEqual(verdict(identityMatches: false), .keepIdentityChanged)
        XCTAssertEqual(verdict(isRegular: nil), .keepPolicyUnknown)
        XCTAssertEqual(verdict(isRegular: true), .keepRegular)
    }

    func testSeatsOutrankPolicyAndFinderOutranksSeats() {
        // A process that left .regular but still owns a real window keeps its seat.
        XCTAssertEqual(verdict(hasSeats: true, isRegular: false), .keepHasSeats)
        // Finder's persistent entry is never evicted, seats or not.
        XCTAssertEqual(verdict(isFinder: true, hasSeats: true, isRegular: false), .keepFinder)
    }

    func testTrackerDropsZeroSeatEntryWhenProcessLeftRegular() {
        let provider = EvictionProcessProvider(isRegular: false)
        let tracker = AppTracker(
            reader: EvictionNoopReader(),
            processProvider: provider,
            cgSnapshotProvider: { .init(allWindowIDs: [], onScreenWindowIDs: [], windowIDsByPID: [:], alphaByWindowID: [:]) }
        )
        tracker.installFixtureForTesting(makeApp(pid: pid, cgWindowID: cgWindowID))

        // Still regular while the window is open → the entry stays.
        provider.isRegular = true
        XCTAssertEqual(tracker.evictIfNonRegularForTesting(pid: pid), .keepHasSeats)

        // The window truly closes (gone from AX and CG) → zero seats, still tracked.
        let emptyCG = AppTrackerCGWindowSnapshot(allWindowIDs: [], onScreenWindowIDs: [], windowIDsByPID: [:], alphaByWindowID: [:])
        tracker.reconcileFixtureForTesting(pid: pid, cgSnapshot: emptyCG, now: Date(), eligible: [], readOutcome: .success(count: 0))
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowOrder, [])
        XCTAssertEqual(tracker.evictIfNonRegularForTesting(pid: pid), .keepRegular)
        XCTAssertNotNil(tracker.fixtureAppForTesting(pid: pid))

        // The process flips back to .accessory → the seatless entry (and its app-* chip) goes.
        provider.isRegular = false
        XCTAssertEqual(tracker.evictIfNonRegularForTesting(pid: pid), .evict)
        XCTAssertNil(tracker.fixtureAppForTesting(pid: pid))
        XCTAssertFalse(tracker.snapshot.orderedWindowIDs.contains { $0.rawValue.hasPrefix("app-") })
        XCTAssertEqual(tracker.evictIfNonRegularForTesting(pid: pid), .keepUntracked)
    }

    func testSweepSkipsUnknownPolicyAndFinder() {
        let provider = EvictionProcessProvider(isRegular: nil)
        let tracker = AppTracker(
            reader: EvictionNoopReader(),
            processProvider: provider,
            cgSnapshotProvider: { .init(allWindowIDs: [], onScreenWindowIDs: [], windowIDsByPID: [:], alphaByWindowID: [:]) }
        )
        var seatless = makeApp(pid: pid, cgWindowID: cgWindowID)
        seatless.windowsByID = [:]
        seatless.windowOrder = []
        tracker.installFixtureForTesting(seatless)
        var finder = makeApp(pid: 6161, cgWindowID: 100, bundleID: "com.apple.finder")
        finder.windowsByID = [:]
        finder.windowOrder = []
        tracker.installFixtureForTesting(finder)

        tracker.sweepNonRegularZeroSeatEntriesForTesting()
        XCTAssertNotNil(tracker.fixtureAppForTesting(pid: pid), "unknown policy is not evidence")
        XCTAssertNotNil(tracker.fixtureAppForTesting(pid: 6161))

        provider.isRegular = false
        tracker.sweepNonRegularZeroSeatEntriesForTesting()
        XCTAssertNil(tracker.fixtureAppForTesting(pid: pid))
        XCTAssertNotNil(tracker.fixtureAppForTesting(pid: 6161), "Finder's persistent entry survives the sweep")
    }

    private func verdict(
        isTracked: Bool = true,
        isFinder: Bool = false,
        hasSeats: Bool = false,
        identityMatches: Bool = true,
        isRegular: Bool? = false
    ) -> NonRegularEvictionDecision.Verdict {
        NonRegularEvictionDecision.verdict(
            isTracked: isTracked,
            isFinder: isFinder,
            hasSeats: hasSeats,
            identityMatches: identityMatches,
            isRegular: isRegular
        )
    }

    private func makeApp(pid: pid_t, cgWindowID: CGWindowID, bundleID: String? = nil) -> AppEntry {
        let seat = WindowEntry(
            cgWindowID: cgWindowID,
            token: "tabgrp-\(pid)-s1",
            title: "Settings",
            bounds: CGRect(x: 10, y: 20, width: 500, height: 400),
            isMinimized: false,
            isFocused: true,
            everSeenVisible: true
        )
        return AppEntry(
            pid: pid,
            bundleIdentifier: bundleID ?? "com.example.menubar\(pid)",
            appName: "MenuBar\(pid)",
            activationPolicy: .regular,
            executablePath: "/Applications/MenuBar.app",
            windowsByID: [cgWindowID: seat],
            windowOrder: [cgWindowID],
            isHidden: false
        )
    }
}

private final class EvictionProcessProvider: AppTrackerProcessProviding, @unchecked Sendable {
    var isRegular: Bool?

    init(isRegular: Bool?) {
        self.isRegular = isRegular
    }

    func isAlive(pid: pid_t) -> Bool { true }

    func identity(pid: pid_t, bundleID: String?) -> ScanAdmissionDecision.ProcessIdentity {
        ScanAdmissionDecision.ProcessIdentity(pid: pid, startTimeSec: 1, startTimeUsec: 2, bundleID: bundleID)
    }

    func isRegularApplication(pid: pid_t) -> Bool? { isRegular }
}

private struct EvictionNoopReader: AppTrackerWindowReading {
    func windows(forPID pid: pid_t) -> [AXWindowSnapshot] { [] }
    func windowReadResult(forPID pid: pid_t) -> AXWindowReadResult { .success([]) }
    func inventoryWindows(forPID pid: pid_t, messagingTimeout: TimeInterval) -> AXWindowReadResult { .success([]) }
}
