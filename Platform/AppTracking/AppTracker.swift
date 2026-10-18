import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import os

struct AppEntry {
    let pid: pid_t
    let bundleIdentifier: String?
    let appName: String
    let activationPolicy: NSApplication.ActivationPolicy
    let executablePath: String?
    var windowsByID: [CGWindowID: WindowEntry]
    var windowOrder: [CGWindowID]
    var isHidden: Bool
    /// Shadow tab pool: on the previous reconcile round, ids of windows that were "in the full CG list (this pid, layer 0) but not in AXWindows" --
    /// the signature of order-out background tabs. (Not unique: a window on another Space also leaves AXWindows while
    /// staying in CG — seated ids are kept out of the pool for that reason.)
    /// Pass B's second-level fold check uses this to cover the gap where "member history was wiped by a dock restart"; rebuilt from live signals every round,
    /// not persisted. The check uses the previous round's pool (at the instant of a minimize burst all tabs flood into AX, so a pool computed this round would be empty).
    var shadowTabCgIDs: Set<CGWindowID> = []
    /// The display (display UUID) where this app's windows last were. After all windows close, the fallback card for "running but no windows" lands here
    ///(multi-display item 4: an icon with a dot appears on only one strip, owner 2026-09-02); dragging that card onto another display's strip also writes here
    ///(`noteNoWindowHome`). Session-only memory, not persisted; nil -> the projection layer falls back to the main display.
    var lastWindowDisplayUUID: String? = nil
}

/// One **physical window seat** (single-seat model). `cgWindowID` is its **current** visible tab (= the action target) and changes as
/// tabs switch; `token` is the seat's stable identity, **never changes** once assigned (even if activeCgID is replaced) -- this is the root of
/// cards not jumping or splitting on tab switch / minimize. Background tabs do NOT occupy a seat of their own.
struct WindowEntry {
    var cgWindowID: CGWindowID   // cgID of the current visible tab (action target); replaced on tab switch
    let token: String            // stable physical-seat identity (tabgrp-<pid>-<seed cgID>), never changes
    var title: String
    var bounds: CGRect?
    var isMinimized: Bool
    var isFocused: Bool
    /// Start time of continuous AX absence in the min/hidden keep branch.
    /// Feeds only the phantom-seat self-heal decision (PhantomSeatDecision, five gates); naturally reset by make() when the window reappears in AX.
    var minAbsentSince: Date? = nil
    /// Diagnostics only: set/cleared together with `minAbsentSince`, identifying one continuous AX-absence episode.
    /// Not part of the seat signature, folding, or self-heal decisions.
    var absenceEpisodeID: UUID? = nil
    /// Whether this seat has ever appeared in AX with min=false (inherited when the seat continues). A real window has almost certainly been visible;
    /// a phantom seat (split off a min=true burst candidate when a fold failed) is always false -- the top gate of the self-heal decision,
    /// and it also protects Safari-style real windows that "leave AX entirely as soon as they are minimized" from being wrongly healed away.
    var everSeenVisible: Bool = false
    /// Tabs that have ever been this seat's activeCgID (recorded when displaced by a tab switch; also learned on a successful fold with a unique owner).
    /// A tab becomes the active tab at creation => every background tab is in its owning seat's history. Pass B folding decides by this membership first,
    /// independent of geometry and the min flag -- which exempts it from two fold failures: "background tab AX geometry is stale after the window moves/resizes" and "min lag
    /// race" (root fix for the split bug). To prevent wrongly folding on cgID reuse: cleared globally on a real destroy (tombstone),
    /// and intersected with the full CG list every reconcile round; tabs evicted by a tear-out are NOT recorded (it is now an independent window).
    var formerCgIDs: Set<CGWindowID> = []
    /// The display the window is on (display UUID, a coarse ownership key, `WindowDisplayAttribution`). **Updated only while the seat is visible**
    /// (AX reads min=false and the app is not hidden; the 5s tick's CG bounds walk; recomputed from stored frames when display parameters change),
    /// frozen on the last visible display during minimize / Cmd-H (multi-display item 4, "a minimized card stays on its original display"). Part of `seatSignature`;
    /// **the coordinates themselves never enter the fingerprint** -- otherwise every pixel of movement would rebuild the whole strip.
    var displayUUID: String? = nil
    /// **Freezes** the ownership key after an optimistic update for a cross-display window drag: the AX frame write is still in flight on the action queue, and reads landing meanwhile (foreground
    /// polling / the tick's CG walk) still see the old position; without freezing, the card would bounce back to the source display and jump again.
    /// `.distantFuture` = pinned until the next time it is visible in AX (off-screen / phantom windows whose AX handle can't be obtained and can't be moved:
    /// dragging to another strip counts as "changing address", and the stale coordinates in CG don't count).
    var displayUUIDHoldUntil: Date? = nil
    /// Absence fallback for a window hidden without a destroy notification (`AbsentSeatReleaseDecision`).
    var absentProbe: AbsentSeatProbeState? = nil
}

protocol AppTrackerProcessProviding: Sendable {
    func isAlive(pid: pid_t) -> Bool
    func identity(pid: pid_t, bundleID: String?) -> ScanAdmissionDecision.ProcessIdentity
    /// Whether the process currently runs with the `.regular` activation policy; `nil` when
    /// LaunchServices cannot resolve the pid. Policy only — never liveness (see `isAlive`).
    func isRegularApplication(pid: pid_t) -> Bool?
}

extension AppTrackerProcessProviding {
    /// Unknown is the safe answer: `NonRegularEvictionDecision` treats it as "keep".
    func isRegularApplication(pid: pid_t) -> Bool? { nil }
}

struct LiveAppTrackerProcessProvider: AppTrackerProcessProviding {
    func isAlive(pid: pid_t) -> Bool {
        ProcessLiveness.isAlive(pid: pid)
    }

    func isRegularApplication(pid: pid_t) -> Bool? {
        // One LaunchServices round trip; reached only for a seatless tracked process after a
        // seat release or on the 60s slow scan, never per tick for every app.
        NSRunningApplication(processIdentifier: pid).map { $0.activationPolicy == .regular }
    }

    func identity(pid: pid_t, bundleID: String?) -> ScanAdmissionDecision.ProcessIdentity {
        let start = ProcessLiveness.startTime(pid: pid)
        return ScanAdmissionDecision.ProcessIdentity(
            pid: pid,
            startTimeSec: start.map { Int64($0.tv_sec) },
            startTimeUsec: start.map { $0.tv_usec },
            bundleID: bundleID
        )
    }
}

@MainActor
final class AppTracker: ObservableObject {
    @Published private(set) var snapshot: DockSnapshot = .empty

    private var apps: [pid_t: AppEntry] = [:]
    private var appOrder: [pid_t] = []
    private var observers: [pid_t: AppWindowObserver] = [:]
    private var workspaceObservers: [NSObjectProtocol] = []
    private var reconcileTimer: Timer?
    private var frontmostPollTimer: Timer?
    private var isScanningCandidates = false
    /// Per-pid retry task asking whether a freshly seatless process is still `.regular`
    /// (`scheduleNonRegularEviction`). Ice flips back to `.accessory` right after its settings
    /// window closes, sometimes after our destroy handler has already landed, hence the retries.
    private var nonRegularEvictionTasks: [pid_t: Task<Void, Never>] = [:]
    private static let nonRegularEvictionDelays: [TimeInterval] = [0.2, 0.5, 1.0, 2.0, 5.0]
    /// Side-channel cache of AX elements for the action path. Written here (the inventory read already holds the element), read in
    /// `PlatformActionExecutor`. Deliberately kept out of `DockSnapshot`; see `AXElementCache` for the reason.
    private let elementCache = AXElementCache.shared
    private var destroyedCGIDs: [CGWindowID: Date] = [:]
    private static let tombstoneTTL: TimeInterval = 3.0
    /// Phantom-seat self-heal threshold: how long a min-kept seat must be continuously absent from AX before it may enter the PhantomSeatDecision check
    /// (it must also pass four gates: everSeenVisible / present in CG / AX reads healthy / has an AX-present sibling seat).
    private static let phantomReapGrace: TimeInterval = 10.0
    /// Due subscription retries collected during the current main-thread turn; at most one runs.
    private var retryCandidates: [WindowSubscriptionRetryCandidate<AXElementKey>] = []
    private var retryFlushScheduled = false
    private var nextRetryFlushID: UInt64 = 0

    /// CG on-screen set at the last snapshot rebuild. Foreground polling uses it to detect a "tab switch" -- AX may not report it at all,
    /// but the on-screen set changes immediately, and a change triggers a rebuild (so the tab group's visible tab updates instantly).
    private var lastOnScreenCGIDs: Set<CGWindowID> = []

    /// Global auto-incrementing sequence for physical-seat tokens. Guarantees every new seat gets a unique token (never derived from a cgID, which can be reused).
    private var nextSeatSerial: Int = 0

    private struct ShadowPoolDiagnosticState {
        var initialized = false
        var updateWasSkipped = false
        var lastSuccessfulRoundID: UInt64?
    }

    private var nextInventoryRoundID: UInt64 = 0
    private var reconcileOrdinalsByPID: [pid_t: UInt64] = [:]
    private var lastReconcileAtByPID: [pid_t: Date] = [:]
    private var shadowPoolDiagnosticsByPID: [pid_t: ShadowPoolDiagnosticState] = [:]
    private var heldLogDeduplicator = InventoryPhantomHeldDeduplicator()

    private struct PendingEventRead {
        let token: UInt64
        let mutationGeneration: UInt64
        let identity: ScanAdmissionDecision.ProcessIdentity
        let source: InventoryReconcileSource
        var absenceProbes: [AbsentSeatProbeRequest] = []
    }

    private var nextEventReadToken: UInt64 = 0
    private var pendingEventReads: [pid_t: PendingEventRead] = [:]
    private var trailingEventSources: [pid_t: InventoryReconcileSource] = [:]
    private var mutationGenerations: [pid_t: UInt64] = [:]

    private let reader: any AppTrackerWindowReading
    private let processProvider: any AppTrackerProcessProviding
    private let cgSnapshotProvider: @Sendable () -> AppTrackerCGWindowSnapshot
    private let onScreenWindowIDsProvider: @Sendable () -> Set<CGWindowID>
    private let eventAXAsyncEnabled: Bool
    /// AX read timeout for the periodic reconcile (5s tick). Default 100ms, time-limited background batch read; nil (DOCK_RECONCILE_AX_TIMEOUT_MS=0)
    /// falls back to the old path: main-thread, per-pid, unlimited synchronous reads. The synchronous compat path with DOCK_EVENT_AX_ASYNC=0 also takes the old path.
    private let periodicReconcileTimeout: TimeInterval?
    /// Skip-read gate for periodic reconcile (DOCK_RECONCILE_SKIP=0 disables). Affects only the batch-read path; the old synchronous path is unaffected.
    private let reconcileSkipEnabled: Bool
    private let uptimeProvider: () -> TimeInterval
    /// Table of currently present displays (the one in `DisplayTopologyStore`); the cache is refreshed when display parameters change; tests inject a fixed table.
    private let displayTableProvider: @MainActor () -> WindowDisplayAttribution.Table
    private var displayTable: WindowDisplayAttribution.Table
    private var screenParametersObserver: NSObjectProtocol?

    /// Per-pid state for the skip-read gate. Refreshed at the end of reconcileSeats by a successful full read from **any source**
    ///(the foreground pid is naturally always fresh thanks to the 2Hz foreground polling, so the periodic tick can skip it); AX/workspace events mark it dirty.
    private struct ReconcileGateState {
        var lastCGIDs: Set<CGWindowID>
        var lastFullReadUptime: TimeInterval
        var dirty: Bool
        var lastReadWasUnread: Bool
        var lastRoundChanged: Bool
        /// Seated cgIDs that were on-screen at the last full read: a seat going off-screen with no
        /// AX event (a window hidden without notifications) must still get a prompt read.
        var lastSeatOnScreenIDs: Set<CGWindowID>
    }

    private var gateStates: [pid_t: ReconcileGateState] = [:]

    /// Event cache for the frontmost app. Every read of `NSWorkspace.frontmostApplication` is a synchronous LS XPC round trip
    ///(before this change: foreground polling at 2Hz plus one more per rebuildSnapshot -- the main remaining source of
    /// LS overhead in the 2026-08-22 true-idle attribution). Maintained by the didActivate notification (applies to **all** activations, not just regular; the cache must reflect
    /// the real frontmost app); the 5s reconcile self-heals with one real query, so the worst-case drift from a missed notification is <=5s, and the correctness of the activation highlight
    /// depends only on the value taken at rebuildSnapshot time, which the next activation / self-heal will always correct afterwards.
    /// DOCK_FRONTMOST_CACHE=0 falls back to a real query every time.
    private let frontmostCacheEnabled: Bool
    private var cachedFrontmostPID: pid_t?

    /// CG full-list reuse gate for the event read path (DOCK_CG_SNAPSHOT_REUSE=0 disables). See `CGSnapshotReuseDecision` for the decision and the hard ordering rules;
    /// the cache is refreshed only by **fresh captures** on the event read path (a reuse round does not refresh the age, otherwise the
    /// age cap would be defeated); the 5s reconcile batch path neither reads nor writes it.
    private let cgSnapshotReuseEnabled: Bool
    /// Global event generation: any AX/workspace event (markReconcileGateDirty, app add/remove) increments it.
    /// The cache records the generation at capture time; if the generation has changed -> the next event read takes a fresh capture. Global rather than per-pid is deliberately conservative.
    private var cgEventGeneration: UInt64 = 0
    private var cachedCGSnapshot: AppTrackerCGWindowSnapshot?
    private var cachedCGProbeIDs: Set<CGWindowID>?
    private var cachedCGAtUptime: TimeInterval = -.infinity
    private var cachedCGGeneration: UInt64 = 0

    /// State for the supplementary-scan probe gate (DOCK_SCAN_GATE=0 disables). The memo records only the conclusion "no qualifying window";
    /// dirty is set by the workspace launch notification; a slow full scan every 60s covers gate holes.
    private let scanGateEnabled: Bool
    private var scanMemos: [pid_t: ScanProbeGateDecision.Memo] = [:]
    private var scanDirtyPIDs: Set<pid_t> = []
    private var lastFullScanUptime: TimeInterval?
    /// Cache of supplementary-scan candidates (pid + bundleID). Property access on `NSWorkspace.runningApplications`
    ///(processIdentifier / bundleIdentifier / isTerminated...) is **one synchronous
    /// LaunchServices XPC per app** -- in the 2026-08-22 true-idle attribution it was the bulk of the supplementary-scan cost (118/142 samples),
    /// and the more apps, the pricier. The list is rebuilt only when membership may have changed (launch/quit/adoption mark it dirty + 60s slow-scan backstop),
    /// so a quiet tick never touches NSWorkspace; candidate liveness uses ProcessLiveness, and identity is backstopped by a generation re-check at probe time.
    private var scanCandidateCache: [(pid: pid_t, bundleID: String?)]?
    #if DEBUG
    /// Test only: fixture pids can't create a real AXObserver, so the skip-read gate's observerActive criterion is overridden with this.
    private var observerActiveOverridesForTesting: [pid_t: Bool] = [:]
    #endif
    /// `DOCK_ABSENT_SEAT_RELEASE`; only effective on the timed background read path.
    private let absentSeatReleaseEnabled: Bool
    private let absentSeatProber: any AbsentSeatProbing
    /// One coalesced timer per pid for an absence probe due within the next 5s tick.
    private var absenceProbeTimers: [pid_t: DispatchWorkItem] = [:]
    #if DEBUG
    private var subscribedElementOverridesForTesting: [pid_t: [CGWindowID: (element: AXUIElement, instanceID: UInt64)]] = [:]
    #endif
    private let windowEligibility = AppTrackerWindowEligibility()
    private let logger = Logger(subsystem: "app.neobar.NeoBar", category: "app-tracker")
    private let inventoryLog: WindowInventoryAnomalyLog

    init(
        inventoryLog: WindowInventoryAnomalyLog = WindowInventoryAnomalyLog(),
        reader: any AppTrackerWindowReading = AXWindowReader(),
        processProvider: any AppTrackerProcessProviding = LiveAppTrackerProcessProvider(),
        cgSnapshotProvider: @escaping @Sendable () -> AppTrackerCGWindowSnapshot = {
            AppTrackerCGWindowSnapshot.capture()
        },
        onScreenWindowIDsProvider: @escaping @Sendable () -> Set<CGWindowID> = {
            AppTrackerCGWindowSnapshot.captureOnScreenWindowIDs()
        },
        eventAXAsyncEnabled: Bool = DebugSwitch.eventAxAsync.isEnabled(in: ProcessInfo.processInfo.environment),
        periodicAXTimeoutMS: Int = Int(DebugSwitch.reconcileAxTimeoutMs.value(in: ProcessInfo.processInfo.environment) ?? "") ?? 100,
        reconcileSkipEnabled: Bool = DebugSwitch.reconcileSkip.isEnabled(in: ProcessInfo.processInfo.environment),
        scanGateEnabled: Bool = DebugSwitch.scanGate.isEnabled(in: ProcessInfo.processInfo.environment),
        frontmostCacheEnabled: Bool = DebugSwitch.frontmostCache.isEnabled(in: ProcessInfo.processInfo.environment),
        cgSnapshotReuseEnabled: Bool = DebugSwitch.cgSnapshotReuse.isEnabled(in: ProcessInfo.processInfo.environment),
        absentSeatReleaseEnabled: Bool = DebugSwitch.absentSeatRelease.isEnabled(in: ProcessInfo.processInfo.environment),
        absentSeatProber: any AbsentSeatProbing = LiveAbsentSeatProber(),
        uptimeProvider: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        displayTableProvider: @escaping @MainActor () -> WindowDisplayAttribution.Table = { .empty }
    ) {
        self.inventoryLog = inventoryLog
        self.displayTableProvider = displayTableProvider
        self.displayTable = displayTableProvider()
        self.reader = reader
        self.processProvider = processProvider
        self.cgSnapshotProvider = cgSnapshotProvider
        self.onScreenWindowIDsProvider = onScreenWindowIDsProvider
        self.eventAXAsyncEnabled = eventAXAsyncEnabled
        self.periodicReconcileTimeout = periodicAXTimeoutMS > 0 ? TimeInterval(periodicAXTimeoutMS) / 1000.0 : nil
        self.reconcileSkipEnabled = reconcileSkipEnabled
        self.scanGateEnabled = scanGateEnabled
        self.frontmostCacheEnabled = frontmostCacheEnabled
        self.cgSnapshotReuseEnabled = cgSnapshotReuseEnabled
        self.absentSeatReleaseEnabled = absentSeatReleaseEnabled && eventAXAsyncEnabled
        self.absentSeatProber = absentSeatProber
        self.uptimeProvider = uptimeProvider
    }

    func start() {
        guard workspaceObservers.isEmpty else { return }
        let info = Bundle.main.infoDictionary
        inventoryLog.record(.sessionStart(InventorySessionStartPayload(
            version: info?["CFBundleShortVersionString"] as? String,
            build: info?["CFBundleVersion"] as? String,
            processID: ProcessInfo.processInfo.processIdentifier,
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString
        )))
        // Subscribe to notifications first, then seed: launch/quit events during seeding are no longer missed (addApp has an apps[pid] == nil guard, so repeated admission is safe).
        subscribeWorkspaceNotifications()
        // Screen parameters changed: skip one turn before refreshing so `TaskbarScreenOrchestrator`
        // has pushed the shared topology snapshot into the common table first.
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleScreenParametersChanged() }
        }
        displayTable = displayTableProvider()
        seedRunningApps()
        startReconcileTimer()
        startFrontmostPollTimer()
        // Four supplementary scans after seeding: hung apps are skipped in the time-limited seed read; the scans pick them up gradually via the time-limited inventoryWindows read.
        for delay in [0.5, 1.0, 2.0, 4.0] {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                self?.scanNonAdmittedApps()
            }
        }
    }

    func stop() {
        reconcileTimer?.invalidate()
        reconcileTimer = nil
        frontmostPollTimer?.invalidate()
        frontmostPollTimer = nil
        if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
            self.screenParametersObserver = nil
        }
        for obs in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
        workspaceObservers.removeAll()
        for obs in observers.values { obs.stop() }
        observers.removeAll()
        apps.removeAll()
        appOrder.removeAll()
        destroyedCGIDs.removeAll()
        reconcileOrdinalsByPID.removeAll()
        lastReconcileAtByPID.removeAll()
        shadowPoolDiagnosticsByPID.removeAll()
        heldLogDeduplicator.removeAll()
        pendingEventReads.removeAll()
        trailingEventSources.removeAll()
        mutationGenerations.removeAll()
        gateStates.removeAll()
        scanMemos.removeAll()
        scanDirtyPIDs.removeAll()
        lastFullScanUptime = nil
        scanCandidateCache = nil
        cachedFrontmostPID = nil
        snapshot = .empty
        inventoryLog.flush()
    }

    // MARK: - Tombstone

    private func isTombstoned(_ cgID: CGWindowID) -> Bool {
        guard let removedAt = destroyedCGIDs[cgID] else { return false }
        return Date().timeIntervalSince(removedAt) <= Self.tombstoneTTL
    }

    private func purgeStaleTombstones() {
        let now = Date()
        destroyedCGIDs = destroyedCGIDs.filter { _, date in
            now.timeIntervalSince(date) <= Self.tombstoneTTL
        }
    }

    /// cgIDs get reused by the system: when a window is truly destroyed, immediately purge that cgID from all seat histories (formerCgIDs) and the shadow tab pool,
    /// so that after it is reused for a new window it can't be wrongly absorbed by member/shadow-pool folding. Purged across pids (cgIDs are globally unique; reuse ignores processes).
    private func purgeFromSeatHistories(_ cgID: CGWindowID) {
        for pid in appOrder {
            guard var app = apps[pid] else { continue }
            var touched = false
            if app.shadowTabCgIDs.remove(cgID) != nil { touched = true }
            for wid in app.windowOrder where app.windowsByID[wid]?.formerCgIDs.contains(cgID) == true {
                app.windowsByID[wid]?.formerCgIDs.remove(cgID)
                touched = true
            }
            if touched { apps[pid] = app }
        }
    }

    /// "Same pid + pixel-identical frame" key. A physical seat uses this to claim the new current tab after a "tab switch displacement": all tabs of the same physical window
    /// have exactly the same frame, so the new current tab shows up at the seat's current frame.
    private func frameKey(_ pid: pid_t, _ bounds: CGRect?) -> String? {
        guard let b = bounds else { return nil }
        return "\(pid)|\(Int(b.origin.x.rounded())):\(Int(b.origin.y.rounded())):\(Int(b.size.width.rounded())):\(Int(b.size.height.rounded()))"
    }

    /// Physical-seat reconcile (single-seat model - tab tear-out root fix step 1). Converges an app's currently AX-eligible windows into
    /// "one physical window = one seat". Seats are anchored on frame; once assigned, the token doesn't change with the current tab's cgID:
    /// - **Tab switch**: the old activeCgID leaves AX and a new cgID takes its place at the same frame -> the seat swaps activeCgID in place, token unchanged (card doesn't jump).
    /// - **Dragging the current tab out**: the old activeCgID moves to a new frame and another tab takes its place at the old frame -> the seat stays on the old frame with the new tab,
    ///   and the old activeCgID is "evicted" into a new seat (tear-out splits the card).
    /// - **Minimized / background with no replacement**: if it's still in CG, keep the seat marked minimized; delete only once it's gone from CG (Safari minimize doesn't lose the card).
    /// - Background tabs do NOT keep a seat of their own. When several old seats share a frame (overlapping windows), don't displace; prefer creating a new one to avoid wrong merges.
    /// Returns true if the seat set or key properties changed (the caller uses this to decide whether to rebuild the snapshot).
    @discardableResult
    private func reconcileSeats(
        pid: pid_t,
        cgSnapshot: AppTrackerCGWindowSnapshot,
        now: Date,
        source: InventoryReconcileSource,
        preloadedEligible: [AXWindowSnapshot]? = nil,
        preloadedReadOutcome: InventoryAXReadOutcome? = nil,
        preloadedReadMode: InventoryReconcileReadMode? = nil,
        rawAXCgIDs: Set<CGWindowID>? = nil,
        absenceEvidence: [CGWindowID: AbsentSeatProbeEvidence] = [:]
    ) -> Bool {
        guard var app = apps[pid] else { return false }
        let cgIDs = cgSnapshot.allWindowIDs
        let onScreenCGIDs = cgSnapshot.onScreenWindowIDs
        let cgPidIDs = cgSnapshot.windowIDsByPID[pid] ?? []
        // The shadow tab pool is decided from the **previous** round's snapshot: at the instant of a minimize burst all tabs flood into AX, so a pool computed this round would be empty.
        let shadowPool = app.shadowTabCgIDs
        let eligible: [AXWindowSnapshot]
        let axReadOutcome: InventoryAXReadOutcome
        if let preloaded = preloadedEligible {
            eligible = preloaded
            axReadOutcome = preloadedReadOutcome ?? .success(count: preloaded.count)
        } else {
            switch reader.windowReadResult(forPID: pid) {
            case .success(let windows):
                axReadOutcome = .success(count: windows.count)
                eligible = windows.filter {
                    isEligible(
                        $0,
                        application: eligibilityApplication(for: app),
                        cgSnapshot: cgSnapshot
                    )
                }
            case .unread(let error):
                axReadOutcome = .unread(errorCode: error.rawValue)
                eligible = []
            }
        }
        if axReadOutcome.kind == .unread {
            // An unread AX round is unknown, never evidence of absence. In particular it must not
            // start grace periods, update the shadow-tab pool, or advance phantom healing.
            inventoryLog.record(.reconcileUnread(InventoryReconcileUnreadPayload(
                pid: pid,
                bundleID: app.bundleIdentifier,
                source: source,
                readMode: preloadedReadMode ?? .untimed,
                usedPreloadedAX: preloadedEligible != nil,
                errorCode: axReadOutcome.errorCode ?? AXError.failure.rawValue
            )))
            gateStates[pid]?.lastReadWasUnread = true
            return false
        }
        let reconcileContext = inventoryLog.isEnabled
            ? inventoryReconcileContext(
                pid: pid,
                source: source,
                now: now,
                usedPreloadedAX: preloadedEligible != nil,
                axReadOutcome: axReadOutcome
            )
            : nil
        func fk(_ b: CGRect?) -> String? { frameKey(pid, b) }

        var eligibleByCgID: [CGWindowID: AXWindowSnapshot] = [:]
        for s in eligible { if let c = s.cgWindowID { eligibleByCgID[c] = s } }

        // Also feed the AX element into the action path's side-channel cache (see the `AXElementCache` comment). This is the only write point:
        // this round has already passed the `.unread` early-exit gate, so the element was truly read. **Do not delete because a cgID didn't appear in AX this round**
        // -- Safari-style windows leave AXWindows entirely once minimized, which is exactly when the cache matters most. Eviction recognizes only
        // the full CG list (the retain on the line below), destroy notifications, and process disappearance.
        if AXElementCache.isEnabled {
            for (c, s) in eligibleByCgID { elementCache.store(pid: pid, cgWindowID: c, element: s.element) }
            elementCache.retain(pid: pid, liveCGWindowIDs: cgIDs)
        }

        let before = seatSignature(app)
        var usedEligible: Set<CGWindowID> = []
        var newOrder: [CGWindowID] = []
        var newByID: [CGWindowID: WindowEntry] = [:]
        func place(_ e: WindowEntry) { newOrder.append(e.cgWindowID); newByID[e.cgWindowID] = e }
        // history = the set of "former active tabs" inherited when the seat continues. Intersected with the full CG list: truly closed tabs
        // drop out with it, preventing a reused cgID from being wrongly folded into an old seat. wasEverVisible = whether the seat has been visible before (inherited on continuation);
        // appearing now with min=false also counts -- a phantom seat can never earn this flag (the top gate of self-heal).
        func make(token: String, _ s: AXWindowSnapshot, previousTitle: String? = nil,
                  history: Set<CGWindowID> = [], wasEverVisible: Bool = false,
                  previousDisplayUUID: String? = nil, previousHoldUntil: Date? = nil) -> WindowEntry {
            // The ownership key follows the frame only while visible; minimized / hidden reuse the previous seat's value (frozen on the last visible display);
            // the optimistic key from a cross-display window drag also stays put during the freeze; a pinned one (`.distantFuture`) is released only once this AX read actually sees a visible frame.
            let visible = !s.isMinimized && !app.isHidden
            let fresh = visible ? WindowDisplayAttribution.displayUUID(for: s.bounds, table: displayTable) : nil
            let sticky = previousHoldUntil == .distantFuture
            let held = !sticky && (previousHoldUntil.map { $0 > now } ?? false)
            let displayUUID: String?
            let holdUntil: Date?
            if sticky {
                displayUUID = fresh ?? previousDisplayUUID
                holdUntil = fresh == nil ? previousHoldUntil : nil
            } else if held {
                displayUUID = previousDisplayUUID
                holdUntil = previousHoldUntil
            } else {
                displayUUID = fresh ?? previousDisplayUUID
                holdUntil = nil
            }
            return WindowEntry(cgWindowID: s.cgWindowID!, token: token,
                               title: s.titleRead.resolvedTitle(previousTitle: previousTitle),
                               bounds: s.bounds, isMinimized: s.isMinimized, isFocused: s.isFocusedWindow,
                               everSeenVisible: wasEverVisible || !s.isMinimized,
                               formerCgIDs: history.subtracting([s.cgWindowID!]).intersection(cgIDs),
                               displayUUID: displayUUID,
                               displayUUIDHoldUntil: holdUntil)
        }
        // How many old seats currently claim a given frame (>1 = overlapping-window ambiguity; skipped during tab-switch displacement, conservatively avoiding a wrong merge)
        func seatsAtFrame(_ key: String) -> Int {
            app.windowOrder.filter { fk(app.windowsByID[$0]?.bounds) == key }.count
        }

        // Number of seats whose current activeCgID is still in AX -- the "sibling seat present" gate of phantom self-heal (the phantom itself is absent, so naturally not counted).
        let axPresentSeatCount = app.windowOrder.filter { eligibleByCgID[$0] != nil }.count
        var healedSeats: [(cgID: CGWindowID, token: String, episodeID: UUID)] = []
        var releasedSeats: [(seat: WindowEntry, reason: InventorySeatReleasedReason)] = []
        var tearOutCgIDs: Set<CGWindowID> = []
        // Seats released by merging a tab -> owning seat (member learning; written back after Pass A finishes, as the owner may not be seated yet).
        var mergedIntoOwner: [(cgID: CGWindowID, ownerActiveCgID: CGWindowID)] = []
        // Sibling view for TabMergeDecision: old seats present in AX this round, with frames taken from this round's AX snapshot (the ones stored in seats may be stale).
        func axPresentSeatsForMerge(excluding candidate: CGWindowID) -> [TabMergeDecision.AXPresentSeat] {
            app.windowOrder.compactMap { id in
                guard id != candidate, let snap = eligibleByCgID[id] else { return nil }
                return TabMergeDecision.AXPresentSeat(activeCgID: id, bounds: snap.bounds, isMinimized: snap.isMinimized)
            }
        }

        // Pass A: each old seat tries to continue
        for cgID in app.windowOrder {
            guard var seat = app.windowsByID[cgID] else { continue }
            let X = seat.cgWindowID
            let seatKey = fk(seat.bounds)
            if let snapX = eligibleByCgID[X], !usedEligible.contains(X) {
                if inventoryLog.isEnabled, let episodeID = seat.absenceEpisodeID {
                    heldLogDeduplicator.clear(pid: pid, seatToken: seat.token, episodeID: episodeID)
                }
                InventoryAbsenceEpisode.clear(
                    absentSince: &seat.minAbsentSince,
                    episodeID: &seat.absenceEpisodeID
                )
                // X is still visible. Check "dragging the current tab out": X moved to a new frame and another eligible window Y took its place at the old frame.
                // **Do not tear during the cross-display move freeze** (`displayUUIDHoldUntil` valid / pinned): that frame move was written by us,
                // so the seat must follow X -- otherwise the seat stays on the old frame and switches to Y, inheriting the key and freeze just written for the target display, and X falls into Pass B
                // creating a new seat: both cards sit on the target strip, and once the freeze ends the old seat jumps back to the source display (owner 2026-09-03, multi-tab Finder).
                let moveHeld = seat.displayUUIDHoldUntil.map { $0 == .distantFuture || $0 > now } ?? false
                if let seatKey, fk(snapX.bounds) != seatKey, !moveHeld,
                   let Y = eligible.first(where: { s in
                       guard let c = s.cgWindowID, c != X, !usedEligible.contains(c) else { return false }
                       return fk(s.bounds) == seatKey
                   }), let yc = Y.cgWindowID {
                    // The seat stays on the old frame and is replaced by Y, token unchanged. X is evicted as an independent window -> NOT recorded in history
                    place(make(token: seat.token, Y, history: seat.formerCgIDs,
                               wasEverVisible: seat.everSeenVisible,
                               previousDisplayUUID: seat.displayUUID,
                               previousHoldUntil: seat.displayUUIDHoldUntil))
                    usedEligible.insert(yc)
                    subscribeWindow(pid: pid, element: Y.element, cgWindowID: yc, context: reconcileContext)   // taking over the new activeCgID requires subscribing; see the displacement branch below for why
                    tearOutCgIDs.insert(X)
                    // X is not marked used -> falls to Pass B and becomes a new seat (the evicted current tab)
                } else {
                    // Normal: follow X (the frame can move)
                    if case .unread(let error) = snapX.titleRead, let reconcileContext {
                        inventoryLog.record(.titleHeld(InventoryTitleHeldPayload(
                            context: reconcileContext,
                            pid: pid,
                            bundleID: app.bundleIdentifier,
                            seatToken: seat.token,
                            activeCgID: X,
                            errorCode: error.rawValue
                        )))
                    }
                    place(make(token: seat.token, snapX, previousTitle: seat.title,
                               history: seat.formerCgIDs,
                               wasEverVisible: seat.everSeenVisible,
                               previousDisplayUUID: seat.displayUUID,
                               previousHoldUntil: seat.displayUUIDHoldUntil))
                    usedEligible.insert(X)
                    // A continuing seat re-subscribes too: after an order-out/order-in blink the window
                    // answers with a new AX element and the old one's notifications never fire again —
                    // without this the next real order-out goes unnoticed and the seat is held forever.
                    subscribeWindow(pid: pid, element: snapX.element, cgWindowID: X, context: reconcileContext)
                }
            } else {
                // X left AX: did a new current tab take over at the old frame? -> tab switch
                if let seatKey, seatsAtFrame(seatKey) == 1,
                   let Y = eligible.first(where: { s in
                       guard let c = s.cgWindowID, !usedEligible.contains(c), app.windowsByID[c] == nil else { return false }
                       return fk(s.bounds) == seatKey
                   }), let yc = Y.cgWindowID {
                    if inventoryLog.isEnabled, let episodeID = seat.absenceEpisodeID {
                        heldLogDeduplicator.clear(pid: pid, seatToken: seat.token, episodeID: episodeID)
                    }
                    InventoryAbsenceEpisode.clear(
                        absentSince: &seat.minAbsentSince,
                        episodeID: &seat.absenceEpisodeID
                    )
                    // Displaced, token unchanged -> card doesn't jump. X is a background tab that was switched away -> record in history (a closed tab has a
                    // tombstone / has left CG, and make's intersection keeps truly closed ones out)
                    var history = seat.formerCgIDs
                    if !isTombstoned(X) { history.insert(X) }
                    place(make(token: seat.token, Y, history: history,
                               wasEverVisible: seat.everSeenVisible,
                               previousDisplayUUID: seat.displayUUID,
                               previousHoldUntil: seat.displayUUIDHoldUntil))
                    usedEligible.insert(yc)
                    // The taking-over Y must subscribe to per-window notifications here (destroy/min/demin/title are subscribed in only three places for a taking-over activeCgID: new seat, displacement, tear-out replacement).
                    // Otherwise there is no destroy notification when Y closes -> no tombstone; a window closed in Ghostty lingers in the full CG list,
                    // and the seat takes the "still in CG" keep branch and leaves a permanent phantom card (verified 2026-08-23 by closing the last tab of a minimized tab group).
                    subscribeWindow(pid: pid, element: Y.element, cgWindowID: yc, context: reconcileContext)
                } else if cgIDs.contains(X) && !isTombstoned(X) {
                    // X left AX but is still in CG. Distinguish "minimized/hidden (keep seat)" vs "window closed but lingering in CG (should delete)":
                    // signal = whether the last state before leaving AX was min (minimize passes through the Miniaturized notification first and marks min; closing does not).
                    seat.formerCgIDs.formIntersection(cgIDs)   // history anti-reuse: leaves the list once out of CG
                    if seat.isMinimized || app.isHidden {
                        InventoryAbsenceEpisode.beginIfNeeded(
                            absentSince: &seat.minAbsentSince,
                            episodeID: &seat.absenceEpisodeID,
                            now: now
                        )
                        let absentFor = now.timeIntervalSince(seat.minAbsentSince ?? now)
                        let evaluation = PhantomSeatDecision.evaluate(
                            everSeenVisible: seat.everSeenVisible,
                            axAbsentFor: absentFor,
                            threshold: Self.phantomReapGrace,
                            cgStillPresent: true,
                            axReadSawWindows: !eligible.isEmpty,
                            axPresentSiblingCount: axPresentSeatCount
                        )
                        // Phantom-seat self-heal: never visible + AX absent long enough + app not hung + has an AX-present
                        // sibling seat -> judged a phantom split off by a failed fold; release it (do not place). A truly minimized/hidden
                        // window can't pass everSeenVisible or the sibling gate, and keeps its seat indefinitely as before.
                        if evaluation.shouldRelease, let episodeID = seat.absenceEpisodeID {
                            healedSeats.append((X, seat.token, episodeID))
                            releasedSeats.append((seat, .phantomHealed))
                            if inventoryLog.isEnabled {
                                heldLogDeduplicator.clear(
                                    pid: pid, seatToken: seat.token, episodeID: episodeID
                                )
                            }
                        } else {
                            if let reconcileContext,
                               absentFor >= Self.phantomReapGrace,
                               let episodeID = seat.absenceEpisodeID,
                               heldLogDeduplicator.shouldRecord(
                                   pid: pid,
                                   seatToken: seat.token,
                                   episodeID: episodeID,
                                   reasons: evaluation.holdReasons
                               ) {
                                inventoryLog.record(.phantomHeld(InventoryPhantomHeldPayload(
                                    context: reconcileContext,
                                    pid: pid,
                                    bundleID: app.bundleIdentifier,
                                    seatToken: seat.token,
                                    activeCgID: X,
                                    absenceEpisodeID: episodeID,
                                    holdReasons: evaluation.holdReasons.map(\.rawValue).sorted(),
                                    appHidden: app.isHidden,
                                    everSeenVisible: seat.everSeenVisible,
                                    absentForMs: Int((absentFor * 1_000).rounded()),
                                    thresholdMs: Int((Self.phantomReapGrace * 1_000).rounded()),
                                    eligibleWindowCount: eligible.count,
                                    axPresentSiblingCount: axPresentSeatCount,
                                    bounds: seat.bounds.map(InventoryLogRect.init)
                                )))
                            }
                            seat.isFocused = false
                            seat.absentProbe = nil
                            place(seat)                   // truly minimized (Safari leaves AX) / app hidden -> keep the seat
                        }
                    } else {
                        // Not minimized and the app is not hidden, yet it left AX: first ask whether it was merged into another window as a background tab
                        // (TabMergeDecision: CG says not on screen + CG bounds have the same frame as some AX-present sibling seat).
                        // If so -> release; otherwise one window gets two cards, and every later tab switch splits off another.
                        let mergeVerdict = TabMergeDecision.verdict(
                            candidateIsOnScreen: onScreenCGIDs.contains(X),
                            candidateCGBounds: cgSnapshot.boundsByWindowID[X],
                            candidateSeatBounds: seat.bounds,
                            axPresentSeats: axPresentSeatsForMerge(excluding: X),
                            frameKey: fk
                        )
                        if case .release(let owner) = mergeVerdict {
                            releasedSeats.append((seat, .mergedIntoTabbedWindow))
                            if let owner { mergedIntoOwner.append((cgID: X, ownerActiveCgID: owner)) }
                        } else {
                            seat.isFocused = false
                            // AX success doesn't mean the window list is complete. As long as CG still confirms the current activeCgID exists and has no
                            // destroy tombstone, keep the original seat; AX absence can never by itself prove a window was closed.
                            // The one exception is a confirmed dead element (`AbsentSeatReleaseDecision`).
                            if applyAbsentSeatProbe(
                                seat: &seat, pid: pid, bundleID: app.bundleIdentifier,
                                isOnScreen: onScreenCGIDs.contains(X), rawAXCgIDs: rawAXCgIDs,
                                evidence: absenceEvidence[X], context: reconcileContext
                            ) {
                                releasedSeats.append((seat, .hiddenWithoutDestroy))
                            } else {
                                place(seat)
                            }
                        }
                    }
                } else {
                    // Even CG no longer has it -> truly closed, discard.
                    releasedSeats.append((seat, .leftCGList))
                }
            }
        }

        // Pass B: eligible windows nobody claimed -> new seats (new windows / evicted current tabs).
        // The token uses a global auto-incrementing sequence, **never derived from a cgID** -- cgIDs get reused, and deriving from one can collide (observed: an old seat's
        // seed=68 with activeCgID already swapped to 60; later 68 became its own window and generated the same token -> two seats collided on one card).
        // **Minimize folding**: when minimizing a multi-tab window, Ghostty exposes **all of the window's tabs** at once as
        // AX windows (normally it exposes only the current tab). They are all min=true -- background tabs of the same (minimized) window -- and are folded into
        // the already-seated seat rather than creating new seats (otherwise one card would split off per tab).
        // Three-level decision (TabFoldDecision): membership (was once this seat's active tab, independent of geometry) -> exact frame match
        // -> size fallback (same width/height + off-screen, rescuing "background tab AX coordinates stale after the window moves"). When folded with a unique owner, the
        // candidate is recorded into the seat history (member learning) so the next fold no longer depends on geometry.
        // Non-min windows with the same frame are the legitimate "two independent windows overlapping" case, and each builds its own seat as usual.
        // Member learning for merged tabs: the owning seat is always seated in Pass A this round (it is present in AX); write back before Pass B,
        // so a minimize burst right after in the same round can also fold by membership.
        for merged in mergedIntoOwner {
            newByID[merged.ownerActiveCgID]?.formerCgIDs.insert(merged.cgID)
        }
        var placedForFold: [TabFoldDecision.PlacedSeat] = newOrder.compactMap { id in
            guard let e = newByID[id] else { return nil }
            return TabFoldDecision.PlacedSeat(activeCgID: e.cgWindowID, bounds: e.bounds,
                                              isMinimized: e.isMinimized, formerCgIDs: e.formerCgIDs)
        }
        for s in eligible {
            guard let c = s.cgWindowID, !usedEligible.contains(c), newByID[c] == nil else { continue }
            let verdict = TabFoldDecision.verdict(
                candidateCgID: c,
                candidateBounds: s.bounds,
                candidateIsMinimized: s.isMinimized,
                candidateIsOnScreen: onScreenCGIDs.contains(c),
                candidateIsKnownShadow: shadowPool.contains(c),
                placedSeats: placedForFold,
                frameKey: fk
            )
            switch verdict {
            case .fold(let owner, _):
                usedEligible.insert(c)   // background tab -> fold into an existing seat, no new seat
                if let owner { newByID[owner]?.formerCgIDs.insert(c) }   // member learning
            case .newSeat:
                let hadPlacedSeat = !placedForFold.isEmpty
                if s.isMinimized, !placedForFold.isEmpty {
                    // Diagnostics (always on): a min=true candidate failing all four decision levels while a seat is already placed, falling through to a new seat =
                    // a potential split point; dump all decision inputs to capture the scene. An empty placed (an
                    // independent window that was already minimized at seed time) is a correct new seat and is not printed. Zero output on the normal path -- don't clear this away as leftover.
                    let cand = s.bounds.map { "\(Int($0.origin.x)),\(Int($0.origin.y)) \(Int($0.width))x\(Int($0.height))" } ?? "nil"
                    let placedDesc = placedForFold.map { p in
                        let b = p.bounds.map { "\(Int($0.origin.x)),\(Int($0.origin.y)) \(Int($0.width))x\(Int($0.height))" } ?? "nil"
                        return "(cg=\(p.activeCgID) min=\(p.isMinimized) b=[\(b)] hist=\(p.formerCgIDs.sorted()))"
                    }.joined(separator: " ")
                    print("[tabfold] 分裂点 pid=\(pid) 为 min 窗口新建座位 cg=\(c) b=[\(cand)] onScreen=\(onScreenCGIDs.contains(c)) shadow=\(shadowPool.contains(c)) pool=\(shadowPool.count) placed=\(placedDesc)")
                }
                nextSeatSerial += 1
                let entry = make(token: "tabgrp-\(pid)-s\(nextSeatSerial)", s)
                if let reconcileContext {
                    let isOnScreen = onScreenCGIDs.contains(c)
                    let creationReason = InventorySeatCreationReason.classify(
                        hasPlacedSeat: hadPlacedSeat,
                        isTearOut: tearOutCgIDs.contains(c),
                        isMinimized: s.isMinimized,
                        isOnScreen: isOnScreen
                    )
                    let relations: [InventorySeatRelation] = newOrder.compactMap { id in
                        guard let existing = newByID[id] else { return nil }
                        let exactFrame = fk(existing.bounds) != nil && fk(existing.bounds) == fk(s.bounds)
                        let nearbyFrame: Bool
                        if let lhs = existing.bounds, let rhs = s.bounds {
                            nearbyFrame = WindowFrameMatchPolicy.areClose(lhs, rhs)
                        } else {
                            nearbyFrame = false
                        }
                        let sizeMatches: Bool
                        if let lhs = existing.bounds, let rhs = s.bounds {
                            sizeMatches = abs(lhs.width - rhs.width) < 3 && abs(lhs.height - rhs.height) < 3
                        } else {
                            sizeMatches = false
                        }
                        return InventorySeatRelation(
                            seatToken: existing.token,
                            activeCgID: existing.cgWindowID,
                            isMinimized: existing.isMinimized,
                            everSeenVisible: existing.everSeenVisible,
                            bounds: existing.bounds.map(InventoryLogRect.init),
                            formerCgIDs: existing.formerCgIDs.sorted(),
                            formerContainsCandidate: existing.formerCgIDs.contains(c),
                            normalizedTitleMatches: WindowInventoryDiagnosticRelations.normalizedTitlesMatch(
                                existing.title, s.title
                            ),
                            exactFrameMatches: exactFrame,
                            nearbyFrameMatches: nearbyFrame,
                            sizeMatches: sizeMatches
                        )
                    }
                    inventoryLog.record(.seatCreated(InventorySeatCreatedPayload(
                        context: reconcileContext,
                        pid: pid,
                        bundleID: app.bundleIdentifier,
                        seatToken: entry.token,
                        activeCgID: c,
                        creationReason: creationReason,
                        isMinimized: s.isMinimized,
                        isOnScreen: isOnScreen,
                        isFocused: s.isFocusedWindow,
                        appHidden: app.isHidden,
                        bounds: s.bounds.map(InventoryLogRect.init),
                        candidateKnownShadow: shadowPool.contains(c),
                        eligibleWindowCount: eligible.count,
                        minimizedEligibleCount: eligible.filter(\.isMinimized).count,
                        onScreenEligibleCount: eligible.compactMap(\.cgWindowID).filter {
                            onScreenCGIDs.contains($0)
                        }.count,
                        cgWindowCount: cgPidIDs.count,
                        eligibleCgIDs: eligible.compactMap(\.cgWindowID).sorted(),
                        cgWindowIDs: cgPidIDs.sorted(),
                        shadowPool: shadowPool.sorted(),
                        existingSeats: relations
                    )))
                }
                place(entry)
                subscribeWindow(pid: pid, element: s.element, cgWindowID: c, context: reconcileContext)
                placedForFold.append(TabFoldDecision.PlacedSeat(activeCgID: entry.cgWindowID, bounds: entry.bounds,
                                                                isMinimized: entry.isMinimized, formerCgIDs: entry.formerCgIDs))
            }
        }

        // Phantom self-heal archiving: when exactly one AX-present seat exists, record the released cgID into its history (the next burst folds it instantly by membership);
        // with several seats it's ambiguous, so don't learn -- the released id returns to the shadow pool anyway and is still blocked by the pool.
        if !healedSeats.isEmpty {
            let axPresentPlaced = newOrder.filter { eligibleByCgID[$0] != nil }
            let ownerCandidates = axPresentPlaced.compactMap { cgID -> InventoryPhantomOwner? in
                guard let token = newByID[cgID]?.token else { return nil }
                return InventoryPhantomOwner(seatToken: token, activeCgID: cgID)
            }
            let owner = InventoryPhantomOwnerResolution.uniqueOwner(from: ownerCandidates)
            for healed in healedSeats {
                if let owner {
                    newByID[owner.activeCgID]?.formerCgIDs.insert(healed.cgID)
                }
                if let reconcileContext {
                    inventoryLog.record(.phantomHealed(InventoryPhantomHealedPayload(
                        context: reconcileContext,
                        pid: pid,
                        bundleID: app.bundleIdentifier,
                        releasedSeatToken: healed.token,
                        releasedActiveCgID: healed.cgID,
                        absenceEpisodeID: healed.episodeID,
                        ownerSeatToken: owner?.seatToken,
                        ownerActiveCgID: owner?.activeCgID,
                        ownerCandidateCount: ownerCandidates.count
                    )))
                }
                let ownerDescription = owner.map { String($0.activeCgID) } ?? "无(歧义)"
                print("[tabheal] 自愈 pid=\(pid) 释放幽灵座位 cg=\(healed.cgID) 归入=\(ownerDescription)")
            }
        }

        for released in releasedSeats {
            let snapshot = inventorySeatReleaseSnapshot(app: app, seats: [released.seat])
            for payload in InventorySeatReleasePlan.payloads(
                for: snapshot,
                reason: released.reason,
                context: reconcileContext
            ) {
                inventoryLog.record(.seatReleased(payload))
            }
        }

        // Roll the shadow tab pool to the next round (this round's decision used the old pool). Health gate: if AX read no windows at all while CG
        // still has some (app hung / AX read failed) -> leave the pool untouched this round. Rules: out of CG (truly closed) -> out of pool; appearing in AX with min=false
        // (active tab / truly visible window / torn-out tab) -> out of pool; in CG but not in AX and not a seated activeCgID
        // (Safari-style real windows kept by min, and seats held in grace, don't enter the pool, to prevent wrong folding after a seat is lost) -> into the pool.
        // Appearing in AX with min=true does not leave the pool -- that is exactly the minimize-burst moment, and the pool must hold for the whole minimized period.
        let shouldUpdateShadowPool = !eligible.isEmpty || cgPidIDs.isEmpty
        if shouldUpdateShadowPool {
            var pool = app.shadowTabCgIDs
            pool.formIntersection(cgPidIDs)
            for s in eligible { if let c = s.cgWindowID, !s.isMinimized { pool.remove(c) } }
            pool.formUnion(cgPidIDs.subtracting(eligibleByCgID.keys).subtracting(newOrder))
            app.shadowTabCgIDs = pool

            if let reconcileContext {
                var diagnostic = shadowPoolDiagnosticsByPID[pid] ?? ShadowPoolDiagnosticState()
                func recordShadowPool(_ status: InventoryShadowPoolStatus) {
                    inventoryLog.record(.shadowPoolState(InventoryShadowPoolPayload(
                        context: reconcileContext,
                        pid: pid,
                        bundleID: app.bundleIdentifier,
                        status: status,
                        previousSuccessfulRoundID: diagnostic.lastSuccessfulRoundID,
                        before: shadowPool.sorted(),
                        after: pool.sorted(),
                        added: pool.subtracting(shadowPool).sorted(),
                        removed: shadowPool.subtracting(pool).sorted(),
                        eligibleWindowCount: eligible.count,
                        cgWindowCount: cgPidIDs.count
                    )))
                }
                if !diagnostic.initialized {
                    recordShadowPool(.initialized)
                }
                if diagnostic.updateWasSkipped {
                    recordShadowPool(.resumed)
                } else if diagnostic.initialized, pool != shadowPool {
                    recordShadowPool(.changed)
                }
                diagnostic.initialized = true
                diagnostic.updateWasSkipped = false
                diagnostic.lastSuccessfulRoundID = reconcileContext.roundID
                shadowPoolDiagnosticsByPID[pid] = diagnostic
            }
        } else if let reconcileContext {
            var diagnostic = shadowPoolDiagnosticsByPID[pid] ?? ShadowPoolDiagnosticState()
            if !diagnostic.updateWasSkipped {
                inventoryLog.record(.shadowPoolState(InventoryShadowPoolPayload(
                    context: reconcileContext,
                    pid: pid,
                    bundleID: app.bundleIdentifier,
                    status: .updateSkipped,
                    previousSuccessfulRoundID: diagnostic.lastSuccessfulRoundID,
                    before: shadowPool.sorted(),
                    after: shadowPool.sorted(),
                    added: [],
                    removed: [],
                    eligibleWindowCount: eligible.count,
                    cgWindowCount: cgPidIDs.count
                )))
            }
            diagnostic.updateWasSkipped = true
            shadowPoolDiagnosticsByPID[pid] = diagnostic
        }

        // Subscription hygiene against cgWindowID reuse. Keep this round's seats and AX-present
        // windows even if this round's CG capture predates them (a periodic batch captures CG before
        // its AX reads land), and skip entirely when the capture failed.
        if !cgSnapshot.captureFailed, let observer = observers[pid] {
            let dropped = observer.retainSubscriptions(
                keep: cgIDs.union(newOrder).union(eligibleByCgID.keys)
            )
            if inventoryLog.isEnabled {
                for entry in dropped {
                    recordSubscriptionEvent(InventoryWindowSubscriptionPayload(
                        event: .leftCG, context: reconcileContext, flushID: nil, pid: pid,
                        bundleID: app.bundleIdentifier, cgWindowID: entry.cgWindowID,
                        instanceID: entry.instanceID
                    ))
                }
            }
        }

        let hadSeats = !app.windowOrder.isEmpty
        app.windowOrder = newOrder
        app.windowsByID = newByID
        apps[pid] = app
        let changed = seatSignature(app) != before
        // Last seat gone → ask (with retries) whether the process is still `.regular`; a menu-bar
        // app that flipped back to `.accessory` must not keep projecting an `app-*` fallback chip.
        if hadSeats, newOrder.isEmpty { scheduleNonRegularEviction(pid: pid) }
        gateStates[pid] = ReconcileGateState(
            lastCGIDs: cgPidIDs,
            lastFullReadUptime: uptimeProvider(),
            dirty: false,
            lastReadWasUnread: false,
            lastRoundChanged: changed || app.shadowTabCgIDs != shadowPool,
            lastSeatOnScreenIDs: Set(newOrder).intersection(onScreenCGIDs)
        )
        return changed
    }

    /// The absence fallback for a seat held in the "left AX, not minimized, not hidden, still in CG"
    /// branch. Returns true when the seat is to be released (`AbsentSeatReleaseDecision.release`).
    /// Candidates are only created from reads that carry the raw (pre-filter) AX id set; a window
    /// still in raw `AXWindows`, on-screen, or never subscribed is not a candidate.
    private func applyAbsentSeatProbe(
        seat: inout WindowEntry,
        pid: pid_t,
        bundleID: String?,
        isOnScreen: Bool,
        rawAXCgIDs: Set<CGWindowID>?,
        evidence: AbsentSeatProbeEvidence?,
        context: InventoryReconcileContext?
    ) -> Bool {
        guard absentSeatReleaseEnabled, let rawAXCgIDs else { return false }
        let cgID = seat.cgWindowID
        guard !isOnScreen, !rawAXCgIDs.contains(cgID),
              let handle = subscribedElement(pid: pid, cgWindowID: cgID) else {
            seat.absentProbe = nil
            return false
        }
        let now = uptimeProvider()
        var probe = seat.absentProbe ?? AbsentSeatProbeState(nextProbeUptime: now)
        defer { seat.absentProbe = probe }
        guard let evidence else { return false }

        let firstHiddenAgeMs = probe.firstHidden.map { Int(((now - $0.uptime) * 1_000).rounded()) }
        let verdict = AbsentSeatReleaseDecision.verdict(AbsentSeatReleaseDecision.Input(
            evidenceMatchesSeat: evidence.request.seatToken == seat.token
                && evidence.request.cgWindowID == cgID
                && evidence.request.instanceID == handle.instanceID,
            element: evidence.element,
            spaces: evidence.spaces,
            firstHidden: probe.firstHidden,
            cgWindowID: cgID,
            instanceID: evidence.request.instanceID,
            now: now
        ))
        switch verdict {
        case .release:
            break
        case .markFirst:
            probe.firstHidden = AbsentSeatProbeState.FirstHiddenMark(
                uptime: now, cgWindowID: cgID, instanceID: evidence.request.instanceID
            )
            probe.nextProbeUptime = now + AbsentSeatReleaseDecision.confirmMinInterval
        case .holdMark:
            if let first = probe.firstHidden {
                probe.nextProbeUptime = first.uptime + AbsentSeatReleaseDecision.confirmMinInterval
            }
        case .notHidden:
            probe.firstHidden = nil
        }
        recordAbsenceProbe(
            evidence: evidence, verdict: verdict, pid: pid, bundleID: bundleID,
            context: context, firstHiddenAgeMs: firstHiddenAgeMs
        )
        return verdict == .release
    }

    private func recordAbsenceProbe(
        evidence: AbsentSeatProbeEvidence,
        verdict: AbsentSeatReleaseDecision.Verdict?,
        discardReason: String? = nil,
        pid: pid_t,
        bundleID: String?,
        context: InventoryReconcileContext?,
        firstHiddenAgeMs: Int?
    ) {
        guard inventoryLog.isEnabled else { return }
        let element: String
        var minimized: Bool?
        var errorCode: Int32?
        switch evidence.element {
        case .dead: element = "dead"; errorCode = AXError.invalidUIElement.rawValue
        case .alive(let value): element = "alive"; minimized = value
        case .unknown(let code): element = "unknown"; errorCode = code
        }
        let verdictName: String
        switch verdict {
        case .release: verdictName = "release"
        case .markFirst: verdictName = "markFirst"
        case .holdMark: verdictName = "holdMark"
        case .notHidden(let reason): verdictName = "notHidden:\(reason.rawValue)"
        case nil: verdictName = "discarded:\(discardReason ?? "unknown")"
        }
        inventoryLog.record(.absenceProbe(InventoryAbsenceProbePayload(
            context: context,
            pid: pid,
            bundleID: bundleID,
            seatToken: evidence.request.seatToken,
            cgWindowID: evidence.request.cgWindowID,
            instanceID: evidence.request.instanceID,
            element: element,
            elementMinimized: minimized,
            elementErrorCode: errorCode,
            windowSpaceIDs: evidence.windowSpaceIDs,
            currentSpaceIDs: evidence.currentSpaceIDs.map { $0.sorted() },
            spaceClass: evidence.spaces.rawValue,
            verdict: verdictName,
            probeCount: evidence.request.probeCount,
            firstHiddenAgeMs: firstHiddenAgeMs
        )))
    }

    private func subscribedElement(pid: pid_t, cgWindowID: CGWindowID) -> (element: AXUIElement, instanceID: UInt64)? {
        #if DEBUG
        if let overrides = subscribedElementOverridesForTesting[pid] { return overrides[cgWindowID] }
        #endif
        return observers[pid]?.subscribedElement(cgWindowID: cgWindowID)
    }

    /// Picks this pid's due absence probes (earliest first, at most `maxProbesPerRead`) for a read
    /// being dispatched now, and charges their budget at dispatch: a landing that is later
    /// discarded must not make the same candidate eligible again on the next read.
    private func takeDueAbsenceProbes(pid: pid_t) -> [AbsentSeatProbeRequest] {
        guard absentSeatReleaseEnabled, var app = apps[pid] else { return [] }
        let now = uptimeProvider()
        let due = app.windowOrder
            .compactMap { id -> (CGWindowID, AbsentSeatProbeState)? in
                guard let probe = app.windowsByID[id]?.absentProbe, probe.nextProbeUptime <= now else { return nil }
                return (id, probe)
            }
            .sorted { $0.1.nextProbeUptime < $1.1.nextProbeUptime }
            .prefix(AbsentSeatReleaseDecision.maxProbesPerRead)
        guard !due.isEmpty else { return [] }
        var requests: [AbsentSeatProbeRequest] = []
        for (cgID, state) in due {
            guard let token = app.windowsByID[cgID]?.token,
                  let handle = subscribedElement(pid: pid, cgWindowID: cgID) else {
                app.windowsByID[cgID]?.absentProbe = nil
                continue
            }
            var probe = state
            probe.probeCount += 1
            probe.nextProbeUptime = now + AbsentSeatReleaseDecision.backoff(afterDispatch: probe.probeCount)
            app.windowsByID[cgID]?.absentProbe = probe
            requests.append(AbsentSeatProbeRequest(
                cgWindowID: cgID, seatToken: token, element: handle.element,
                instanceID: handle.instanceID, probeCount: probe.probeCount
            ))
        }
        apps[pid] = app
        return requests
    }

    private func hasDueAbsenceProbe(pid: pid_t) -> Bool {
        guard absentSeatReleaseEnabled, let app = apps[pid] else { return false }
        let now = uptimeProvider()
        return app.windowOrder.contains { (app.windowsByID[$0]?.absentProbe?.nextProbeUptime ?? .infinity) <= now }
    }

    /// After a landing: dispatch a read now if a probe is due, or arm one timer for the earliest
    /// probe due before the next 5s tick (later ones are dispatched by `reconcile()`).
    private func armAbsenceProbes(pid: pid_t) {
        cancelAbsenceProbeTimer(pid: pid)
        guard absentSeatReleaseEnabled, let app = apps[pid] else { return }
        guard let next = app.windowOrder.compactMap({ app.windowsByID[$0]?.absentProbe?.nextProbeUptime }).min() else {
            return
        }
        let delay = next - uptimeProvider()
        if delay <= 0 {
            scheduleEventRead(pid: pid, source: .absenceProbe)
            return
        }
        guard delay < 5 else { return }
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.absenceProbeTimers.removeValue(forKey: pid)
                self.armAbsenceProbes(pid: pid)
            }
        }
        absenceProbeTimers[pid] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func cancelAbsenceProbeTimer(pid: pid_t) {
        absenceProbeTimers.removeValue(forKey: pid)?.cancel()
    }

    /// Minimize / restore / create / destroy / hide / unhide change what a pending "hidden" mark
    /// meant, and none of their handlers runs `reconcileSeats`, so the marks are dropped here.
    private func clearFirstHiddenMarks(pid: pid_t) {
        guard var app = apps[pid] else { return }
        var touched = false
        for id in app.windowOrder where app.windowsByID[id]?.absentProbe?.firstHidden != nil {
            app.windowsByID[id]?.absentProbe?.firstHidden = nil
            touched = true
        }
        if touched { apps[pid] = app }
    }

    private func inventoryReconcileContext(
        pid: pid_t,
        source: InventoryReconcileSource,
        now: Date,
        usedPreloadedAX: Bool,
        axReadOutcome: InventoryAXReadOutcome
    ) -> InventoryReconcileContext {
        nextInventoryRoundID += 1
        let ordinal = (reconcileOrdinalsByPID[pid] ?? 0) + 1
        let gapMs = lastReconcileAtByPID[pid].map {
            max(0, Int((now.timeIntervalSince($0) * 1_000).rounded()))
        }
        reconcileOrdinalsByPID[pid] = ordinal
        lastReconcileAtByPID[pid] = now
        return InventoryReconcileContext(
            roundID: nextInventoryRoundID,
            appReconcileOrdinal: ordinal,
            source: source,
            gapMs: gapMs,
            usedPreloadedAX: usedPreloadedAX,
            axReadOutcome: axReadOutcome
        )
    }

    private func clearInventoryDiagnostics(pid: pid_t) {
        reconcileOrdinalsByPID.removeValue(forKey: pid)
        lastReconcileAtByPID.removeValue(forKey: pid)
        shadowPoolDiagnosticsByPID.removeValue(forKey: pid)
        heldLogDeduplicator.removeAll(pid: pid)
    }

    private func inventorySeatReleaseSnapshot(
        app: AppEntry,
        seats: [WindowEntry]? = nil
    ) -> InventorySeatReleaseSnapshot {
        let selected = seats ?? app.windowOrder.compactMap { app.windowsByID[$0] }
        return InventorySeatReleaseSnapshot(
            pid: app.pid,
            bundleID: app.bundleIdentifier,
            appHidden: app.isHidden,
            seats: selected.map { entry in
                InventorySeatReleaseSnapshot.Seat(
                    seatToken: entry.token,
                    activeCgID: entry.cgWindowID,
                    isMinimized: entry.isMinimized,
                    isFocused: entry.isFocused,
                    everSeenVisible: entry.everSeenVisible,
                    bounds: entry.bounds
                )
            }
        )
    }

    private func recordProcessGoneSeats(app: AppEntry) {
        let snapshot = inventorySeatReleaseSnapshot(app: app)
        for payload in InventorySeatReleasePlan.processGonePayloads(for: snapshot) {
            inventoryLog.record(.seatReleased(payload))
        }
    }

    /// Lightweight fingerprint of the seat set (order + token + title + minimized/focus + display), used to tell whether this reconcile actually changed anything.
    /// The display is a coarse display UUID; **the coordinates themselves never enter the fingerprint**.
    private func seatSignature(_ app: AppEntry) -> String {
        app.windowOrder.map { id -> String in
            let e = app.windowsByID[id]
            return "\(id):\(e?.token ?? ""):\(e?.title ?? ""):\(e?.isMinimized == true ? 1 : 0):\(e?.isFocused == true ? 1 : 0):\(e?.displayUUID ?? "")"
        }.joined(separator: "|")
    }

    // MARK: - Display attribution (multi-display item 4)

    /// Display changes the CG pass proposed on the previous tick, waiting for a second tick to agree.
    private var pendingCGDisplayKeys: [CGWindowID: String] = [:]

    /// 5s tick: re-attribute **every** visible seat from its CG bounds, covering pids the skip gate left
    /// without an AX read (a background app's window moved to another display). Changes only the key —
    /// never `bounds` (the AX frame `frameKey` / `seatsAtFrame` rely on) and never the skip-gate state.
    /// No CG bounds / bounds touching no display → the old key stays.
    ///
    /// A new key applies only when two consecutive ticks agree. While a window minimizes or restores its
    /// CG bounds are not a position: they travel to the system Dock and back (~0.5s), crossing onto the
    /// Dock's display, and the AX `min=true` read lands only after the animation — a single mid-animation
    /// tick would move the seat and the minimize would then freeze it on the wrong display.
    private func refreshDisplayAttributionFromCG(_ cgSnapshot: AppTrackerCGWindowSnapshot) -> Bool {
        guard !cgSnapshot.boundsByWindowID.isEmpty, !displayTable.displays.isEmpty else { return false }
        let now = Date()
        var changed = false
        var pending: [CGWindowID: String] = [:]
        for pid in appOrder {
            guard let app = apps[pid], !app.isHidden else { continue }
            for cgID in app.windowOrder {
                guard let seat = app.windowsByID[cgID], !seat.isMinimized,
                      !(seat.displayUUIDHoldUntil.map { $0 > now } ?? false),
                      let rect = cgSnapshot.boundsByWindowID[cgID],
                      let key = WindowDisplayAttribution.displayUUID(for: rect, table: displayTable),
                      key != seat.displayUUID else { continue }
                guard pendingCGDisplayKeys[cgID] == key else {
                    pending[cgID] = key
                    continue
                }
                apps[pid]?.windowsByID[cgID]?.displayUUID = key
                changed = true
            }
        }
        pendingCGDisplayKeys = pending
        return changed
    }

    /// Display parameters changed (plug/unplug / main display swap / arrangement change): swap the display table, and recompute visible seats from stored AX frames; keep the old key when it can't be computed
    ///(the projection layer drops a key pointing at an unplugged display onto the main display). Reads no AX and takes no CG capture.
    private func handleScreenParametersChanged() {
        displayTable = displayTableProvider()
        let now = Date()
        var changed = false
        for pid in appOrder {
            guard let app = apps[pid], !app.isHidden else { continue }
            for cgID in app.windowOrder {
                guard let seat = app.windowsByID[cgID], !seat.isMinimized,
                      !(seat.displayUUIDHoldUntil.map { $0 > now } ?? false),
                      let key = WindowDisplayAttribution.displayUUID(for: seat.bounds, table: displayTable),
                      key != seat.displayUUID else { continue }
                apps[pid]?.windowsByID[cgID]?.displayUUID = key
                changed = true
            }
        }
        if changed { rebuildSnapshot(onScreenCGIDs: lastOnScreenCGIDs) }
    }

    /// Optimistic update for a cross-display window drag (`AppRuntime.moveWindow`): the user action writes the ownership key and publishes directly, so the card jumps to the target strip on the spot,
    /// without waiting for the next read. `.brief` freezes for `displayMoveHold` (the AX frame write is in flight on the action queue; reads landing meanwhile still see the old position);
    /// `.untilVisible` pins until it is next visible in AX (off-screen / phantom windows whose AX handle can't be obtained: dragging = changing address);
    /// on write failure the caller rolls back with the old key `.none` (the truth is then corrected by AX / CG reads). Recognizes registered seats only.
    static let displayMoveHold: TimeInterval = 1.5

    enum DisplayKeyHold { case none, brief, untilVisible }

    /// When the fallback card for "running but no windows" / a kept placeholder of a running app is dragged onto another display's strip: for all processes under this bundle,
    /// the "display where the window last was" is set to that display and published (a bundle has only one fallback card, so keying by bundle keeps it from being lost when the pid changes).
    func noteNoWindowHome(bundleID: String, displayUUID: String) {
        guard !bundleID.isEmpty else { return }
        var changed = false
        var matched = 0
        for pid in appOrder where apps[pid]?.bundleIdentifier == bundleID {
            matched += 1
            guard apps[pid]?.lastWindowDisplayUUID != displayUUID else { continue }
            apps[pid]?.lastWindowDisplayUUID = displayUUID
            changed = true
        }
        if Self.displayTraceEnabled {
            displayTraceLogger.info("noteNoWindowHome bundle=\(bundleID, privacy: .public) to=\(displayUUID, privacy: .public) matchedPIDs=\(matched) changed=\(changed)")
        }
        if changed { rebuildSnapshot(onScreenCGIDs: lastOnScreenCGIDs) }
    }

    /// Verdict after the AX frame write of a cross-display window drag fails: if the window is on screen right now (a real window the user can see) -> roll back to the source display;
    /// if not on screen (off-screen / phantom seat) -> nothing to move, so pin it to the target display as "changing address".
    enum FailedMoveVerdict: Equatable { case rolledBack, pinnedToTarget, seatGone }

    @discardableResult
    func resolveFailedWindowMove(pid: pid_t, cgWindowID: CGWindowID, target: String, previous: String?) -> FailedMoveVerdict {
        guard apps[pid]?.windowsByID[cgWindowID] != nil else { return .seatGone }
        if lastOnScreenCGIDs.contains(cgWindowID) {
            noteWindowMoved(pid: pid, cgWindowID: cgWindowID, displayUUID: previous, hold: .none)
            return .rolledBack
        }
        noteWindowMoved(pid: pid, cgWindowID: cgWindowID, displayUUID: target, hold: .untilVisible)
        return .pinnedToTarget
    }

    private static let displayTraceEnabled = DebugSwitch.displayTrace.isEnabled(in: ProcessInfo.processInfo.environment)
    private let displayTraceLogger = Logger(subsystem: "app.neobar.NeoBar", category: "display-trace")

    @discardableResult
    func noteWindowMoved(pid: pid_t, cgWindowID: CGWindowID, displayUUID: String?, hold: DisplayKeyHold = .brief) -> Bool {
        guard let seat = apps[pid]?.windowsByID[cgWindowID] else { return false }
        let holdUntil: Date?
        switch hold {
        case .none: holdUntil = nil
        case .brief: holdUntil = Date().addingTimeInterval(Self.displayMoveHold)
        case .untilVisible: holdUntil = .distantFuture
        }
        apps[pid]?.windowsByID[cgWindowID]?.displayUUIDHoldUntil = holdUntil
        if Self.displayTraceEnabled {
            displayTraceLogger.info("noteWindowMoved pid=\(pid) cg=\(cgWindowID) \(seat.displayUUID ?? "nil", privacy: .public) → \(displayUUID ?? "nil", privacy: .public) hold=\(String(describing: hold), privacy: .public)")
        }
        guard seat.displayUUID != displayUUID else { return true }
        apps[pid]?.windowsByID[cgWindowID]?.displayUUID = displayUUID
        rebuildSnapshot(onScreenCGIDs: lastOnScreenCGIDs)
        return true
    }

    // MARK: - Seed

    private func seedRunningApps() {
        let seedStart = Date()
        // Environment variable DOCK_SEED_AX_TIMEOUT_MS: 0 = fall back to the old unlimited read; other values override the milliseconds; default 100ms.
        let timeoutMS = DebugSwitch.seedAxTimeoutMs.value(in: ProcessInfo.processInfo.environment)
        let useTimeout: Bool
        var messagingTimeout: TimeInterval = 0.1
        if let ms = timeoutMS, let val = Int(ms) {
            if val == 0 {
                useTimeout = false
            } else {
                useTimeout = true
                messagingTimeout = TimeInterval(val) / 1000.0
            }
        } else {
            useTimeout = true
        }

        var admittedCount = 0
        var unreadList: [String] = []
        let cgSnapshot = cgSnapshotProvider()

        for app in NSWorkspace.shared.runningApplications {
            guard isRegularNonSelf(app) else { continue }
            let pid = app.processIdentifier
            let bid = app.bundleIdentifier
            let eligibilityApplication = eligibilityApplication(for: app)
            let probeIdentity = inventoryLog.isEnabled ? processIdentity(pid: pid, bundleID: bid) : nil

            // Time-limited probe: a hung app times out on its first AX message -> .unread -> skipped, left to the supplementary scan.
            let result: AXWindowReadResult
            if useTimeout {
                result = reader.inventoryWindows(forPID: pid, messagingTimeout: messagingTimeout)
            } else {
                // Keep legacy untimed/two-attempt behavior while preserving `.unread` for diagnostics.
                result = reader.windowReadResult(forPID: pid)
            }

            let probedEligible: [AXWindowSnapshot]
            let inventoryReadOutcome: InventoryAXReadOutcome
            switch result {
            case .success(let snaps):
                probedEligible = snaps.filter {
                    isEligible($0, application: eligibilityApplication, cgSnapshot: cgSnapshot)
                }
                inventoryReadOutcome = .success(count: snaps.count)
            case .unread(let error):
                probedEligible = []
                inventoryReadOutcome = .unread(errorCode: error.rawValue)
                unreadList.append(app.localizedName ?? bid ?? "\(pid)")
            }

            let seedVerdict: InventoryAdmissionProbeVerdict
            if FinderWindowRules.isFinder(bundleIdentifier: bid) {
                seedVerdict = .admitFinderPersistent
            } else if case .unread = result {
                seedVerdict = .skipUnread
            } else if probedEligible.isEmpty {
                seedVerdict = .skipNoEligible
            } else {
                seedVerdict = .admit
            }
            if let probeIdentity {
                recordAdmissionProbe(
                    source: .seed,
                    identity: probeIdentity,
                    readMode: useTimeout ? .timed : .untimed,
                    messagingTimeoutMs: useTimeout ? Int((messagingTimeout * 1_000).rounded()) : nil,
                    maxAttempts: useTimeout ? 1 : 2,
                    result: result,
                    eligibleWindowCount: result.isSuccess ? probedEligible.count : nil,
                    verdict: seedVerdict
                )
            }

            if FinderWindowRules.isFinder(bundleIdentifier: bid) {
                // Finder always holds a slot: if unread, hold it with an empty window list first (the slot is permanent; notifications/reconcile fill it in later).
                addApp(app, enumerateImmediately: false)
                reconcileSeats(
                    pid: pid,
                    cgSnapshot: cgSnapshot,
                    now: Date(),
                    source: .seed,
                    preloadedEligible: probedEligible,
                    preloadedReadOutcome: inventoryReadOutcome,
                    preloadedReadMode: useTimeout ? .timed : .untimed
                )
                admittedCount += 1
                continue
            }

            if !probedEligible.isEmpty {
                addApp(app, enumerateImmediately: false)
                reconcileSeats(
                    pid: pid,
                    cgSnapshot: cgSnapshot,
                    now: Date(),
                    source: .seed,
                    preloadedEligible: probedEligible,
                    preloadedReadOutcome: inventoryReadOutcome,
                    preloadedReadMode: useTimeout ? .timed : .untimed
                )
                admittedCount += 1
            }
        }

        rebuildSnapshot(onScreenCGIDs: cgSnapshot.onScreenWindowIDs)

        let elapsed = Date().timeIntervalSince(seedStart)
        logger.info("seed done: \(admittedCount) admitted, \(unreadList.count) unread [\(unreadList.joined(separator: ", "))], elapsed=\(String(format: "%.2f", elapsed))s")
    }

    // MARK: - Workspace Notifications

    private func subscribeWorkspaceNotifications() {
        let nc = NSWorkspace.shared.notificationCenter

        workspaceObservers.append(nc.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor [weak self] in self?.handleAppLaunched(app) }
        })

        workspaceObservers.append(nc.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            Task { @MainActor [weak self] in self?.handleAppTerminated(pid: pid) }
        })

        workspaceObservers.append(nc.addObserver(
            forName: NSWorkspace.didHideApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            Task { @MainActor [weak self] in self?.handleAppHidden(pid: pid) }
        })

        workspaceObservers.append(nc.addObserver(
            forName: NSWorkspace.didUnhideApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            Task { @MainActor [weak self] in self?.handleAppUnhidden(pid: pid) }
        })

        workspaceObservers.append(nc.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            Task { @MainActor [weak self] in
                // The frontmost cache applies to all activations (accessory/self also take the foreground); the regular filter
                // in handleAppActivated only governs admission, not the frontmost fact.
                self?.cachedFrontmostPID = pid
                self?.handleAppActivated(app)
            }
        })
    }

    // MARK: - Workspace Handlers

    private func handleAppLaunched(_ app: NSRunningApplication) {
        guard isRegularNonSelf(app) else { return }
        scanDirtyPIDs.insert(app.processIdentifier)
        scanCandidateCache = nil
        if FinderWindowRules.isFinder(bundleIdentifier: app.bundleIdentifier) {
            // Remove any stale Finder entry left over from a quit/relaunch cycle,
            // then add the fresh entry with the new pid.
            if let stalePID = appOrder.first(where: {
                FinderWindowRules.isFinder(bundleIdentifier: apps[$0]?.bundleIdentifier)
            }), stalePID != app.processIdentifier {
                observers[stalePID]?.stop()
                observers.removeValue(forKey: stalePID)
                apps.removeValue(forKey: stalePID)
                appOrder.removeAll { $0 == stalePID }
                clearInventoryDiagnostics(pid: stalePID)
                gateStates.removeValue(forKey: stalePID)
                cancelAbsenceProbeTimer(pid: stalePID)
                invalidateEventReads(pid: stalePID)
                elementCache.removeAll(pid: stalePID)
            }
            addApp(app, enumerateImmediately: true)
            rebuildSnapshot()
            return
        }
        scheduleRetryAdmission(app: app, delays: [0.2, 0.5, 1.0, 2.0])
    }

    private func handleAppActivated(_ app: NSRunningApplication) {
        guard isRegularNonSelf(app) else { return }
        guard apps[app.processIdentifier] == nil else {
            markReconcileGateDirty(pid: app.processIdentifier)
            rebuildSnapshot()  // frontmost changed → active highlight update
            return
        }
        addApp(app, enumerateImmediately: true)
        rebuildSnapshot()
    }

    private func handleAppTerminated(pid: pid_t) {
        cgEventGeneration &+= 1
        invalidateEventReads(pid: pid)
        observers[pid]?.stop()
        observers.removeValue(forKey: pid)
        if let app = apps[pid] { recordProcessGoneSeats(app: app) }
        clearInventoryDiagnostics(pid: pid)
        gateStates.removeValue(forKey: pid)
        cancelAbsenceProbeTimer(pid: pid)
        scanMemos.removeValue(forKey: pid)
        scanDirtyPIDs.remove(pid)
        scanCandidateCache = nil
        nonRegularEvictionTasks.removeValue(forKey: pid)?.cancel()

        // Finder relaunches immediately via launchd. Keep the entry (no windows) so the chip
        // stays visible during the gap. handleAppLaunched will replace this stale entry with
        // the new pid when Finder comes back up.
        if FinderWindowRules.isFinder(bundleIdentifier: apps[pid]?.bundleIdentifier) {
            apps[pid]?.windowsByID = [:]
            apps[pid]?.windowOrder = []
            rebuildSnapshot()
            return
        }

        apps.removeValue(forKey: pid)
        appOrder.removeAll { $0 == pid }
        elementCache.removeAll(pid: pid)
        rebuildSnapshot()
    }

    private func handleAppHidden(pid: pid_t) {
        markReconcileGateDirty(pid: pid)
        clearFirstHiddenMarks(pid: pid)
        apps[pid]?.isHidden = true
        rebuildSnapshot()
    }

    private func handleAppUnhidden(pid: pid_t) {
        markReconcileGateDirty(pid: pid)
        clearFirstHiddenMarks(pid: pid)
        apps[pid]?.isHidden = false
        rebuildSnapshot()
    }

    // MARK: - App Management

    private func addApp(
        _ app: NSRunningApplication,
        enumerateImmediately: Bool,
        source: InventoryReconcileSource = .initialEnumeration
    ) {
        let pid = app.processIdentifier
        guard apps[pid] == nil else { return }
        cgEventGeneration &+= 1

        apps[pid] = AppEntry(
            pid: pid,
            bundleIdentifier: app.bundleIdentifier,
            appName: app.localizedName ?? app.bundleIdentifier ?? "\(pid)",
            activationPolicy: app.activationPolicy,
            executablePath: app.executableURL?.path,
            windowsByID: [:],
            windowOrder: [],
            isHidden: app.isHidden
        )
        appOrder.append(pid)
        mutationGenerations[pid, default: 0] &+= 1
        scanMemos.removeValue(forKey: pid)
        scanDirtyPIDs.remove(pid)
        scanCandidateCache = nil

        if AXIsProcessTrusted() {
            let obs = AppWindowObserver(pid: pid)
            obs.onWindowCreated = { [weak self] pid in self?.handleWindowCreated(pid: pid) }
            obs.onWindowDestroyed = { [weak self] pid, cgID in self?.handleWindowDestroyed(pid: pid, cgWindowID: cgID) }
            obs.onWindowMinimized = { [weak self] pid, cgID in self?.handleWindowMinimized(pid: pid, cgWindowID: cgID) }
            obs.onWindowDeminiaturized = { [weak self] pid, cgID in self?.handleWindowDeminiaturized(pid: pid, cgWindowID: cgID) }
            obs.onFocusedWindowChanged = { [weak self] pid in self?.handleFocusedWindowChanged(pid: pid) }
            obs.onTitleChanged = { [weak self] pid, cgID in self?.handleTitleChanged(pid: pid, cgWindowID: cgID) }
            obs.onSubscriptionDestroyNotified = { [weak self] pid, cgID, removedInstanceID in
                self?.noteSubscriptionDestroyNotified(pid: pid, cgWindowID: cgID, removedInstanceID: removedInstanceID)
            }
            obs.start()
            observers[pid] = obs
        }

        if enumerateImmediately {
            enumerateWindows(for: pid, source: source)
        }
    }

    private func scheduleRetryAdmission(app: NSRunningApplication, delays: [TimeInterval]) {
        let pid = app.processIdentifier
        for delay in delays {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard let self else { return }
                if self.apps[pid] != nil {
                    self.enumerateWindows(for: pid, source: .initialEnumeration)
                    return
                }
                guard NSRunningApplication(processIdentifier: pid)?.isTerminated == false else { return }
                let windows = self.reader.windows(forPID: pid)
                let cgSnapshot = self.cgSnapshotProvider()
                let eligibilityApplication = self.eligibilityApplication(for: app)
                let hasEligible = windows.contains {
                    self.isEligible($0, application: eligibilityApplication, cgSnapshot: cgSnapshot)
                }
                if hasEligible {
                    self.addApp(app, enumerateImmediately: true)
                    self.rebuildSnapshot()
                }
            }
        }
    }

    // MARK: - Non-Regular Eviction

    /// The system Dock drops a process the moment it leaves `.regular`; a seatless `AppEntry` would
    /// otherwise keep its `app-*` fallback chip for the process's whole life (`reconcile()` only
    /// removes dead pids). Retries cover the policy flipping slightly after the window close.
    private func scheduleNonRegularEviction(pid: pid_t) {
        nonRegularEvictionTasks[pid]?.cancel()
        let probedIdentity = processIdentity(pid: pid, bundleID: apps[pid]?.bundleIdentifier)
        nonRegularEvictionTasks[pid] = Task { @MainActor [weak self] in
            for delay in Self.nonRegularEvictionDelays {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                switch self.evictIfNonRegular(pid: pid, probedIdentity: probedIdentity) {
                case .keepRegular, .keepPolicyUnknown:
                    continue
                case .evict, .keepUntracked, .keepFinder, .keepHasSeats, .keepIdentityChanged:
                    self.nonRegularEvictionTasks.removeValue(forKey: pid)
                    return
                }
            }
            self?.nonRegularEvictionTasks.removeValue(forKey: pid)
        }
    }

    @discardableResult
    private func evictIfNonRegular(
        pid: pid_t,
        probedIdentity: ScanAdmissionDecision.ProcessIdentity? = nil
    ) -> NonRegularEvictionDecision.Verdict {
        let app = apps[pid]
        let currentIdentity = processIdentity(pid: pid, bundleID: app?.bundleIdentifier)
        let verdict = NonRegularEvictionDecision.verdict(
            isTracked: app != nil,
            isFinder: FinderWindowRules.isFinder(bundleIdentifier: app?.bundleIdentifier),
            hasSeats: !(app?.windowOrder.isEmpty ?? true),
            identityMatches: probedIdentity.map {
                ScanAdmissionDecision.ProcessIdentity.matches(probed: $0, current: currentIdentity)
            } ?? true,
            isRegular: app == nil ? nil : processProvider.isRegularApplication(pid: pid)
        )
        if verdict == .evict { evictNonRegularEntry(pid: pid) }
        return verdict
    }

    private func evictNonRegularEntry(pid: pid_t) {
        nonRegularEvictionTasks.removeValue(forKey: pid)?.cancel()
        guard let app = apps[pid], app.windowOrder.isEmpty else { return }
        logger.info("evict: pid=\(pid) \(app.appName, privacy: .public) left .regular with no seats, dropping the app-level fallback")
        cgEventGeneration &+= 1
        invalidateEventReads(pid: pid)
        observers[pid]?.stop()
        observers.removeValue(forKey: pid)
        clearInventoryDiagnostics(pid: pid)
        gateStates.removeValue(forKey: pid)
        cancelAbsenceProbeTimer(pid: pid)
        scanMemos.removeValue(forKey: pid)
        scanDirtyPIDs.remove(pid)
        scanCandidateCache = nil
        apps.removeValue(forKey: pid)
        appOrder.removeAll { $0 == pid }
        elementCache.removeAll(pid: pid)
        rebuildSnapshot()
    }

    private func sweepNonRegularZeroSeatEntries() {
        for pid in appOrder where apps[pid]?.windowOrder.isEmpty == true {
            evictIfNonRegular(pid: pid)
        }
    }

    // MARK: - Window Enumeration

    private func enumerateWindows(for pid: pid_t, source: InventoryReconcileSource) {
        guard apps[pid] != nil else { return }
        let cgSnapshot = cgSnapshotProvider()
        if reconcileSeats(pid: pid, cgSnapshot: cgSnapshot, now: Date(), source: source) {
            rebuildSnapshot(onScreenCGIDs: cgSnapshot.onScreenWindowIDs)
        }
    }

    private func isEligible(
        _ snap: AXWindowSnapshot,
        application: AppTrackerWindowEligibility.Application,
        cgSnapshot: AppTrackerCGWindowSnapshot
    ) -> Bool {
        let alpha = snap.cgWindowID.flatMap { cgSnapshot.alphaByWindowID[$0] }
        return windowEligibility.isEligible(
            title: snap.title,
            role: snap.role,
            subrole: snap.subrole,
            bounds: snap.bounds,
            alpha: alpha,
            isMinimized: snap.isMinimized,
            isBelowNormalLayer: snap.cgWindowID.map {
                cgSnapshot.belowNormalLayerWindowIDs.contains($0)
            } ?? false,
            application: application
        )
    }

    private func eligibilityApplication(for app: AppEntry) -> AppTrackerWindowEligibility.Application {
        AppTrackerWindowEligibility.Application(
            bundleIdentifier: app.bundleIdentifier,
            appName: app.appName,
            activationPolicy: app.activationPolicy,
            executablePath: app.executablePath
        )
    }

    private func eligibilityApplication(for app: NSRunningApplication) -> AppTrackerWindowEligibility.Application {
        AppTrackerWindowEligibility.Application(
            bundleIdentifier: app.bundleIdentifier,
            appName: app.localizedName ?? app.bundleIdentifier ?? "\(app.processIdentifier)",
            activationPolicy: app.activationPolicy,
            executablePath: app.executableURL?.path
        )
    }

    // MARK: - Window Subscriptions

    /// Every seat placement with an AX element in hand goes through here (new seat, tab takeover,
    /// tear-out replacement, plain continuation). Initial / renewal attempts run inside the reconcile;
    /// a due retry is queued and at most one runs after this main-thread turn (`flushRetryCandidates`).
    private func subscribeWindow(
        pid: pid_t,
        element: AXUIElement,
        cgWindowID: CGWindowID,
        context: InventoryReconcileContext?
    ) {
        guard let observer = observers[pid] else { return }
        switch observer.registerWindow(element, cgWindowID: cgWindowID) {
        case .none:
            return
        case .attempted(let report):
            recordSubscriptionAttempt(report, context: context, flushID: nil)
        case .retryDue(let candidate):
            retryCandidates.append(candidate)
            guard !retryFlushScheduled else { return }
            retryFlushScheduled = true
            // Runs after the whole landing (single event read, periodic batch, scan or seed), so the
            // pick sees every pid that landed together.
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.flushRetryCandidates() }
            }
        }
    }

    private func flushRetryCandidates() {
        retryFlushScheduled = false
        let candidates = retryCandidates
        retryCandidates.removeAll()
        guard !candidates.isEmpty else { return }
        nextRetryFlushID &+= 1
        let flushID = nextRetryFlushID
        let observers = self.observers
        let choice = WindowSubscriptionRetryScheduler.pick(candidates) { candidate in
            observers[candidate.pid]?.isRetryValid(candidate) ?? false
        }
        let report = choice.picked.flatMap { observers[$0.pid]?.performRetry($0) }
        guard inventoryLog.isEnabled else { return }
        inventoryLog.record(.subscriptionRetryFlush(InventorySubscriptionRetryFlushPayload(
            flushID: flushID,
            candidates: candidates.map {
                InventorySubscriptionRetryCandidateEntry(pid: $0.pid, cgWindowID: $0.cgWindowID)
            },
            skippedInvalid: choice.skippedInvalid,
            executedPID: report?.pid,
            executedCgWindowID: report?.cgWindowID,
            durationMs: report?.durationMs
        )))
        if let report { recordSubscriptionAttempt(report, context: nil, flushID: flushID) }
    }

    private func recordSubscriptionAttempt(
        _ report: WindowSubscriptionAttemptReport,
        context: InventoryReconcileContext?,
        flushID: UInt64?
    ) {
        guard inventoryLog.isEnabled else { return }
        recordSubscriptionEvent(InventoryWindowSubscriptionPayload(
            event: .attempt, context: context, flushID: flushID, pid: report.pid,
            bundleID: apps[report.pid]?.bundleIdentifier, cgWindowID: report.cgWindowID,
            instanceID: report.instanceID, previousInstanceID: report.previousInstanceID,
            kind: report.kind,
            results: Dictionary(uniqueKeysWithValues: report.results.map { ($0.key.logName, $0.value.rawValue) }),
            stop: report.stop, covered: report.covered,
            durationMs: (report.durationMs * 10).rounded() / 10
        ))
    }

    private func noteSubscriptionDestroyNotified(pid: pid_t, cgWindowID: CGWindowID, removedInstanceID: UInt64?) {
        guard inventoryLog.isEnabled else { return }
        recordSubscriptionEvent(InventoryWindowSubscriptionPayload(
            event: .destroyNotified, context: nil, flushID: nil, pid: pid,
            bundleID: apps[pid]?.bundleIdentifier, cgWindowID: cgWindowID,
            instanceID: removedInstanceID, removedCurrent: removedInstanceID != nil
        ))
    }

    private func recordSubscriptionEvent(_ payload: InventoryWindowSubscriptionPayload) {
        inventoryLog.record(.windowSubscription(payload))
    }

    // MARK: - AX Event Handlers

    private func handleWindowCreated(pid: pid_t) {
        markReconcileGateDirty(pid: pid)
        clearFirstHiddenMarks(pid: pid)
        scheduleEventRead(pid: pid, source: .windowCreated)
    }

    private func handleWindowDestroyed(pid: pid_t, cgWindowID: CGWindowID) {
        guard apps[pid] != nil else { return }
        markReconcileGateDirty(pid: pid)
        clearFirstHiddenMarks(pid: pid)
        invalidateEventReads(pid: pid)
        destroyedCGIDs[cgWindowID] = Date()
        purgeFromSeatHistories(cgWindowID)
        // Delete the element cache only when it is truly closed. The destroy notification may arrive before the full CG list updates, so delete explicitly here once,
        // without waiting for the CG intersection in reconcileSeats below.
        elementCache.remove(pid: pid, cgWindowID: cgWindowID)
        // Don't delete the seat directly: if this was the current tab of a tabbed window being closed while another tab of the same physical window takes its place,
        // reconcileSeats lets the seat swap activeCgID in place and keep the token (the card doesn't flicker or change identity). If the whole window closes, it is truly deleted.
        // Reconcile goes through a time-limited background event read (same as created / focus / title): previously this ran `reconcileSeats` directly on the main actor
        // with an unlimited read, so if the closed window's app was stuck, the taskbar main thread could freeze for up to ~12s.
        scheduleEventRead(pid: pid, source: .windowDestroyed)
    }

    private func handleWindowMinimized(pid: pid_t, cgWindowID: CGWindowID) {
        markReconcileGateDirty(pid: pid)
        clearFirstHiddenMarks(pid: pid)
        invalidateEventReads(pid: pid)
        apps[pid]?.windowsByID[cgWindowID]?.isMinimized = true
        apps[pid]?.windowsByID[cgWindowID]?.isFocused = false
        rebuildSnapshot()
    }

    private func handleWindowDeminiaturized(pid: pid_t, cgWindowID: CGWindowID) {
        markReconcileGateDirty(pid: pid)
        clearFirstHiddenMarks(pid: pid)
        invalidateEventReads(pid: pid)
        apps[pid]?.windowsByID[cgWindowID]?.isMinimized = false
        rebuildSnapshot()
    }

    private func handleFocusedWindowChanged(pid: pid_t) {
        markReconcileGateDirty(pid: pid)
        scheduleEventRead(pid: pid, source: .focusChanged)
    }

    private func handleTitleChanged(pid: pid_t, cgWindowID: CGWindowID) {
        markReconcileGateDirty(pid: pid)
        scheduleEventRead(pid: pid, source: .titleChanged)
    }

    private func markReconcileGateDirty(pid: pid_t) {
        gateStates[pid]?.dirty = true
        cgEventGeneration &+= 1
    }

    private func invalidateEventReads(pid: pid_t) {
        mutationGenerations[pid, default: 0] &+= 1
        // The in-flight read now lands as `.skipped`, so whatever it was fetching must be fetched
        // again. Dropping it lost a destroy's follow-up read whenever a minimize of another window
        // landed first (orderOut + miniaturize in one burst): the next periodic read came after the
        // 3s tombstone and the hidden window's seat was held for the app's lifetime.
        if let inFlight = pendingEventReads[pid], trailingEventSources[pid] == nil {
            trailingEventSources[pid] = inFlight.source
        }
    }

    private func scheduleEventRead(pid: pid_t, source: InventoryReconcileSource) {
        guard apps[pid] != nil else { return }
        guard eventAXAsyncEnabled else {
            enumerateWindows(for: pid, source: source)
            return
        }
        if pendingEventReads[pid] != nil {
            // Coalesce any burst while a read is in flight into exactly one read using the latest
            // event source. Completion consumes and clears this slot before starting it.
            trailingEventSources[pid] = source
            return
        }

        nextEventReadToken &+= 1
        let request = PendingEventRead(
            token: nextEventReadToken,
            mutationGeneration: mutationGenerations[pid, default: 0],
            identity: processIdentity(pid: pid, bundleID: apps[pid]?.bundleIdentifier),
            source: source,
            absenceProbes: takeDueAbsenceProbes(pid: pid)
        )
        pendingEventReads[pid] = request
        let reader = self.reader
        let cgSnapshotProvider = self.cgSnapshotProvider
        let probeProvider = self.onScreenWindowIDsProvider
        let prober = self.absentSeatProber
        let ticket = makeCGSnapshotReuseTicket(pid: pid)

        Task.detached { [weak self] in
            let result = reader.inventoryWindows(forPID: pid, messagingTimeout: 0.1)
            // Absence probes run only on a readable round, after the AX list and before the CG
            // capture: a window shown again meanwhile is then on-screen in the table that decides.
            var evidence: [AbsentSeatProbeEvidence] = []
            if !request.absenceProbes.isEmpty, case .success = result {
                evidence = request.absenceProbes.map { prober.probe($0, messagingTimeout: 0.1) }
            }
            // Hard ordering rule: probe first, full capture after (see the header comment of CGSnapshotReuseDecision for the reason).
            let acquisition: CGSnapshotAcquisition
            switch request.absenceProbes.isEmpty
                ? CGSnapshotReuseDecision.preVerdict(ticket.input) : .captureWithoutProbe {
            case .captureWithoutProbe:
                acquisition = CGSnapshotAcquisition(
                    snapshot: cgSnapshotProvider(), probeIDs: nil, fresh: true, ticket: ticket
                )
            case .captureAndPrime:
                let probe = probeProvider()
                acquisition = CGSnapshotAcquisition(
                    snapshot: cgSnapshotProvider(), probeIDs: probe, fresh: true, ticket: ticket
                )
            case .probeThenCompare:
                let probe = probeProvider()
                switch CGSnapshotReuseDecision.probeVerdict(
                    probe: probe, cachedProbe: ticket.cachedProbeIDs ?? []
                ) {
                case .reuse:
                    if let cached = ticket.cachedSnapshot,
                       !CGSnapshotReuseDecision.cachedLayerVetoApplies(
                           axWindowIDs: Set(result.windowsOrEmpty.compactMap(\.cgWindowID)),
                           cachedBelowNormalLayerIDs: cached.belowNormalLayerWindowIDs
                       ) {
                        acquisition = CGSnapshotAcquisition(
                            snapshot: cached, probeIDs: probe, fresh: false, ticket: ticket
                        )
                    } else {
                        // No cache (preVerdict guarantees one; defensive), or the cached table
                        // would veto a window AX just listed — that verdict needs a fresh layer.
                        acquisition = CGSnapshotAcquisition(
                            snapshot: cgSnapshotProvider(), probeIDs: probe, fresh: true, ticket: ticket
                        )
                    }
                case .captureAndPrime:
                    acquisition = CGSnapshotAcquisition(
                        snapshot: cgSnapshotProvider(), probeIDs: probe, fresh: true, ticket: ticket
                    )
                }
            }
            let landedEvidence = evidence
            await MainActor.run { [weak self] in
                self?.noteCGSnapshotAcquisition(acquisition)
                self?.completeEventRead(
                    pid: pid,
                    request: request,
                    result: result,
                    cgSnapshot: acquisition.snapshot,
                    absenceEvidence: landedEvidence
                )
            }
        }
    }

    /// Source of the CG table returned by a background event read: a fresh capture (including the same-round probe, used to link up the cache) or a reused cache.
    private struct CGSnapshotAcquisition: Sendable {
        let snapshot: AppTrackerCGWindowSnapshot
        let probeIDs: Set<CGWindowID>?
        let fresh: Bool
        let ticket: CGSnapshotReuseTicket
    }

    /// Main-thread ticket assembly: static criteria are fixed here (age is computed at ticket-assembly time; the time cost of the background read is already included in
    /// `defaultMaxCacheAge`). The cached snapshot / probe set travels with the ticket, so the background task never reads main-thread state back.
    private struct CGSnapshotReuseTicket: Sendable {
        let input: CGSnapshotReuseDecision.Input
        let cachedSnapshot: AppTrackerCGWindowSnapshot?
        let cachedProbeIDs: Set<CGWindowID>?
        let uptime: TimeInterval
        let generation: UInt64
    }

    private func makeCGSnapshotReuseTicket(pid: pid_t) -> CGSnapshotReuseTicket {
        let now = uptimeProvider()
        let app = apps[pid]
        let input = CGSnapshotReuseDecision.Input(
            reuseEnabled: cgSnapshotReuseEnabled,
            hasCache: cachedCGSnapshot != nil && cachedCGProbeIDs != nil,
            cachedCaptureFailed: cachedCGSnapshot?.captureFailed ?? true,
            cacheAge: now - cachedCGAtUptime,
            generationMatches: cachedCGGeneration == cgEventGeneration,
            hasAbsenceClock: app?.windowOrder.contains {
                app?.windowsByID[$0]?.minAbsentSince != nil
            } ?? false,
            hasPhantomCandidate: app?.windowOrder.contains {
                app?.windowsByID[$0]?.everSeenVisible == false
            } ?? false,
            observerActive: observerActive(pid: pid)
        )
        return CGSnapshotReuseTicket(
            input: input,
            cachedSnapshot: cachedCGSnapshot,
            cachedProbeIDs: cachedCGProbeIDs,
            uptime: now,
            generation: cgEventGeneration
        )
    }

    /// Only a **fresh capture** refreshes the cache (a reuse round doesn't -- refreshing would defeat the age cap). Out-of-order landings are blocked by the ticket-assembly time:
    /// an old ticket's fresh capture doesn't overwrite the new cache. The generation records its value at ticket-assembly time: if an event arrived in between, the cache generation lags -> next round takes a fresh capture, conservatively.
    private func noteCGSnapshotAcquisition(_ acquisition: CGSnapshotAcquisition) {
        guard cgSnapshotReuseEnabled, acquisition.fresh,
              let probe = acquisition.probeIDs,
              acquisition.ticket.uptime >= cachedCGAtUptime else { return }
        cachedCGSnapshot = acquisition.snapshot
        cachedCGProbeIDs = probe
        cachedCGAtUptime = acquisition.ticket.uptime
        cachedCGGeneration = acquisition.ticket.generation
    }

    private enum EventReadLanding {
        case staleToken                  // token was invalidated/superseded: the whole landing is void (the new in-flight read owns trailing)
        case skipped                     // token matched and was consumed, but generation/process identity mismatched -> touch no state
        case reconciled(seatsChanged: Bool)
    }

    /// Common core for landing one background time-limited read: validate and consume the pending token, pass the mutation-generation and process-identity checks, then
    /// run reconcileSeats. Does **not** rebuild the snapshot and does **not** consume trailing -- the single-shot paths (event/foreground polling) need to layer
    /// an on-screen forced refresh on top, while the batch path (periodic reconcile) rebuilds only once for the whole batch; each finishes up outside.
    private func landEventRead(
        pid: pid_t,
        request: PendingEventRead,
        result: AXWindowReadResult,
        cgSnapshot: AppTrackerCGWindowSnapshot,
        absenceEvidence: [AbsentSeatProbeEvidence] = []
    ) -> EventReadLanding {
        guard pendingEventReads[pid]?.token == request.token else { return .staleToken }
        pendingEventReads.removeValue(forKey: pid)

        let currentIdentity = apps[pid].map {
            processIdentity(pid: pid, bundleID: $0.bundleIdentifier)
        }
        guard mutationGenerations[pid, default: 0] == request.mutationGeneration,
              currentIdentity.map({
                  ScanAdmissionDecision.ProcessIdentity.matches(probed: request.identity, current: $0)
              }) == true,
              let app = apps[pid] else { return .skipped }

        let readOutcome: InventoryAXReadOutcome
        let eligible: [AXWindowSnapshot]
        var rawAXCgIDs: Set<CGWindowID>?
        switch result {
        case .success(let windows):
            readOutcome = .success(count: windows.count)
            rawAXCgIDs = Set(windows.compactMap(\.cgWindowID))
            let application = eligibilityApplication(for: app)
            eligible = windows.filter {
                isEligible($0, application: application, cgSnapshot: cgSnapshot)
            }
        case .unread(let error):
            readOutcome = .unread(errorCode: error.rawValue)
            eligible = []
        }
        var evidenceByCgID: [CGWindowID: AbsentSeatProbeEvidence] = [:]
        for item in absenceEvidence { evidenceByCgID[item.request.cgWindowID] = item }
        let seatsChanged = reconcileSeats(
            pid: pid,
            cgSnapshot: cgSnapshot,
            now: Date(),
            source: request.source,
            preloadedEligible: eligible,
            preloadedReadOutcome: readOutcome,
            preloadedReadMode: .timed,
            rawAXCgIDs: rawAXCgIDs,
            absenceEvidence: evidenceByCgID
        )
        return .reconciled(seatsChanged: seatsChanged)
    }

    private func completeEventRead(
        pid: pid_t,
        request: PendingEventRead,
        result: AXWindowReadResult,
        cgSnapshot: AppTrackerCGWindowSnapshot,
        absenceEvidence: [AbsentSeatProbeEvidence] = []
    ) {
        let landing = landEventRead(
            pid: pid, request: request, result: result, cgSnapshot: cgSnapshot,
            absenceEvidence: absenceEvidence
        )
        if case .reconciled = landing {} else {
            for item in absenceEvidence {
                recordAbsenceProbe(
                    evidence: item, verdict: nil,
                    discardReason: { if case .staleToken = landing { return "staleToken" }; return "skipped" }(),
                    pid: pid, bundleID: apps[pid]?.bundleIdentifier, context: nil, firstHiddenAgeMs: nil
                )
            }
        }
        switch landing {
        case .staleToken:
            return
        case .skipped:
            break
        case .reconciled(let seatsChanged):
            let onScreenChanged = request.source == .frontmostPoll
                && cgSnapshot.onScreenWindowIDs != lastOnScreenCGIDs
            if seatsChanged || onScreenChanged {
                rebuildSnapshot(onScreenCGIDs: cgSnapshot.onScreenWindowIDs)
            }
        }
        consumeTrailingEventRead(pid: pid)
        armAbsenceProbes(pid: pid)
    }

    private func consumeTrailingEventRead(pid: pid_t) {
        if let trailingSource = trailingEventSources.removeValue(forKey: pid), apps[pid] != nil {
            scheduleEventRead(pid: pid, source: trailingSource)
        }
    }

    // MARK: - Reconcile

    private func startReconcileTimer() {
        reconcileTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reconcile() }
        }
        reconcileTimer?.tolerance = 0.5
    }

    // Foreground fast polling: for native tab groups (e.g. Ghostty), AX may not report a tab switch at all, and min reports lag by several seconds.
    // The truth is in the CG on-screen set -- it changes immediately on a tab switch. Check the frontmost app every 0.5s: if on-screen changed
    //(a tab switched), rebuild, and the tab group's visible tab updates instantly. It also incidentally tops up AX title/focus. When the frontmost app is untracked,
    // the whole tick exits immediately (so unattended measurement may go inactive for the whole stretch -- each arm must record and pin the frontmost app).
    // On a quiet tick the CG full table is reused under the CGSnapshotReuseDecision gate; AX reads proceed as usual.
    private func startFrontmostPollTimer() {
        frontmostPollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.pollFrontmostApp() }
        }
        frontmostPollTimer?.tolerance = 0.05
    }

    private func currentFrontmostPID() -> pid_t? {
        guard frontmostCacheEnabled else {
            return NSWorkspace.shared.frontmostApplication?.processIdentifier
        }
        if let cached = cachedFrontmostPID { return cached }
        let live = NSWorkspace.shared.frontmostApplication?.processIdentifier
        cachedFrontmostPID = live
        return live
    }

    /// Real query self-heal once every 5s (called in the reconcile tick). When live is nil (transient, no frontmost app), keep the old value.
    private func refreshFrontmostCache() {
        guard frontmostCacheEnabled else { return }
        if let live = NSWorkspace.shared.frontmostApplication?.processIdentifier {
            cachedFrontmostPID = live
        }
    }

    private func pollFrontmostApp() {
        guard AXIsProcessTrusted() else { return }
        guard let pid = currentFrontmostPID(), apps[pid] != nil else { return }

        scheduleFrontmostPoll(pid: pid)
    }

    private func scheduleFrontmostPoll(pid: pid_t) {
        guard apps[pid] != nil else { return }

        // Keep the 0.5s cadence, but never perform the full AXWindows read on the main actor.
        // Slow frontmost apps previously blocked SwiftUI animation for 200-400ms every tick.
        if eventAXAsyncEnabled {
            scheduleEventRead(pid: pid, source: .frontmostPoll)
            return
        }

        // Under the single-seat model: switching tabs in a tabbed window = the seat's activeCgID being replaced, and reconcileSeats converges immediately.
        // The frontmost app runs once every 0.5s, so tab switch / minimize / tear-out are reflected within a second (no longer relying on AX event reliability).
        let cgSnapshot = cgSnapshotProvider()
        var changed = reconcileSeats(pid: pid, cgSnapshot: cgSnapshot, now: Date(), source: .frontmostPoll)
        // Also force a refresh when on-screen changed (a tab switched), covering the edge case where the seat fingerprint is unchanged but the visible tab changed.
        let onScreen = cgSnapshot.onScreenWindowIDs
        if onScreen != lastOnScreenCGIDs { changed = true }
        if changed { rebuildSnapshot(onScreenCGIDs: onScreen) }
    }

    private func reconcile() {
        guard AXIsProcessTrusted() else { return }
        purgeStaleTombstones()
        refreshFrontmostCache()
        let now = Date()
        var changed = false

        // Remove entries for processes that no longer exist. This handles multi-process apps where
        // didTerminateApplicationNotification fires for the host pid while the window was tracked
        // under a different pid — the workspace notification removes the wrong entry and the
        // tracked pid's app entry stays indefinitely.
        var deadPIDs: [pid_t] = []
        for pid in appOrder {
            if !processProvider.isAlive(pid: pid) {
                // Finder's entry is intentionally kept alive across quit/relaunch cycles
                // (handleAppTerminated clears windows but preserves the slot).
                if FinderWindowRules.isFinder(bundleIdentifier: apps[pid]?.bundleIdentifier) { continue }
                deadPIDs.append(pid)
                logger.info("reconcile: pid=\(pid) no longer exists (POSIX kill(0) == ESRCH), removing stale entry")
            }
        }
        for pid in deadPIDs {
            // Before bulk-deleting AppEntry, write one seatReleased(.processGone) for each seat per windowOrder.
            // This path has no AX/CG sample from this round and no InventoryReconcileContext -- only the seat state already in memory,
            // and unsampled fields are never faked as 0/false. The log identity uses the stable pid + seatToken.
            if let app = apps[pid] { recordProcessGoneSeats(app: app) }
            observers[pid]?.stop()
            observers.removeValue(forKey: pid)
            apps.removeValue(forKey: pid)
            appOrder.removeAll { $0 == pid }
            clearInventoryDiagnostics(pid: pid)
            gateStates.removeValue(forKey: pid)
            cancelAbsenceProbeTimer(pid: pid)
            invalidateEventReads(pid: pid)
            elementCache.removeAll(pid: pid)
            changed = true
        }

        // Snapshot CG window state once for the entire reconcile pass.
        let cgSnapshot = cgSnapshotProvider()
        // Multi-display item 4: all visible seats switch displays by this round's CG bounds (pids whose read was skipped are covered too).
        if !cgSnapshot.captureFailed, refreshDisplayAttributionFromCG(cgSnapshot) { changed = true }

        if let timeout = periodicReconcileTimeout, eventAXAsyncEnabled {
            // Deletions from the dead-process sweep go on screen immediately, without waiting for the batch read to land.
            if changed { rebuildSnapshot(onScreenCGIDs: cgSnapshot.onScreenWindowIDs) }
            // Due absence probes ride single-pid reads; the batch then skips those pids (in flight).
            for pid in appOrder where pendingEventReads[pid] == nil && hasDueAbsenceProbe(pid: pid) {
                scheduleEventRead(pid: pid, source: .absenceProbe)
            }
            schedulePeriodicBatchRead(cgSnapshot: cgSnapshot, timeout: timeout)
        } else {
            // Old path (DOCK_RECONCILE_AX_TIMEOUT_MS=0 or DOCK_EVENT_AX_ASYNC=0): main-thread, per-pid, unlimited synchronous reads.
            for pid in appOrder {
                if reconcileSeats(pid: pid, cgSnapshot: cgSnapshot, now: now, source: .periodicReconcile) { changed = true }
            }
            if changed { rebuildSnapshot(onScreenCGIDs: cgSnapshot.onScreenWindowIDs) }
        }
        scanNonAdmittedApps(cgSnapshot: cgSnapshot)
    }

    /// Batch background read for periodic reconcile: pids that already have an in-flight read are skipped (their landing brings updated data), the rest register
    /// pending tokens in a batch and are then read serially with a time limit inside **one** detached task, landing as one batch with at most one rebuild.
    /// AX events arriving while the batch read is in flight still merge into trailing as usual (one in-flight per pid is unchanged); in the next tick,
    /// pids that haven't landed yet are skipped because pending exists, so they naturally don't pile up.
    private func schedulePeriodicBatchRead(cgSnapshot: AppTrackerCGWindowSnapshot, timeout: TimeInterval) {
        var batch: [(pid: pid_t, request: PendingEventRead)] = []
        for pid in appOrder {
            guard pendingEventReads[pid] == nil, let app = apps[pid] else { continue }
            if reconcileSkipEnabled, shouldSkipPeriodicRead(pid: pid, app: app, cgSnapshot: cgSnapshot) {
                continue
            }
            nextEventReadToken &+= 1
            let request = PendingEventRead(
                token: nextEventReadToken,
                mutationGeneration: mutationGenerations[pid, default: 0],
                identity: processIdentity(pid: pid, bundleID: app.bundleIdentifier),
                source: .periodicReconcile
            )
            pendingEventReads[pid] = request
            batch.append((pid, request))
        }
        guard !batch.isEmpty else { return }
        let reader = self.reader

        Task.detached { [weak self] in
            var results: [(pid: pid_t, request: PendingEventRead, result: AXWindowReadResult)] = []
            for entry in batch {
                results.append((
                    entry.pid,
                    entry.request,
                    reader.inventoryWindows(forPID: entry.pid, messagingTimeout: timeout)
                ))
            }
            let landed = results
            await MainActor.run { [weak self] in
                self?.completePeriodicBatch(landed, cgSnapshot: cgSnapshot)
            }
        }
    }

    /// Silent skip-read decision (pure decision: PeriodicReconcileSkipDecision; all eight conditions must pass to skip).
    /// Skipping = no AX read is scheduled for that pid this round; all state stays un-advanced (same semantics as `.unread`).
    private func shouldSkipPeriodicRead(
        pid: pid_t,
        app: AppEntry,
        cgSnapshot: AppTrackerCGWindowSnapshot
    ) -> Bool {
        let gate = gateStates[pid]
        let input = PeriodicReconcileSkipDecision.Input(
            captureFailed: cgSnapshot.captureFailed,
            currentCGIDs: cgSnapshot.windowIDsByPID[pid] ?? [],
            lastObservedCGIDs: gate?.lastCGIDs,
            dirtySinceLastRead: gate?.dirty ?? true,
            hasAbsenceClock: app.windowOrder.contains { app.windowsByID[$0]?.minAbsentSince != nil },
            hasPhantomCandidate: app.windowOrder.contains { app.windowsByID[$0]?.everSeenVisible == false },
            lastReadWasUnread: gate?.lastReadWasUnread ?? true,
            lastRoundChanged: gate?.lastRoundChanged ?? true,
            observerActive: observerActive(pid: pid),
            allSeatsSubscribed: allSeatsSubscribed(pid: pid, app: app),
            uptimeSinceLastFullRead: gate.map { uptimeProvider() - $0.lastFullReadUptime } ?? .infinity,
            seatOnScreenChanged: absentSeatReleaseEnabled && gate.map {
                $0.lastSeatOnScreenIDs != Set(app.windowOrder).intersection(cgSnapshot.onScreenWindowIDs)
            } ?? false
        )
        return PeriodicReconcileSkipDecision.verdict(input) == .skip
    }

    /// Periodic skipping assumes AX events cover the pid; a seat whose subscription is incomplete
    /// breaks that assumption. No observer (tests, or no Accessibility trust) keeps today's answer.
    private func allSeatsSubscribed(pid: pid_t, app: AppEntry) -> Bool {
        guard let observer = observers[pid], observer.isActive else { return true }
        return app.windowOrder.allSatisfy { observer.isCovered(cgWindowID: $0) }
    }

    private func observerActive(pid: pid_t) -> Bool {
        #if DEBUG
        if let override = observerActiveOverridesForTesting[pid] { return override }
        #endif
        return observers[pid]?.isActive ?? false
    }

    private func completePeriodicBatch(
        _ results: [(pid: pid_t, request: PendingEventRead, result: AXWindowReadResult)],
        cgSnapshot: AppTrackerCGWindowSnapshot
    ) {
        var changed = false
        var landedPIDs: [pid_t] = []
        for entry in results {
            switch landEventRead(pid: entry.pid, request: entry.request, result: entry.result, cgSnapshot: cgSnapshot) {
            case .staleToken:
                continue
            case .skipped:
                landedPIDs.append(entry.pid)
            case .reconciled(let seatsChanged):
                if seatsChanged { changed = true }
                landedPIDs.append(entry.pid)
            }
        }
        if changed { rebuildSnapshot(onScreenCGIDs: cgSnapshot.onScreenWindowIDs) }
        for pid in landedPIDs {
            consumeTrailingEventRead(pid: pid)
            armAbsenceProbes(pid: pid)
        }
    }

    /// `cgSnapshot`: the reconcile tick passes in this round's CG capture -> goes through the probe gate (CG presence criterion + memo) and
    /// reuses that capture for adoption; pass nil (the four supplementary scans after launch) -> bypasses the gate and memo entirely, and adoption takes its own snapshot --
    /// bit-for-bit identical to before the change.
    private func scanNonAdmittedApps(cgSnapshot: AppTrackerCGWindowSnapshot? = nil) {
        guard !isScanningCandidates else { return }
        var slowFullScanDue = false
        if cgSnapshot != nil, scanGateEnabled {
            let uptime = uptimeProvider()
            slowFullScanDue = lastFullScanUptime.map {
                uptime - $0 >= ScanProbeGateDecision.defaultFullScanInterval
            } ?? true
            if slowFullScanDue {
                lastFullScanUptime = uptime
                // Catches a process that was seatless when it left `.regular` (no seat release
                // to trigger the event-driven check) — one policy read per seatless entry per 60s.
                sweepNonRegularZeroSeatEntries()
            }
        }
        // The candidate travels with the **process generation at probe time**: a pid may be reused during the background probe, and the callback must be able to tell it changed hands.
        let candidates: [(pid: pid_t, identity: ScanAdmissionDecision.ProcessIdentity)]
        if let cgSnapshot, scanGateEnabled {
            // Gate path: the candidate list comes from the cache (see the scanCandidateCache comment), and NSWorkspace is re-enumerated
            // only when it is invalid or the slow scan is due. Stale entries in the cache (adopted / dead) are cheaply filtered out each tick.
            if scanCandidateCache == nil || slowFullScanDue {
                scanCandidateCache = enumerateScanCandidates()
            }
            candidates = (scanCandidateCache ?? []).compactMap { entry in
                guard apps[entry.pid] == nil, processProvider.isAlive(pid: entry.pid) else { return nil }
                let identity = processIdentity(pid: entry.pid, bundleID: entry.bundleID)
                let verdict = ScanProbeGateDecision.verdict(.init(
                    captureFailed: cgSnapshot.captureFailed,
                    cgWindowIDs: cgSnapshot.windowIDsByPID[entry.pid] ?? [],
                    memo: scanMemos[entry.pid],
                    currentIdentity: identity,
                    workspaceDirty: scanDirtyPIDs.contains(entry.pid),
                    slowFullScanDue: slowFullScanDue
                ))
                guard case .probe = verdict else { return nil }
                scanDirtyPIDs.remove(entry.pid)
                return (entry.pid, identity)
            }
        } else {
            // Bypass (launch supplementary-scan rounds / DOCK_SCAN_GATE=0): bit-for-bit identical to before the change, with a full on-the-spot enumeration.
            candidates = NSWorkspace.shared.runningApplications.compactMap { app in
                let pid = app.processIdentifier
                guard isRegularNonSelf(app), !app.isTerminated, apps[pid] == nil else { return nil }
                scanDirtyPIDs.remove(pid)
                return (pid, processIdentity(pid: pid, bundleID: app.bundleIdentifier))
            }
        }
        guard !candidates.isEmpty else { return }

        isScanningCandidates = true
        let reader = self.reader

        Task.detached { [weak self] in
            // The background does only the AX read (time-limited to 100ms; hung apps don't drag the main thread). The eligible filter stays on the main thread: it depends on
            // the instance property eligibilityPolicy and is just pure computation over already-read fields, with zero AX round trips.
            let probeStart = DispatchTime.now().uptimeNanoseconds
            var probed: [(pid: pid_t, identity: ScanAdmissionDecision.ProcessIdentity, result: AXWindowReadResult)] = []
            for candidate in candidates {
                probed.append((
                    candidate.pid,
                    candidate.identity,
                    reader.inventoryWindows(forPID: candidate.pid, messagingTimeout: 0.1)
                ))
            }
            let results = probed
            let probeElapsed = TimeInterval(DispatchTime.now().uptimeNanoseconds - probeStart) / 1_000_000_000

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isScanningCandidates = false
                self.admitScannedApps(results, tickSnapshot: cgSnapshot, probeElapsed: probeElapsed)
            }
        }
    }

    /// One real NSWorkspace enumeration (every per-app property access is a synchronous LS XPC; don't call it on a quiet tick).
    private func enumerateScanCandidates() -> [(pid: pid_t, bundleID: String?)] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            let pid = app.processIdentifier
            guard isRegularNonSelf(app), !app.isTerminated, apps[pid] == nil else { return nil }
            return (pid, app.bundleIdentifier)
        }
    }

    /// Supplementary-scan adoption. Three hard rules (all locked by unit tests in `ScanAdmissionDecision`):
    /// admission looks at the set **after the eligible filter** (a non-empty raw AX list != a window that belongs on the taskbar; wrongly adopting leaves a permanent
    /// `app-*` card); the probe result **must be reused** (no second unlimited AX read -- that is exactly the main-thread block the 100ms
    /// time-limited probe exists to avoid); process state and process generation are **re-checked** in the main-thread callback (the pid may have been reused).
    private func admitScannedApps(
        _ probed: [(pid: pid_t, identity: ScanAdmissionDecision.ProcessIdentity, result: AXWindowReadResult)],
        tickSnapshot: AppTrackerCGWindowSnapshot? = nil,
        probeElapsed: TimeInterval = .infinity
    ) {
        guard !probed.isEmpty else { return }
        // Reuse the reconcile tick's CG capture (saves a second full table every 5 seconds). When the probe took too long (>1s, hung app
        // queue timeout) or no snapshot was passed (launch supplementary-scan rounds), take a fresh one; the generation re-check (ScanAdmissionDecision.verdict)
        // continues to backstop correctness against "the snapshot going stale instantly" -- the same existing precedent as seed using one snapshot for probe + adoption.
        let cgSnapshot: AppTrackerCGWindowSnapshot
        if let tickSnapshot, probeElapsed <= 1.0 {
            cgSnapshot = tickSnapshot
        } else {
            cgSnapshot = cgSnapshotProvider()
        }
        var admitted = false

        for entry in probed {
            guard let app = NSRunningApplication(processIdentifier: entry.pid) else {
                scanMemos.removeValue(forKey: entry.pid)
                recordAdmissionProbe(
                    source: .scan,
                    identity: entry.identity,
                    readMode: .timed,
                    messagingTimeoutMs: 100,
                    maxAttempts: 1,
                    result: entry.result,
                    eligibleWindowCount: nil,
                    verdict: .skipProcessUnavailable
                )
                continue
            }
            let bundleID = app.bundleIdentifier
            let eligibilityApplication = eligibilityApplication(for: app)

            let rawWindows: [AXWindowSnapshot]?
            let readOutcome: InventoryAXReadOutcome
            switch entry.result {
            case .success(let snaps):
                rawWindows = snaps
                readOutcome = .success(count: snaps.count)
            case .unread(let error):
                rawWindows = nil
                readOutcome = .unread(errorCode: error.rawValue)
            }

            let prepared = ScanAdmissionDecision.prepare(rawWindows: rawWindows) {
                isEligible($0, application: eligibilityApplication, cgSnapshot: cgSnapshot)
            }
            let verdict = ScanAdmissionDecision.verdict(
                prepared,
                probedIdentity: entry.identity,
                currentIdentity: processIdentity(pid: entry.pid, bundleID: bundleID),
                isRegularNonSelf: isRegularNonSelf(app),
                isTerminated: app.isTerminated,
                alreadyTracked: apps[entry.pid] != nil
            )
            recordAdmissionProbe(
                source: .scan,
                identity: entry.identity,
                readMode: .timed,
                messagingTimeoutMs: 100,
                maxAttempts: 1,
                result: entry.result,
                eligibleWindowCount: prepared.readFailed ? nil : prepared.eligible.count,
                verdict: inventoryAdmissionVerdict(verdict)
            )
            // The memo records only the conclusion "confirmed no eligible window" (.unread is never memoized; a hung app keeps retrying every 5s);
            // any other conclusion clears the old memo.
            if verdict == .skipNoEligible {
                scanMemos[entry.pid] = ScanProbeGateDecision.Memo(
                    identity: entry.identity,
                    lastCGIDs: cgSnapshot.windowIDsByPID[entry.pid] ?? [],
                    verdictWasNoEligible: true
                )
            } else {
                scanMemos.removeValue(forKey: entry.pid)
            }
            guard verdict == .admit else { continue }

            admit(app: app, prepared: prepared, readOutcome: readOutcome, cgSnapshot: cgSnapshot)
            admitted = true
        }

        if admitted { rebuildSnapshot(onScreenCGIDs: cgSnapshot.onScreenWindowIDs) }
    }

    /// Land one supplementary-scan adoption. Accepts only `Prepared` -- the raw AX list never enters this scope, which structurally rules out
    /// feeding an unfiltered array to `reconcileSeats`.
    private func admit(
        app: NSRunningApplication,
        prepared: ScanAdmissionDecision.Prepared<AXWindowSnapshot>,
        readOutcome: InventoryAXReadOutcome,
        cgSnapshot: AppTrackerCGWindowSnapshot
    ) {
        let pid = app.processIdentifier
        addApp(app, enumerateImmediately: false)
        reconcileSeats(
            pid: pid,
            cgSnapshot: cgSnapshot,
            now: Date(),
            source: .initialEnumeration,
            preloadedEligible: prepared.eligible,
            preloadedReadOutcome: readOutcome,
            preloadedReadMode: .timed
        )
        logger.info("scan: admitted pid=\(pid) (\(app.localizedName ?? app.bundleIdentifier ?? "?"))")
    }

    private func processIdentity(pid: pid_t, bundleID: String?) -> ScanAdmissionDecision.ProcessIdentity {
        processProvider.identity(pid: pid, bundleID: bundleID)
    }

    private func recordAdmissionProbe(
        source: InventoryAdmissionProbeSource,
        identity: ScanAdmissionDecision.ProcessIdentity,
        readMode: InventoryAdmissionReadMode,
        messagingTimeoutMs: Int?,
        maxAttempts: Int,
        result: AXWindowReadResult,
        eligibleWindowCount: Int?,
        verdict: InventoryAdmissionProbeVerdict
    ) {
        guard inventoryLog.isEnabled else { return }
        let readResult: InventoryAdmissionProbeReadResult
        let errorCode: Int32?
        let rawWindowCount: Int?
        switch result {
        case .success(let windows):
            readResult = .success
            errorCode = nil
            rawWindowCount = windows.count
        case .unread(let error):
            readResult = .unread
            errorCode = error.rawValue
            rawWindowCount = nil
        }
        inventoryLog.record(.admissionProbe(InventoryAdmissionProbePayload(
            source: source,
            pid: identity.pid,
            bundleID: identity.bundleID,
            processStartTimeSec: identity.startTimeSec,
            processStartTimeUsec: identity.startTimeUsec,
            readMode: readMode,
            messagingTimeoutMs: messagingTimeoutMs,
            maxAttempts: maxAttempts,
            readResult: readResult,
            errorCode: errorCode,
            rawWindowCount: rawWindowCount,
            eligibleWindowCount: eligibleWindowCount,
            verdict: verdict
        )))
    }

    private func inventoryAdmissionVerdict(
        _ verdict: ScanAdmissionDecision.Verdict
    ) -> InventoryAdmissionProbeVerdict {
        switch verdict {
        case .admit: return .admit
        case .skipNotRegular: return .skipNotRegular
        case .skipTerminated: return .skipTerminated
        case .skipAlreadyTracked: return .skipAlreadyTracked
        case .skipIdentityMismatch: return .skipIdentityMismatch
        case .skipUnread: return .skipUnread
        case .skipNoEligible: return .skipNoEligible
        }
    }

    // MARK: - Snapshot Building

    private func rebuildSnapshot(onScreenCGIDs: Set<CGWindowID>? = nil) {
        // Read frontmost PID once; passed to windowStatus to determine active highlight
        let frontmostPID = currentFrontmostPID()
        lastOnScreenCGIDs = onScreenCGIDs ?? onScreenWindowIDsProvider()

        var windows: [WindowID: WindowRecord] = [:]
        var orderedWindowIDs: [WindowID] = []
        let fallbackByPID = Dictionary(uniqueKeysWithValues: AppFallbackChipDecision.fallbacks(
            for: appOrder.compactMap { pid in
                apps[pid].map { app in
                    AppFallbackChipDecision.Process(
                        pid: pid,
                        bundleID: app.bundleIdentifier,
                        appName: app.appName,
                        hasSeats: !app.windowOrder.isEmpty,
                        isFrontmost: pid == frontmostPID
                    )
                }
            }
        ).map { ($0.pid, $0) })

        // Remember where each app's windows last were: follow the first seat with an ownership key when seats exist; keep as is when there are none.
        for pid in appOrder {
            guard let app = apps[pid],
                  let home = app.windowOrder.compactMap({ app.windowsByID[$0]?.displayUUID }).first,
                  home != app.lastWindowDisplayUUID else { continue }
            apps[pid]?.lastWindowDisplayUUID = home
        }

        for pid in appOrder {
            guard let app = apps[pid] else { continue }

            if app.windowOrder.isEmpty {
                guard let fallback = fallbackByPID[pid] else { continue }
                let id = WindowID(rawValue: fallback.windowID)
                windows[id] = WindowRecord(
                    id: id,
                    appID: AppID(rawValue: app.bundleIdentifier ?? app.appName),
                    pid: pid,
                    bundleIdentifier: app.bundleIdentifier,
                    title: app.appName,
                    bounds: nil,
                    status: app.isHidden ? .hidden : .inactive,
                    isOnDesktop: pid == frontmostPID,
                    groupID: id.rawValue,   // fallback card forms its own group, never merged into another
                    displayUUID: app.lastWindowDisplayUUID
                )
                orderedWindowIDs.append(id)
            } else {
                // Single-seat model: one seat = one physical window = one card. Card stable identity = seat token (does not change with the
                // current tab's cgID); action target = current activeCgID. Visibility uses seat state directly (when the current tab
                // leaves AX it is replaced by the new tab, so no stale min remains; a truly minimized seat is marked isMinimized).
                for cgID in app.windowOrder {
                    guard let seat = app.windowsByID[cgID] else { continue }
                    let id = WindowID(rawValue: "cgw-\(cgID)")
                    windows[id] = WindowRecord(
                        id: id,
                        appID: AppID(rawValue: app.bundleIdentifier ?? app.appName),
                        pid: pid,
                        bundleIdentifier: app.bundleIdentifier,
                        title: seat.title,
                        bounds: seat.bounds,
                        status: windowStatus(isHidden: app.isHidden, isMinimized: seat.isMinimized, isFocused: seat.isFocused, pid: pid, frontmostPID: frontmostPID),
                        cgWindowID: cgID,
                        isOnDesktop: !seat.isMinimized && !app.isHidden,
                        groupID: seat.token,
                        displayUUID: seat.displayUUID
                    )
                    orderedWindowIDs.append(id)
                }
            }
        }

        let next = DockSnapshot(windows: windows, orderedWindowIDs: orderedWindowIDs)
        guard next != snapshot else { return }
        snapshot = next
    }

    private func windowStatus(isHidden: Bool, isMinimized: Bool, isFocused: Bool, pid: pid_t, frontmostPID: pid_t?) -> WindowStatus {
        if isHidden { return .hidden }
        if isMinimized { return .minimized }
        if isFocused && pid == frontmostPID { return .active }
        return .inactive
    }

    private func isRegularNonSelf(_ app: NSRunningApplication) -> Bool {
        app.activationPolicy == .regular &&
        app.bundleIdentifier != DockWindowEligibilityPolicy.selfBundleIdentifier
    }

    #if DEBUG
    // MARK: - Deterministic inventory fixtures

    func installFixtureForTesting(_ app: AppEntry) {
        apps[app.pid] = app
        if !appOrder.contains(app.pid) { appOrder.append(app.pid) }
        mutationGenerations[app.pid, default: 0] &+= 1
    }

    func fixtureAppForTesting(pid: pid_t) -> AppEntry? {
        apps[pid]
    }

    @discardableResult
    func reconcileFixtureForTesting(
        pid: pid_t,
        cgSnapshot: AppTrackerCGWindowSnapshot,
        now: Date,
        eligible: [AXWindowSnapshot],
        readOutcome: InventoryAXReadOutcome,
        readMode: InventoryReconcileReadMode = .timed,
        rawAXCgIDs: Set<CGWindowID>? = nil,
        absenceEvidence: [CGWindowID: AbsentSeatProbeEvidence] = [:]
    ) -> Bool {
        reconcileSeats(
            pid: pid,
            cgSnapshot: cgSnapshot,
            now: now,
            source: .periodicReconcile,
            preloadedEligible: eligible,
            preloadedReadOutcome: readOutcome,
            preloadedReadMode: readMode,
            rawAXCgIDs: rawAXCgIDs,
            absenceEvidence: absenceEvidence
        )
    }

    #if DEBUG
    func setSubscribedElementForTesting(pid: pid_t, cgWindowID: CGWindowID, element: AXUIElement?, instanceID: UInt64) {
        var overrides = subscribedElementOverridesForTesting[pid] ?? [:]
        overrides[cgWindowID] = element.map { ($0, instanceID) }
        subscribedElementOverridesForTesting[pid] = overrides
    }

    func takeDueAbsenceProbesForTesting(pid: pid_t) -> [AbsentSeatProbeRequest] {
        takeDueAbsenceProbes(pid: pid)
    }

    func clearFirstHiddenMarksViaHideForTesting(pid: pid_t) {
        handleAppHidden(pid: pid)
    }

    var absenceProbeTimerPIDsForTesting: Set<pid_t> { Set(absenceProbeTimers.keys) }
    #endif

    func scheduleEventReadForTesting(pid: pid_t, source: InventoryReconcileSource) {
        scheduleEventRead(pid: pid, source: source)
    }

    func scheduleFrontmostPollForTesting(pid: pid_t) {
        scheduleFrontmostPoll(pid: pid)
    }

    func minimizeForTesting(pid: pid_t, cgWindowID: CGWindowID) {
        handleWindowMinimized(pid: pid, cgWindowID: cgWindowID)
    }

    func destroyForTesting(pid: pid_t, cgWindowID: CGWindowID) {
        handleWindowDestroyed(pid: pid, cgWindowID: cgWindowID)
    }

    func rebuildSnapshotForTesting(onScreenCGIDs: Set<CGWindowID> = []) {
        rebuildSnapshot(onScreenCGIDs: onScreenCGIDs)
    }

    @discardableResult
    func refreshDisplayAttributionFromCGForTesting(cgSnapshot: AppTrackerCGWindowSnapshot) -> Bool {
        refreshDisplayAttributionFromCG(cgSnapshot)
    }

    func screenParametersChangedForTesting() {
        handleScreenParametersChanged()
    }

    func hasPendingEventReadForTesting(pid: pid_t) -> Bool {
        pendingEventReads[pid] != nil || trailingEventSources[pid] != nil
    }

    func setFrontmostPIDForTesting(_ pid: pid_t?) {
        cachedFrontmostPID = pid
    }

    /// Cache state for CG reuse gating (non-nil after a fresh landing).
    func cgSnapshotCacheForTesting() -> (probeIDs: Set<CGWindowID>, atUptime: TimeInterval)? {
        guard cachedCGSnapshot != nil, let probe = cachedCGProbeIDs else { return nil }
        return (probe, cachedCGAtUptime)
    }

    func bumpCGEventGenerationForTesting() {
        cgEventGeneration &+= 1
    }

    func setObserverActiveForTesting(pid: pid_t, active: Bool) {
        observerActiveOverridesForTesting[pid] = active
    }

    @discardableResult
    func evictIfNonRegularForTesting(pid: pid_t) -> NonRegularEvictionDecision.Verdict {
        evictIfNonRegular(pid: pid)
    }

    func sweepNonRegularZeroSeatEntriesForTesting() {
        sweepNonRegularZeroSeatEntries()
    }

    func runPeriodicBatchForTesting(
        cgSnapshot: AppTrackerCGWindowSnapshot,
        timeoutOverride: TimeInterval? = nil
    ) {
        schedulePeriodicBatchRead(
            cgSnapshot: cgSnapshot,
            timeout: timeoutOverride ?? periodicReconcileTimeout ?? 0.1
        )
    }
    #endif
}
