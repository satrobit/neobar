import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import os

private let windowLiftAXMessagingTimeout: TimeInterval = 0.1

struct WindowLiftCGCandidate: Equatable {
    let key: WindowLiftAvoidance.WindowKey
    let quartzFrame: CGRect
}

struct WindowLiftCGScanResult {
    /// Foreground large-window candidate for each screen (by index into the passed `screenCGFrames`); screens without one are not in the dictionary.
    let candidatesByScreenIndex: [Int: WindowLiftCGCandidate]
    let onScreenFrames: [WindowLiftAvoidance.WindowKey: CGRect]
    let liveWindowKeys: Set<WindowLiftAvoidance.WindowKey>?
}

/// Avoidance host: provides the geometry of "which screens have a resident, visible taskbar", one per screen (aggregated from the units by the orchestration layer under ③④).
@MainActor
protocol WindowLiftAvoidanceHost: AnyObject {
    func windowLiftAvoidanceContexts() -> [WindowLiftAvoidanceContext]
}

enum WindowLiftCGWindowProbe {
    static func frontmostLargeWindow(
        on screenCGFrame: CGRect,
        excludingPID selfPID: pid_t
    ) -> WindowLiftCGCandidate? {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }
        return frontmostLargeWindow(in: list, on: screenCGFrame, excludingPID: selfPID)
    }

    static func capture(
        on contexts: [WindowLiftAvoidanceContext],
        excludingPID selfPID: pid_t,
        includeLiveWindowKeys: Bool,
        includesTiles: Bool,
        trackedKeys: Set<WindowLiftAvoidance.WindowKey>
    ) -> WindowLiftCGScanResult {
        let onScreenList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []

        var onScreenFrames: [WindowLiftAvoidance.WindowKey: CGRect] = [:]
        for info in onScreenList {
            guard let key = windowKey(in: info),
                  let bounds = windowBounds(in: info) else { continue }
            onScreenFrames[key] = bounds
        }

        let liveWindowKeys: Set<WindowLiftAvoidance.WindowKey>?
        if includeLiveWindowKeys,
           let fullList = CGWindowListCopyWindowInfo(
               [.optionAll, .excludeDesktopElements],
               kCGNullWindowID
           ) as? [[String: Any]] {
            liveWindowKeys = Set(fullList.compactMap(windowKey(in:)))
        } else {
            liveWindowKeys = nil
        }

        // One CG list, filtered once per screen. The lift scan has its own gate
        // (`WindowLiftAvoidance.isLiftCandidate`); `frontmostLargeWindow` below stays the
        // fullscreen probe's 0.7-only filter.
        var candidates: [Int: WindowLiftCGCandidate] = [:]
        for (index, context) in contexts.enumerated() {
            if let candidate = frontmostLiftCandidate(
                in: onScreenList,
                context: context,
                excludingPID: selfPID,
                includesTiles: includesTiles,
                trackedKeys: trackedKeys
            ) {
                candidates[index] = candidate
            }
        }
        return WindowLiftCGScanResult(
            candidatesByScreenIndex: candidates,
            onScreenFrames: onScreenFrames,
            liveWindowKeys: liveWindowKeys
        )
    }

    static func liveWindowKeys() -> Set<WindowLiftAvoidance.WindowKey>? {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }
        return Set(list.compactMap(windowKey(in:)))
    }

    static func frames(
        for keys: Set<WindowLiftAvoidance.WindowKey>
    ) -> [WindowLiftAvoidance.WindowKey: CGRect] {
        guard !keys.isEmpty else { return [:] }

        var frames: [WindowLiftAvoidance.WindowKey: CGRect] = [:]
        for key in keys {
            guard let list = CGWindowListCopyWindowInfo(
                [.optionOnScreenAboveWindow, .optionIncludingWindow, .excludeDesktopElements],
                key.cgWindowID
            ) as? [[String: Any]],
                  let info = list.first(where: { windowKey(in: $0) == key }),
                  let bounds = windowBounds(in: info) else {
                continue
            }
            frames[key] = bounds
        }
        return frames
    }

    static func frame(for key: WindowLiftAvoidance.WindowKey) -> CGRect? {
        frames(for: [key])[key]
    }

    private static func frontmostLargeWindow(
        in list: [[String: Any]],
        on screenCGFrame: CGRect,
        excludingPID selfPID: pid_t
    ) -> WindowLiftCGCandidate? {
        for info in list {
            guard number(in: info, key: kCGWindowLayer)?.intValue == 0,
                  let key = windowKey(in: info),
                  key.pid != selfPID,
                  let bounds = windowBounds(in: info),
                  bounds.intersects(screenCGFrame),
                  bounds.width > screenCGFrame.width * 0.7,
                  bounds.width >= 80,
                  bounds.height >= 40,
                  (number(in: info, key: kCGWindowAlpha)?.doubleValue ?? 1) > 0 else {
                continue
            }
            return WindowLiftCGCandidate(key: key, quartzFrame: bounds)
        }
        return nil
    }

    private static func frontmostLiftCandidate(
        in list: [[String: Any]],
        context: WindowLiftAvoidanceContext,
        excludingPID selfPID: pid_t,
        includesTiles: Bool,
        trackedKeys: Set<WindowLiftAvoidance.WindowKey>
    ) -> WindowLiftCGCandidate? {
        for info in list {
            guard number(in: info, key: kCGWindowLayer)?.intValue == 0,
                  let key = windowKey(in: info),
                  key.pid != selfPID,
                  let bounds = windowBounds(in: info),
                  bounds.intersects(context.screenCGFrame),
                  bounds.width >= 80,
                  bounds.height >= 40,
                  (number(in: info, key: kCGWindowAlpha)?.doubleValue ?? 1) > 0,
                  WindowLiftAvoidance.isLiftCandidate(
                      quartzFrame: bounds,
                      isTracked: trackedKeys.contains(key),
                      context: context,
                      includesTiles: includesTiles
                  ) else {
                continue
            }
            return WindowLiftCGCandidate(key: key, quartzFrame: bounds)
        }
        return nil
    }

    private static func windowKey(in info: [String: Any]) -> WindowLiftAvoidance.WindowKey? {
        guard let pid = number(in: info, key: kCGWindowOwnerPID)?.int32Value,
              let windowID = number(in: info, key: kCGWindowNumber)?.uint32Value,
              windowID != 0 else {
            return nil
        }
        return WindowLiftAvoidance.WindowKey(pid: pid, cgWindowID: windowID)
    }

    private static func windowBounds(in info: [String: Any]) -> CGRect? {
        guard let dictionary = info[kCGWindowBounds as String] as? [String: Any] else {
            return nil
        }
        return CGRect(dictionaryRepresentation: dictionary as CFDictionary)
    }

    private static func number(in info: [String: Any], key: CFString) -> NSNumber? {
        info[key as String] as? NSNumber
    }
}

@MainActor
final class WindowLiftAvoidanceController {
    private struct ManagedFrames {
        let nativeAppKit: CGRect
        let targetAppKit: CGRect
        let nativeQuartz: CGRect
        let targetQuartz: CGRect
        let primaryScreenHeight: CGFloat
        /// Set only on a user-zoom-toggle restore: the remembered pre-maximize frame to write
        /// instead of `nativeQuartz`.
        var userRestoreQuartz: CGRect? = nil
    }

    private enum ValidationStage: String {
        case candidateMoved
        case handleUnavailable
        case roleUnavailable
        case unsupportedRole
        case fullscreen
        case minimized
        case frameUnavailable
        case frameMismatch
        case capabilityUnavailable
        case sizeNotSettable
    }

    private enum ValidationOutcome {
        case ready(AXWindowHandle)
        case transient(ValidationStage)
        case unsupported(ValidationStage)
    }

    private struct WriteAnomaly {
        let reason: AXWindowFrameWriteFailure
        let rollback: AXWindowFrameRollbackResult
        let decision: WindowLiftAvoidance.AnimationWriteFailureDecision
        let progress: Double
    }

    /// What `clearManagedSession` leaves behind for the window it clears.
    private enum SuppressionRequest {
        case none
        /// Hold the window until its native frame reappears; `userEra` additionally lets a new
        /// eligible frame release it (`Geometry.suppressionReleasesOnNewFrame`).
        case untilNative(userEra: Bool)
    }

    private enum OperationOutcome {
        case completed(CGRect, reliftCount: Int, anomalies: [WriteAnomaly])
        case externalFrame(CGRect, anomalies: [WriteAnomaly])
        case reliftLimitReached(CGRect, reliftCount: Int, anomalies: [WriteAnomaly])
        case failed(
            reason: AXWindowFrameWriteFailure,
            rollback: AXWindowFrameRollbackResult,
            progress: Double,
            reliftCount: Int,
            anomalies: [WriteAnomaly]
        )
        case transientValidation(ValidationStage)
        case unsupportedValidation(ValidationStage)
        case cancelled
    }

    private static let trackedProbeInterval = WindowLiftAvoidance.trackedSessionProbeInterval
    /// For the static restore path, which cannot reach the instance logger.
    private static let restoreLogger = Logger(
        subsystem: "app.neobar.NeoBar",
        category: "WindowLiftAvoidance"
    )

    private weak var host: WindowLiftAvoidanceHost?
    private let logger = Logger(
        subsystem: "app.neobar.NeoBar",
        category: "WindowLiftAvoidance"
    )
    private var pollTimer: Timer?
    private var pollTimerInterval: TimeInterval?
    private var eventPollTimer: Timer?
    private var eventPollCoalescer = WindowLiftAvoidance.EventPollCoalescer()
    private var scanTask: Task<Void, Never>?
    private var trackedProbeTimer: Timer?
    private var trackedProbeTask: Task<Void, Never>?
    private var restoreTask: Task<Void, Never>?
    private var writeTasks: [WindowLiftAvoidance.WindowKey: Task<Void, Never>] = [:]
    private var writeDrainTasks: [
        WindowLiftAvoidance.WindowKey: [Task<Void, Never>]
    ] = [:]
    private var workspaceObservers: [NSObjectProtocol] = []
    private var geometryObserver: FrontmostWindowGeometryObserver?
    private var states: [WindowLiftAvoidance.WindowKey: WindowLiftAvoidance.SessionState] = [:]
    private var managedFrames: [WindowLiftAvoidance.WindowKey: ManagedFrames] = [:]
    private var suppressedFrames: [WindowLiftAvoidance.WindowKey: ManagedFrames] = [:]
    /// Suppressed keys whose session was cleared by a user-era external frame
    /// (`WindowLiftAvoidance.externalFrameIsUserEra`). Always a subset of `suppressedFrames.keys`:
    /// written only through `setSuppression` / `clearSuppression` / `clearAllSuppressions`.
    private var userEraSuppressedKeys: Set<WindowLiftAvoidance.WindowKey> = []
    private var observationWatermarks: [WindowLiftAvoidance.WindowKey: UInt64] = [:]
    private var validationGenerations: [WindowLiftAvoidance.WindowKey: UInt64] = [:]
    private var lastTraceClassifications: [
        WindowLiftAvoidance.WindowKey: WindowLiftAvoidance.FrameClassification
    ] = [:]
    /// The context set the host provided last time (one per screen). A change in the set = restore all lifted windows and rescan (a generalization of today's screen-change behavior).
    private var lastContexts: [WindowLiftAvoidanceContext] = []
    /// The context of the screen each session belongs to (sessions are on different screens in multi-screen setups). Added/removed along with `states`, and handled per session during probing.
    private var sessionContexts: [WindowLiftAvoidance.WindowKey: WindowLiftAvoidanceContext] = [:]
    /// Each on-screen window's last settled non-eligible frame — what the system zoom's undo would
    /// return to, had our lift not poisoned it. Fed by every scan, used by `restoreUserFrame`.
    private var userFrames: [WindowLiftAvoidance.WindowKey: WindowLiftAvoidance.UserFrameMemory] = [:]
    private var clickSampler = WindowLiftAvoidance.ClickCounterSampler()
    private var lastDoubleClick: WindowLiftAvoidance.DoubleClick?
    private var nextGeneration: UInt64 = 0
    private var scanGeneration: UInt64 = 0
    private var trackedProbeGeneration: UInt64 = 0
    private var restoreGeneration: UInt64 = 0
    private var scanInFlight = false
    private var usesAnimatedLift = false
    /// `DOCK_WINDOW_LIFT_TILES`: bottom-docked tiles lift too. Off = maximized windows only.
    private var includesTiles = false
    private var traceEnabled = false
    private var periodicPollCount: UInt64 = 0
    private var eventPollCount: UInt64 = 0
    private var trailingEventPollCount: UInt64 = 0
    private var isEnabled = false
    /// User setting (menu "Maximized windows avoid the taskbar"). **Off by default**; `AppDelegate` feeds in the
    /// persisted value once at startup and then syncs by subscription. It lives on the controller itself rather than being guarded only at the call site:
    /// `endPermissionUncertainty()` calls `start()` internally, and if only guarded outside, a single permission flap
    /// could turn a feature the user had turned off back on.
    private var isEnabledBySetting = false

    /// During freeze: only drop task references, never touch `states` / `managedFrames` / `suppressedFrames` /
    /// `pendingRestorations`. After permission is revoked AX can't write to windows, so clearing snapshots then means permanently losing the ability to restore.
    private var isPermissionFrozen = false
    private var freezeGeneration: UInt64 = 0
    /// Pending-restore windows are owned by the controller: an item is removed only after it is restored successfully. Previously this data was copied into local variables
    /// and handed to a detached task, which the new freeze mechanism could not take over if permission was lost midway.
    private var pendingRestorations: [WindowLiftAvoidance.WindowKey: ManagedFrames] = [:]
    /// Process start time at enqueue, used to detect pid reuse after a long freeze.
    private var pendingRestorationStartTimes: [WindowLiftAvoidance.WindowKey: timeval] = [:]
    /// Write tasks that were cancelled but haven't finished running. A cancelled AX call can't be interrupted midway, so they must be drained before recovery,
    /// otherwise a late rollback would overwrite the restore result.
    private var pendingDrains: [Task<Void, Never>] = []
    private let isTrustedProbe: () -> Bool

    private enum RestoreOutcome: Equatable {
        /// Already restored, or confirmed to need no restore (user moved it, window gone, pid reused).
        case handled
        /// Unreachable this round (most likely Accessibility permission isn't granted yet); keep it for the next restore attempt.
        case unreachable
    }

    init(host: WindowLiftAvoidanceHost, isTrustedProbe: @escaping () -> Bool = { AXIsProcessTrusted() }) {
        self.host = host
        self.isTrustedProbe = isTrustedProbe
    }

    // MARK: - Permission freeze

    /// Called when permission can't be read for the first time. The UI hasn't changed at all yet, but snapshots must be locked immediately.
    func beginPermissionUncertainty() {
        enterFreeze(reason: "permissionUncertain")
    }

    /// False-alarm path: permission can be read again. **Tiered unfreeze** -- first drain the old writer, bump the generation to reject late callbacks,
    /// converge the frozen sessions according to the current situation, and only then resume polling. Directly clearing the freeze flag would leave a `.writing` session
    /// whose writer is dead but which never re-issues writes (the pure reducer only
    /// updates the generation on later observations), and that window would never move again.
    func endPermissionUncertainty() {
        guard isPermissionFrozen else { return }
        freezeGeneration &+= 1
        let generation = freezeGeneration
        let drains = pendingDrains
        pendingDrains.removeAll()

        Task { @MainActor [weak self] in
            for task in drains { await task.value }
            guard let self, self.freezeGeneration == generation, self.isPermissionFrozen else { return }
            self.isPermissionFrozen = false
            self.convergeFrozenSessions()
            self.start()
        }
    }

    /// Called when permission has just been restored, before the process is about to restart: drain -> unfreeze -> restore -> wait for the restore to finish.
    func restoreAndStopForPermissionRecovery() async {
        freezeGeneration &+= 1
        let drains = pendingDrains
        pendingDrains.removeAll()
        for task in drains { await task.value }

        isPermissionFrozen = false
        stop()
        while let task = restoreTask {
            await task.value
        }
    }

    private func enterFreeze(reason: String) {
        guard !isPermissionFrozen else { return }
        isPermissionFrozen = true
        // A poll() already queued on the main queue only looks at this field, so it must be turned off as well.
        isEnabled = false
        freezeGeneration &+= 1
        pollTimer?.invalidate()
        pollTimer = nil
        pollTimerInterval = nil
        resetEventPolling()
        scanGeneration &+= 1
        scanTask?.cancel()
        scanTask = nil
        scanInFlight = false
        stopTrackedProbe()
        geometryObserver?.stop()
        geometryObserver = nil
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        workspaceObservers.removeAll()

        for task in writeTasks.values {
            task.cancel()
            pendingDrains.append(task)
        }
        for tasks in writeDrainTasks.values { pendingDrains.append(contentsOf: tasks) }
        writeTasks.removeAll()
        writeDrainTasks.removeAll()

        logger.notice("""
            lift frozen reason=\(reason, privacy: .public) \
            sessions=\(self.states.count, privacy: .public) \
            pending=\(self.pendingRestorations.count, privacy: .public)
            """)
    }

    /// Unfreeze convergence: a `.writing` session whose writer has been cancelled can't finish by itself, so clear it in place.
    /// Clear with `.untilNative`, so the next round doesn't treat "the already-lifted position" as the native position and lift it again.
    private func convergeFrozenSessions() {
        let stalled = states.compactMap { key, state -> WindowLiftAvoidance.WindowKey? in
            if case .writing = state { return key }
            return nil
        }
        for key in stalled {
            clearManagedSession(
                for: key,
                cancelWriter: false,
                reason: "permissionUnfreeze",
                suppression: .untilNative(userEra: false)
            )
        }
    }

    /// During freeze, all operations that would erase session data are forbidden.
    private func canMutateSessions() -> Bool { !isPermissionFrozen }

    /// Unified gate for destructive entry points; also does a **silent** trusted self-check on the side (never with a prompt).
    ///
    /// Snapshot protection must be the controller's own business: the watchdog samples every 5 seconds; as long as there are sessions, suppressed frames, or restore tasks,
    /// polling stays at 0.2 seconds here. The 1-second slow tier is enabled only in idle periods when there is no snapshot to protect.
    /// In the 0-5 seconds between permission revocation and the watchdog seeing its first false, if the user switches screens once,
    /// `reconcileContext` would first clear the snapshots and then try to restore -- yet AX can no longer write at that point.
    private func ensureTrustedOrFreeze() -> Bool {
        if isPermissionFrozen { return false }
        guard isTrustedProbe() else {
            enterFreeze(reason: "selfCheck")
            return false
        }
        return true
    }

    deinit {
        MainActor.assumeIsolated { stop() }
    }

    /// The user setting switch. Off -> `stop()` (also restoring lifted windows to their native size);
    /// on -> restart polling.
    ///
    /// Not restarted during freeze: `enterFreeze` has already torn down the workspace observer and cleared `isEnabled`,
    /// and `start()` at that point would only install an idle timer and put back observers that shouldn't exist during freeze. On unfreeze
    /// `endPermissionUncertainty()` calls `start()` itself, and that path now honors this flag too.
    func setEnabledBySetting(_ enabled: Bool) {
        guard isEnabledBySetting != enabled else { return }
        isEnabledBySetting = enabled
        if enabled {
            guard !isPermissionFrozen else { return }
            start()
        } else {
            stop()
        }
    }

    func start(environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard !isEnabled else { return }
        guard isEnabledBySetting else { return }
        guard DebugSwitch.windowLift.isEnabled(in: environment) else {
            logger.info("window lift disabled by DOCK_WINDOW_LIFT=0")
            return
        }

        isEnabled = true
        usesAnimatedLift = DebugSwitch.windowLiftAnim.isEnabled(in: environment)
        includesTiles = DebugSwitch.windowLiftTiles.isEnabled(in: environment)
        traceEnabled = DebugSwitch.windowLiftTrace.isEnabled(in: environment)
        periodicPollCount = 0
        eventPollCount = 0
        trailingEventPollCount = 0
        subscribeWorkspaceNotifications()

        let geometryObserver = FrontmostWindowGeometryObserver()
        geometryObserver.onEvent = { [weak self] _ in
            self?.requestEventPoll()
        }
        self.geometryObserver = geometryObserver
        let initialPID = NSWorkspace.shared.runningApplications.first(where: { $0.isActive })?
            .processIdentifier
        geometryObserver.start(pid: initialPID)

        updatePollTimerLifecycle()
        poll()
        if traceEnabled {
            logger.info("window lift trace started animated=\(self.usesAnimatedLift, privacy: .public) tiles=\(self.includesTiles, privacy: .public)")
        }
    }

    func stop() {
        // After freeze, isEnabled and pollTimer have both been cleared, and looking only at these two conditions would make stop() idle,
        // so windows pending restore could never go back -- hence we also check whether there's an outstanding restore.
        guard isEnabled || pollTimer != nil || geometryObserver != nil
            || !states.isEmpty || !pendingRestorations.isEmpty else { return }
        tracePollSummary(reason: "stop")
        isEnabled = false
        pollTimer?.invalidate()
        pollTimer = nil
        pollTimerInterval = nil
        resetEventPolling()
        scanGeneration &+= 1
        scanTask?.cancel()
        scanTask = nil
        scanInFlight = false
        stopTrackedProbe()
        geometryObserver?.stop()
        geometryObserver = nil
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        workspaceObservers.removeAll()
        restoreSettledWindowsAndClearSessions()
        lastContexts = []
        sessionContexts.removeAll()
        userFrames.removeAll()
        lastDoubleClick = nil
    }

    func stopAndRestore() async {
        stop()
        while let task = restoreTask {
            await task.value
        }
    }

    private func subscribeWorkspaceNotifications() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let activePID = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                .processIdentifier
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.cancelWrites(except: activePID)
                self.geometryObserver?.activate(pid: activePID)
                self.requestEventPoll()
            }
        })
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                .processIdentifier
            Task { @MainActor [weak self] in
                guard let self, let pid else { return }
                self.removeStates(forPID: pid)
            }
        })
    }

    private func hostContexts() -> [WindowLiftAvoidanceContext] {
        host?.windowLiftAvoidanceContexts() ?? []
    }

    private func poll() {
        guard isEnabled, ensureTrustedOrFreeze() else { return }
        let contexts = hostContexts()
        reconcileContexts(contexts)
        guard !contexts.isEmpty, !scanInFlight, restoreTask == nil else { return }

        scanInFlight = true
        scanGeneration &+= 1
        let generation = scanGeneration
        nextGeneration &+= 1
        let observationGeneration = nextGeneration
        let tracked = !states.isEmpty || !suppressedFrames.isEmpty
        let selfPID = pid_t(ProcessInfo.processInfo.processIdentifier)
        let includesTiles = includesTiles
        let trackedKeys = Set(states.keys)
        scanTask = Task.detached { [weak self] in
            let result = WindowLiftCGWindowProbe.capture(
                on: contexts,
                excludingPID: selfPID,
                includeLiveWindowKeys: tracked,
                includesTiles: includesTiles,
                trackedKeys: trackedKeys
            )
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                self?.handleScanResult(
                    result,
                    contexts: contexts,
                    scanGeneration: generation,
                    observationGeneration: observationGeneration
                )
            }
        }
    }

    private func updatePollTimerLifecycle() {
        guard isEnabled else {
            pollTimer?.invalidate()
            pollTimer = nil
            pollTimerInterval = nil
            return
        }

        let interval = WindowLiftAvoidance.PollCadence.interval(
            hasSessions: !states.isEmpty,
            hasSuppressedFrames: !suppressedFrames.isEmpty,
            isRestoring: restoreTask != nil
        )
        guard pollTimer == nil || pollTimerInterval != interval else { return }

        let previousInterval = pollTimerInterval
        if traceEnabled, let previous = previousInterval {
            logger.info(
                "lift trace cadence from=\(previous, privacy: .public) to=\(interval, privacy: .public)"
            )
        }
        pollTimer?.invalidate()
        resetEventPolling()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.periodicPollCount &+= 1
                self.poll()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        pollTimerInterval = interval

        // The old fixed 0.2s timer always supplied one more convergence scan after a
        // transient validation/session clear. Preserve that behavior when dropping to idle.
        if previousInterval == WindowLiftAvoidance.globalDetectionInterval,
           interval == WindowLiftAvoidance.PollCadence.idleInterval {
            Task { @MainActor [weak self] in self?.requestEventPoll() }
        }
    }

    private var usesFastPollCadence: Bool {
        pollTimerInterval == WindowLiftAvoidance.globalDetectionInterval
    }

    private func requestEventPoll() {
        guard isEnabled, !usesFastPollCadence else { return }
        let action = eventPollCoalescer.request(
            at: ProcessInfo.processInfo.systemUptime,
            scanInFlight: scanInFlight
        )
        performEventPollAction(action, trailing: false)
    }

    private func finishEventPollAfterScan() {
        guard isEnabled, !usesFastPollCadence else { return }
        let action = eventPollCoalescer.scanCompleted(
            at: ProcessInfo.processInfo.systemUptime
        )
        performEventPollAction(action, trailing: true)
    }

    private func performEventPollAction(
        _ action: WindowLiftAvoidance.EventPollCoalescer.Action,
        trailing: Bool
    ) {
        switch action {
        case .none:
            break
        case .start:
            eventPollTimer?.invalidate()
            eventPollTimer = nil
            if trailing {
                trailingEventPollCount &+= 1
            } else {
                eventPollCount &+= 1
            }
            poll()
        case .schedule(let delay):
            guard eventPollTimer == nil else { return }
            let timer = Timer(timeInterval: max(0, delay), repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.eventPollTimer = nil
                    let action = self.eventPollCoalescer.cooldownFired(
                        at: ProcessInfo.processInfo.systemUptime,
                        scanInFlight: self.scanInFlight
                    )
                    self.performEventPollAction(action, trailing: true)
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            eventPollTimer = timer
        }
    }

    private func resetEventPolling() {
        eventPollTimer?.invalidate()
        eventPollTimer = nil
        eventPollCoalescer.reset()
    }

    private func tracePollSummary(reason: String) {
        guard traceEnabled else { return }
        logger.info(
            "lift trace poll-summary reason=\(reason, privacy: .public) periodic=\(self.periodicPollCount, privacy: .public) event=\(self.eventPollCount, privacy: .public) trailing=\(self.trailingEventPollCount, privacy: .public)"
        )
    }

    private func updateTrackedProbeLifecycle() {
        guard isEnabled, !states.isEmpty, restoreTask == nil else {
            stopTrackedProbe()
            return
        }
        guard trackedProbeTimer == nil else { return }

        let timer = Timer(timeInterval: Self.trackedProbeInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.probeTrackedFrames() }
        }
        RunLoop.main.add(timer, forMode: .common)
        trackedProbeTimer = timer
    }

    private func stopTrackedProbe() {
        trackedProbeTimer?.invalidate()
        trackedProbeTimer = nil
        clickSampler.reset()
        trackedProbeGeneration &+= 1
        trackedProbeTask?.cancel()
        trackedProbeTask = nil
    }

    private func probeTrackedFrames() {
        guard isEnabled,
              restoreTask == nil,
              trackedProbeTask == nil,
              !lastContexts.isEmpty else {
            updateTrackedProbeLifecycle()
            return
        }
        let contexts = lastContexts
        guard hostContexts() == contexts else {
            stopTrackedProbe()
            return
        }

        sessionContexts = sessionContexts.filter { states[$0.key] != nil }
        let keys = Set(states.keys)
        guard !keys.isEmpty else {
            updateTrackedProbeLifecycle()
            return
        }
        sampleClicks()

        trackedProbeGeneration &+= 1
        let generation = trackedProbeGeneration
        nextGeneration &+= 1
        let observationGeneration = nextGeneration
        trackedProbeTask = Task.detached { [weak self] in
            let frames = WindowLiftCGWindowProbe.frames(for: keys)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                self?.handleTrackedProbeResult(
                    frames,
                    contexts: contexts,
                    probeGeneration: generation,
                    observationGeneration: observationGeneration
                )
            }
        }
    }

    private func handleTrackedProbeResult(
        _ quartzFrames: [WindowLiftAvoidance.WindowKey: CGRect],
        contexts: [WindowLiftAvoidanceContext],
        probeGeneration: UInt64,
        observationGeneration: UInt64
    ) {
        guard probeGeneration == trackedProbeGeneration else { return }
        trackedProbeTask = nil
        guard hostContexts() == contexts else {
            stopTrackedProbe()
            return
        }
        guard restoreTask == nil else { return }

        for (key, quartzFrame) in quartzFrames {
            // The screen a session belongs to must still be in the set; those not in it (that screen's bar is hidden / unplugged) were already restored as a whole by reconcileContexts.
            guard let context = sessionContexts[key], contexts.contains(context) else { continue }
            _ = handleTrackedObservation(
                quartzFrame,
                for: key,
                context: context,
                observationGeneration: observationGeneration
            )
        }
        updateTrackedProbeLifecycle()
    }

    @discardableResult
    private func handleTrackedObservation(
        _ quartzFrame: CGRect,
        for key: WindowLiftAvoidance.WindowKey,
        context: WindowLiftAvoidanceContext,
        observationGeneration: UInt64
    ) -> Bool {
        guard let state = states[key], let frames = managedFrames[key] else { return false }
        guard acceptObservation(for: key, generation: observationGeneration) else { return true }

        let appKitFrame = WindowLiftAvoidance.appKitFrame(
            fromQuartz: quartzFrame,
            primaryScreenHeight: context.primaryScreenHeight
        )
        let classification = WindowLiftAvoidance.frameClassification(
            of: appKitFrame,
            nativeFrame: frames.nativeAppKit,
            targetFrame: frames.targetAppKit
        )
        traceClassification(classification, for: key)

        if case let .writing(attempt) = state,
           validationGenerations[key] == attempt.generation,
           classification == .external {
            // The bounded CG/AX confirmation owns zoom-tail movement until it either stabilizes or
            // returns candidateMoved. No AX write has happened yet, so never suppress this frame.
            return true
        }

        if case .lifted = state, classification == .native {
            guard NSRunningApplication(processIdentifier: key.pid)?.isActive == true,
                  hostContexts().contains(context) else {
                return true
            }
            if restoreUserFrameIfZoomToggled(for: key, state: state, frames: frames) {
                return true
            }
        }

        let transition = WindowLiftAvoidance.reduce(
            state: state,
            event: .nonMaximizedObserved(
                generation: observationGeneration,
                at: ProcessInfo.processInfo.systemUptime,
                frame: appKitFrame
            )
        )
        let candidate = WindowLiftCGCandidate(
            key: key,
            quartzFrame: WindowLiftAvoidance.quartzFrame(
                fromAppKit: appKitFrame,
                primaryScreenHeight: context.primaryScreenHeight
            )
        )
        apply(
            transition,
            for: candidate,
            context: context,
            operationGeneration: observationGeneration
        )
        return true
    }

    /// Once the context **set** changes (a screen's bar shown/hidden / tier switch / screen plugged or unplugged) -> restore all lifted windows, rescan next round (re-lift within <=0.2s).
    /// This generalizes the single-screen-era "restore on screen change" behavior; per-screen incremental restore is left until someone reports "windows on the other screen jump too".
    private func reconcileContexts(_ contexts: [WindowLiftAvoidanceContext]) {
        guard canMutateSessions() else { return }
        guard contexts != lastContexts else { return }
        observationWatermarks.removeAll()
        clearAllSuppressions()
        scanGeneration &+= 1
        scanTask?.cancel()
        scanTask = nil
        scanInFlight = false
        updatePollTimerLifecycle()

        if !lastContexts.isEmpty {
            restoreSettledWindowsAndClearSessions()
        }
        lastContexts = contexts
    }

    private func handleScanResult(
        _ result: WindowLiftCGScanResult,
        contexts: [WindowLiftAvoidanceContext],
        scanGeneration: UInt64,
        observationGeneration: UInt64
    ) {
        guard scanGeneration == self.scanGeneration else { return }
        scanTask = nil
        scanInFlight = false
        defer { finishEventPollAfterScan() }
        // Scan callbacks that are already queued must also pass the gate: adding guards to a few cleanup functions alone can't stop in-flight work.
        guard canMutateSessions() else { return }
        guard hostContexts() == contexts else { return }
        // A restore queued after this scan started (user zoom toggle) owns the window now; a
        // candidate captured before the restore wrote would start a lift against it.
        guard restoreTask == nil else { return }

        if let liveWindowKeys = result.liveWindowKeys {
            pruneDeadWindowStates(
                liveWindowKeys: liveWindowKeys,
                observationGeneration: observationGeneration
            )
        }
        let reconciledKeys = reconcileTrackedFrames(
            result.onScreenFrames,
            contexts: contexts,
            observationGeneration: observationGeneration
        )
        rememberUserFrames(result.onScreenFrames, contexts: contexts)

        // Candidates per screen; a window spanning screens belongs only to the screen holding the majority of its area. Only the foreground app's windows get lifted,
        // so just take the first candidate in screen order that passes all the gates.
        let screenCGFrames = contexts.map(\.screenCGFrame)
        for (index, context) in contexts.enumerated() {
            guard let candidate = result.candidatesByScreenIndex[index],
                  WindowLiftAvoidance.owningContextIndex(for: candidate.quartzFrame, screenCGFrames: screenCGFrames) == index,
                  !reconciledKeys.contains(candidate.key) else { continue }
            if handleScanCandidate(
                candidate,
                context: context,
                observationGeneration: observationGeneration
            ) {
                return
            }
        }
    }

    /// Returns true = this candidate has been handled (lifted or already in a session), and later screens needn't be looked at.
    private func handleScanCandidate(
        _ candidate: WindowLiftCGCandidate,
        context: WindowLiftAvoidanceContext,
        observationGeneration: UInt64
    ) -> Bool {
        guard acceptObservation(
            for: candidate.key,
            generation: observationGeneration
        ) else {
            return false
        }
        let appKitFrame = WindowLiftAvoidance.appKitFrame(
            fromQuartz: candidate.quartzFrame,
            primaryScreenHeight: context.primaryScreenHeight
        )
        if let suppressed = suppressedFrames[candidate.key] {
            let classification = WindowLiftAvoidance.frameClassification(
                of: appKitFrame,
                nativeFrame: suppressed.nativeAppKit,
                targetFrame: suppressed.targetAppKit
            )
            traceClassification(classification, for: candidate.key)
            guard classification == .native
                || context.geometry.suppressionReleasesOnNewFrame(
                    appKitFrame,
                    suppressedNative: suppressed.nativeAppKit,
                    userEra: userEraSuppressedKeys.contains(candidate.key),
                    includesTiles: includesTiles
                ) else {
                return false
            }
            clearSuppression(for: candidate.key)
            updatePollTimerLifecycle()
            if traceEnabled {
                logger.info(
                    "lift trace suppression cleared pid=\(candidate.key.pid, privacy: .public) wid=\(candidate.key.cgWindowID, privacy: .public)"
                )
            }
        }
        guard let targetFrame = context.geometry.liftTargetFrame(
                  for: appKitFrame,
                  includesTiles: includesTiles
              ),
              let app = NSRunningApplication(processIdentifier: candidate.key.pid),
              app.isActive,
              !app.isTerminated,
              app.activationPolicy == .regular || app.activationPolicy == .accessory else {
            return false
        }

        if let state = states[candidate.key],
           let frames = managedFrames[candidate.key],
           WindowLiftAvoidance.framesMatch(appKitFrame, frames.nativeAppKit),
           restoreUserFrameIfZoomToggled(for: candidate.key, state: state, frames: frames) {
            return true
        }

        let operationGeneration = observationGeneration
        let transition = WindowLiftAvoidance.reduce(
            state: states[candidate.key] ?? .idle,
            event: .maximizedDetected(
                generation: operationGeneration,
                at: ProcessInfo.processInfo.systemUptime,
                nativeFrame: appKitFrame,
                targetFrame: targetFrame
            )
        )
        apply(
            transition,
            for: candidate,
            context: context,
            operationGeneration: operationGeneration
        )
        return true
    }

    private func reconcileTrackedFrames(
        _ quartzFrames: [WindowLiftAvoidance.WindowKey: CGRect],
        contexts: [WindowLiftAvoidanceContext],
        observationGeneration: UInt64
    ) -> Set<WindowLiftAvoidance.WindowKey> {
        var reconciled: Set<WindowLiftAvoidance.WindowKey> = []
        for key in Array(states.keys) {
            guard let quartzFrame = quartzFrames[key],
                  let context = sessionContexts[key], contexts.contains(context) else { continue }
            if handleTrackedObservation(
                quartzFrame,
                for: key,
                context: context,
                observationGeneration: observationGeneration
            ) {
                reconciled.insert(key)
            }
        }
        return reconciled
    }

    private func acceptObservation(
        for key: WindowLiftAvoidance.WindowKey,
        generation: UInt64
    ) -> Bool {
        guard generation > (observationWatermarks[key] ?? 0) else { return false }
        observationWatermarks[key] = generation
        return true
    }

    private func apply(
        _ transition: WindowLiftAvoidance.Transition,
        for candidate: WindowLiftCGCandidate,
        context: WindowLiftAvoidanceContext,
        operationGeneration: UInt64
    ) {
        sessionContexts[candidate.key] = context
        if transition.action == .clear {
            // Read the era off the state the external frame is about to clear.
            let userEra = WindowLiftAvoidance.externalFrameIsUserEra(
                state: states[candidate.key] ?? .idle,
                at: ProcessInfo.processInfo.systemUptime
            )
            clearManagedSession(
                for: candidate.key,
                cancelWriter: true,
                reason: "reducerClear",
                suppression: .untilNative(userEra: userEra)
            )
            return
        }
        store(transition.state, for: candidate.key)
        switch transition.action {
        case .none:
            break
        case .clear:
            break
        case let .abandon(reason):
            logger.error(
                "lift abandoned pid=\(candidate.key.pid, privacy: .public) wid=\(candidate.key.cgWindowID, privacy: .public) reason=\(String(describing: reason), privacy: .public)"
            )
        case let .write(targetFrame, rollbackFrame, generation, isRelift):
            guard generation == operationGeneration else { return }
            beginWrite(
                candidate: candidate,
                nativeFrame: rollbackFrame,
                targetFrame: targetFrame,
                context: context,
                generation: generation,
                isRelift: isRelift
            )
        }
    }

    private func beginWrite(
        candidate: WindowLiftCGCandidate,
        nativeFrame: CGRect,
        targetFrame: CGRect,
        context: WindowLiftAvoidanceContext,
        generation: UInt64,
        isRelift: Bool
    ) {
        let key = candidate.key
        guard case let .writing(attempt) = states[key],
              attempt.generation == generation else {
            return
        }
        let nativeQuartz = WindowLiftAvoidance.quartzFrame(
            fromAppKit: nativeFrame,
            primaryScreenHeight: context.primaryScreenHeight
        )
        let targetQuartz = WindowLiftAvoidance.quartzFrame(
            fromAppKit: targetFrame,
            primaryScreenHeight: context.primaryScreenHeight
        )
        managedFrames[key] = ManagedFrames(
            nativeAppKit: nativeFrame,
            targetAppKit: targetFrame,
            nativeQuartz: nativeQuartz,
            targetQuartz: targetQuartz,
            primaryScreenHeight: context.primaryScreenHeight
        )
        validationGenerations[key] = generation

        let animate = usesAnimatedLift
        let reader = AXWindowReader()
        var drains = writeDrainTasks.removeValue(forKey: key) ?? []
        if let previousWriter = writeTasks.removeValue(forKey: key) {
            previousWriter.cancel()
            drains.append(previousWriter)
        }
        let task = Task.detached { [weak self] in
            for drain in drains {
                await drain.value
            }
            guard !Task.isCancelled else {
                await MainActor.run { [weak self] in
                    self?.finishOperation(for: key, generation: generation, outcome: .cancelled)
                }
                return
            }

            let mayBegin = await MainActor.run { [weak self] in
                self?.canContinueOperation(
                    for: key,
                    generation: generation,
                    context: context
                ) ?? false
            }
            guard mayBegin, !Task.isCancelled else {
                await MainActor.run { [weak self] in
                    self?.finishOperation(for: key, generation: generation, outcome: .cancelled)
                }
                return
            }

            let detectedAt = ProcessInfo.processInfo.systemUptime
            let validation = await Self.validatedHandle(
                reader: reader,
                candidate: candidate,
                detectedAt: detectedAt
            )
            guard !Task.isCancelled else {
                await MainActor.run { [weak self] in
                    self?.finishOperation(for: key, generation: generation, outcome: .cancelled)
                }
                return
            }

            let handle: AXWindowHandle
            switch validation {
            case let .ready(validatedHandle):
                handle = validatedHandle
            case let .transient(stage):
                await MainActor.run { [weak self] in
                    self?.finishOperation(
                        for: key,
                        generation: generation,
                        outcome: .transientValidation(stage)
                    )
                }
                return
            case let .unsupported(stage):
                await MainActor.run { [weak self] in
                    self?.finishOperation(
                        for: key,
                        generation: generation,
                        outcome: .unsupportedValidation(stage)
                    )
                }
                return
            }

            let mayContinue = await MainActor.run { [weak self] in
                self?.canBeginAXWrite(
                    for: key,
                    generation: generation,
                    context: context
                ) ?? false
            }
            guard mayContinue, !Task.isCancelled else {
                await MainActor.run { [weak self] in
                    self?.finishOperation(for: key, generation: generation, outcome: .cancelled)
                }
                return
            }

            let outcome = await Self.write(
                reader: reader,
                element: handle.element,
                nativeFrame: nativeQuartz,
                targetFrame: targetQuartz,
                animated: animate,
                initialReliftCount: attempt.reliftCount,
                primaryScreenHeight: context.primaryScreenHeight
            )
            await MainActor.run { [weak self] in
                self?.finishOperation(for: key, generation: generation, outcome: outcome)
            }
        }
        writeTasks[key] = task
        if isRelift {
            logger.notice(
                "lift relift begin pid=\(key.pid, privacy: .public) wid=\(key.cgWindowID, privacy: .public) count=\(attempt.reliftCount, privacy: .public)"
            )
        } else if traceEnabled {
            logger.info(
                "lift trace begin pid=\(key.pid, privacy: .public) wid=\(key.cgWindowID, privacy: .public) generation=\(generation, privacy: .public) animated=\(animate, privacy: .public)"
            )
        }
        updateTrackedProbeLifecycle()
    }

    nonisolated private static func validatedHandle(
        reader: AXWindowReader,
        candidate: WindowLiftCGCandidate,
        detectedAt: TimeInterval
    ) async -> ValidationOutcome {
        let schedule = WindowLiftAvoidance.PollSchedule.standard
        var lastTransientStage: ValidationStage = .handleUnavailable

        for index in schedule.deadlines.indices {
            guard !Task.isCancelled else { return .transient(lastTransientStage) }
            let elapsed = ProcessInfo.processInfo.systemUptime - detectedAt
            if let delay = schedule.remainingDelay(for: index, elapsed: elapsed), delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled else { return .transient(lastTransientStage) }
            guard let confirmedCGFrame = WindowLiftCGWindowProbe.frame(for: candidate.key) else {
                lastTransientStage = .candidateMoved
                continue
            }
            guard let handle = reader.captureHandle(
                forPID: candidate.key.pid,
                cgWindowID: candidate.key.cgWindowID,
                messagingTimeout: windowLiftAXMessagingTimeout
            ) else {
                lastTransientStage = .handleUnavailable
                continue
            }

            let element = handle.element
            guard let role = reader.stringAttribute(
                kAXRoleAttribute as CFString,
                from: element,
                maxAttempts: 1
            ) else {
                lastTransientStage = .roleUnavailable
                continue
            }
            guard role == (kAXWindowRole as String) else { return .unsupported(.unsupportedRole) }
            if reader.boolAttribute("AXFullScreen" as CFString, from: element, maxAttempts: 1) == true {
                guard index == schedule.deadlines.index(before: schedule.deadlines.endIndex) else {
                    lastTransientStage = .fullscreen
                    continue
                }
                return .unsupported(.fullscreen)
            }
            if reader.boolAttribute(
                kAXMinimizedAttribute as CFString,
                from: element,
                maxAttempts: 1
            ) == true {
                guard index == schedule.deadlines.index(before: schedule.deadlines.endIndex) else {
                    lastTransientStage = .minimized
                    continue
                }
                return .unsupported(.minimized)
            }
            guard let confirmedAXFrame = reader.frame(
                of: element,
                messagingTimeout: windowLiftAXMessagingTimeout
            ) else {
                lastTransientStage = .frameUnavailable
                continue
            }

            switch reader.frameSettableStatus(
                of: element,
                messagingTimeout: windowLiftAXMessagingTimeout
            ).size {
            case .settable:
                break
            case .notSettable:
                return .unsupported(.sizeNotSettable)
            case .unread:
                lastTransientStage = .capabilityUnavailable
                continue
            }

            guard WindowLiftAvoidance.samplesAreStable(
                initialCGFrame: candidate.quartzFrame,
                confirmedCGFrame: confirmedCGFrame,
                confirmedAXFrame: confirmedAXFrame
            ) else {
                lastTransientStage = WindowLiftAvoidance.samplesAreStable(
                    confirmedCGFrame,
                    comparedTo: candidate.quartzFrame
                ) ? .frameMismatch : .candidateMoved
                continue
            }

            // The zero-deadline pass only captures the first synchronized sample. A write may
            // start once a later (≥100ms) confirmation fully agrees with the detected frame.
            // Jitter from early samples no longer vetoes the whole round (the old behavior forced a full 0.2s rescan cycle):
            // the write loop's stall/trajectory checks can already safely absorb residual movement.
            guard index > schedule.deadlines.startIndex else {
                lastTransientStage = .frameMismatch
                continue
            }
            return .ready(handle)
        }
        return .transient(lastTransientStage)
    }

    nonisolated private static func write(
        reader: AXWindowReader,
        element: AXUIElement,
        nativeFrame: CGRect,
        targetFrame: CGRect,
        animated: Bool,
        initialReliftCount: Int,
        primaryScreenHeight: CGFloat
    ) async -> OperationOutcome {
        if !animated {
            let result = reader.setSize(
                targetFrame.size,
                for: element,
                messagingTimeout: windowLiftAXMessagingTimeout,
                verificationTolerance: WindowLiftAvoidance.verificationTolerance,
                onlyIfCurrentMatches: nativeFrame,
                restoreOnFailureTo: nil
            )
            if Task.isCancelled {
                if case let .success(actualFrame) = result {
                    rollbackCancelledWrite(
                        reader: reader,
                        element: element,
                        nativeFrame: nativeFrame,
                        attemptedFrame: actualFrame
                    )
                }
                return .cancelled
            }
            switch result {
            case let .success(actualFrame):
                return completedOrRolledBack(
                    reader: reader,
                    element: element,
                    actualFrame: actualFrame,
                    nativeFrame: nativeFrame,
                    targetFrame: targetFrame,
                    reliftCount: initialReliftCount,
                    anomalies: [],
                    primaryScreenHeight: primaryScreenHeight
                )

            case let .failure(reason, rollback):
                let decision = animationFailureDecision(
                    for: reason,
                    nativeFrame: nativeFrame,
                    targetFrame: targetFrame,
                    reliftCount: initialReliftCount,
                    lastAcknowledgedFrame: nativeFrame,
                    primaryScreenHeight: primaryScreenHeight
                )
                let anomaly = WriteAnomaly(
                    reason: reason,
                    rollback: rollback,
                    decision: decision,
                    progress: 1
                )
                switch decision {
                case let .complete(actualFrame):
                    return completedOrRolledBack(
                        reader: reader,
                        element: element,
                        actualFrame: actualFrame,
                        nativeFrame: nativeFrame,
                        targetFrame: targetFrame,
                        reliftCount: initialReliftCount,
                        anomalies: [anomaly],
                        primaryScreenHeight: primaryScreenHeight
                    )
                case let .continueFromActual(actualFrame):
                    // Stall: the write may not have been applied by the window yet (late application on a 1x screen). Wait a beat and confirm once more;
                    // only if it's still not in place, clear the session and hand back to the next scan round.
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    if !Task.isCancelled,
                       let settledFrame = reader.frame(
                           of: element,
                           messagingTimeout: windowLiftAXMessagingTimeout
                       ),
                       WindowLiftAvoidance.framesMatch(settledFrame, targetFrame) {
                        return .completed(settledFrame, reliftCount: initialReliftCount, anomalies: [anomaly])
                    }
                    return .externalFrame(actualFrame, anomalies: [anomaly])
                case let .clearSession(frame),
                     let .restartFromNative(frame, _):
                    // Instant mode owns exactly one AX write. A mismatch that did not mutate the
                    // window clears this attempt and lets the next CG observation start cleanly.
                    return .externalFrame(frame, anomalies: [anomaly])
                case let .reliftLimitReached(frame, count):
                    return .reliftLimitReached(
                        frame,
                        reliftCount: count,
                        anomalies: [anomaly]
                    )
                case .abandonWriteFailed:
                    return .failed(
                        reason: reason,
                        rollback: rollback,
                        progress: 1,
                        reliftCount: initialReliftCount,
                        anomalies: [anomaly]
                    )
                }
            }
        }

        let frameInterval = 1.0 / WindowLiftAvoidance.animationFramesPerSecond
        var segmentStartFrame = nativeFrame
        var segmentProgressStart = 0.0
        let animationStartedAt = ProcessInfo.processInfo.systemUptime
        var nextDeadline = animationStartedAt + frameInterval
        var expectedFrame = nativeFrame
        var reliftCount = initialReliftCount
        var anomalies: [WriteAnomaly] = []
        // The final frame allows a limited number of stall retries: on slow-app screens the write takes effect later than the readback.
        var finalStallRetries = 0
        let maxFinalStallRetries = 3

        while true {
            let now = ProcessInfo.processInfo.systemUptime
            let animationElapsed = now - animationStartedAt
            if animationElapsed >= WindowLiftAvoidance.animationDuration {
                let result = reader.setSize(
                    targetFrame.size,
                    for: element,
                    messagingTimeout: windowLiftAXMessagingTimeout,
                    verificationTolerance: WindowLiftAvoidance.verificationTolerance,
                    onlyIfCurrentMatches: expectedFrame,
                    restoreOnFailureTo: nil
                )
                if Task.isCancelled {
                    if case let .success(actualFrame) = result {
                        rollbackCancelledWrite(
                            reader: reader,
                            element: element,
                            nativeFrame: nativeFrame,
                            attemptedFrame: actualFrame
                        )
                    }
                    return .cancelled
                }
                switch result {
                case let .success(actualFrame):
                    return completedOrRolledBack(
                        reader: reader,
                        element: element,
                        actualFrame: actualFrame,
                        nativeFrame: nativeFrame,
                        targetFrame: targetFrame,
                        reliftCount: reliftCount,
                        anomalies: anomalies,
                        primaryScreenHeight: primaryScreenHeight
                    )

                case let .failure(reason, rollback):
                    let decision = animationFailureDecision(
                        for: reason,
                        nativeFrame: nativeFrame,
                        targetFrame: targetFrame,
                        reliftCount: reliftCount,
                        lastAcknowledgedFrame: expectedFrame,
                        primaryScreenHeight: primaryScreenHeight
                    )
                    switch decision {
                    case let .complete(actualFrame):
                        return completedOrRolledBack(
                            reader: reader,
                            element: element,
                            actualFrame: actualFrame,
                            nativeFrame: nativeFrame,
                            targetFrame: targetFrame,
                            reliftCount: reliftCount,
                            anomalies: anomalies,
                            primaryScreenHeight: primaryScreenHeight
                        )
                    case let .continueFromActual(actualFrame):
                        // Final frame stalled / within trajectory: wait a beat and rewrite; only after a limited number of tries is it judged a failure.
                        if finalStallRetries < maxFinalStallRetries {
                            finalStallRetries += 1
                            expectedFrame = actualFrame
                            try? await Task.sleep(
                                nanoseconds: UInt64(frameInterval * 1_000_000_000)
                            )
                            continue
                        }
                        let anomaly = WriteAnomaly(
                            reason: reason,
                            rollback: rollback,
                            decision: decision,
                            progress: 1
                        )
                        recordBounded(anomaly, in: &anomalies)
                        let finalRollback = rollbackAfterAnimationFailure(
                            rollback,
                            reader: reader,
                            element: element,
                            nativeFrame: nativeFrame,
                            currentManagedFrame: actualFrame
                        )
                        return .failed(
                            reason: reason,
                            rollback: finalRollback,
                            progress: 1,
                            reliftCount: reliftCount,
                            anomalies: anomalies
                        )
                    case let .clearSession(frame):
                        recordBounded(WriteAnomaly(
                            reason: reason,
                            rollback: rollback,
                            decision: decision,
                            progress: 1
                        ), in: &anomalies)
                        return .externalFrame(frame, anomalies: anomalies)
                    case let .restartFromNative(frame, nextReliftCount):
                        recordBounded(WriteAnomaly(
                            reason: reason,
                            rollback: rollback,
                            decision: decision,
                            progress: 1
                        ), in: &anomalies)
                        let safeRollback = rollbackAfterAnimationFailure(
                            rollback,
                            reader: reader,
                            element: element,
                            nativeFrame: nativeFrame,
                            currentManagedFrame: frame
                        )
                        return .failed(
                            reason: reason,
                            rollback: safeRollback,
                            progress: 1,
                            reliftCount: nextReliftCount,
                            anomalies: anomalies
                        )
                    case let .reliftLimitReached(frame, count):
                        recordBounded(WriteAnomaly(
                            reason: reason,
                            rollback: rollback,
                            decision: decision,
                            progress: 1
                        ), in: &anomalies)
                        return .reliftLimitReached(frame, reliftCount: count, anomalies: anomalies)
                    case .abandonWriteFailed:
                        recordBounded(WriteAnomaly(
                            reason: reason,
                            rollback: rollback,
                            decision: decision,
                            progress: 1
                        ), in: &anomalies)
                        let safeRollback = rollbackAfterAnimationFailure(
                            rollback,
                            reader: reader,
                            element: element,
                            nativeFrame: nativeFrame,
                            currentManagedFrame: expectedFrame
                        )
                        return .failed(
                            reason: reason,
                            rollback: safeRollback,
                            progress: 1,
                            reliftCount: reliftCount,
                            anomalies: anomalies
                        )
                    }
                }
            }

            let sleepDuration = max(0, nextDeadline - now)
            if sleepDuration > 0 {
                try? await Task.sleep(nanoseconds: UInt64(sleepDuration * 1_000_000_000))
            }
            guard !Task.isCancelled else {
                rollbackCancelledWrite(
                    reader: reader,
                    element: element,
                    nativeFrame: nativeFrame,
                    attemptedFrame: expectedFrame
                )
                return .cancelled
            }

            let elapsed = ProcessInfo.processInfo.systemUptime - animationStartedAt
            guard elapsed < WindowLiftAvoidance.animationDuration else { continue }
            let overallProgress = max(0, elapsed / WindowLiftAvoidance.animationDuration)
            let progress = WindowLiftAvoidance.rebasedAnimationProgress(
                overallProgress,
                startingAt: segmentProgressStart
            )
            let attemptedFrame = monotonicAttemptedFrame(
                scheduled: WindowLiftAvoidance.interpolatedFrame(
                    from: segmentStartFrame,
                    to: targetFrame,
                    progress: progress
                ),
                current: expectedFrame,
                target: targetFrame
            )
            // Round the size: a 1x screen can only represent whole points, so fractional requests get rounded/ignored and run into the 2pt verification tolerance.
            let attemptedSize = CGSize(
                width: attemptedFrame.width.rounded(),
                height: attemptedFrame.height.rounded()
            )
            let result = reader.setSize(
                attemptedSize,
                for: element,
                messagingTimeout: windowLiftAXMessagingTimeout,
                verificationTolerance: WindowLiftAvoidance.verificationTolerance,
                onlyIfCurrentMatches: expectedFrame,
                restoreOnFailureTo: nil
            )
            if Task.isCancelled {
                if case let .success(actualFrame) = result {
                    rollbackCancelledWrite(
                        reader: reader,
                        element: element,
                        nativeFrame: nativeFrame,
                        attemptedFrame: actualFrame
                    )
                }
                return .cancelled
            }
            switch result {
            case let .success(actualFrame):
                expectedFrame = actualFrame
                guard !Task.isCancelled else {
                    rollbackCancelledWrite(
                        reader: reader,
                        element: element,
                        nativeFrame: nativeFrame,
                        attemptedFrame: actualFrame
                    )
                    return .cancelled
                }
            case let .failure(reason, rollback):
                let decision = animationFailureDecision(
                    for: reason,
                    nativeFrame: nativeFrame,
                    targetFrame: targetFrame,
                    reliftCount: reliftCount,
                    lastAcknowledgedFrame: expectedFrame,
                    primaryScreenHeight: primaryScreenHeight
                )
                if case let .continueFromActual(actualFrame) = decision {
                    // Self-heal when stalled or within trajectory: not an anomaly; the progress table will naturally make up the step on the next frame.
                    expectedFrame = actualFrame
                } else {
                    let anomaly = WriteAnomaly(
                        reason: reason,
                        rollback: rollback,
                        decision: decision,
                        progress: overallProgress
                    )
                    recordBounded(anomaly, in: &anomalies)
                    switch decision {
                    case let .complete(actualFrame):
                        return completedOrRolledBack(
                            reader: reader,
                            element: element,
                            actualFrame: actualFrame,
                            nativeFrame: nativeFrame,
                            targetFrame: targetFrame,
                            reliftCount: reliftCount,
                            anomalies: anomalies,
                            primaryScreenHeight: primaryScreenHeight
                        )
                    case .continueFromActual:
                        break
                    case let .clearSession(frame):
                        return .externalFrame(frame, anomalies: anomalies)
                    case let .restartFromNative(frame, nextReliftCount):
                        segmentStartFrame = frame
                        expectedFrame = frame
                        reliftCount = nextReliftCount
                        segmentProgressStart = overallProgress
                        continue
                    case let .reliftLimitReached(frame, count):
                        return .reliftLimitReached(frame, reliftCount: count, anomalies: anomalies)
                    case .abandonWriteFailed:
                        let safeRollback = rollbackAfterAnimationFailure(
                            rollback,
                            reader: reader,
                            element: element,
                            nativeFrame: nativeFrame,
                            currentManagedFrame: expectedFrame
                        )
                        return .failed(
                            reason: reason,
                            rollback: safeRollback,
                            progress: overallProgress,
                            reliftCount: reliftCount,
                            anomalies: anomalies
                        )
                    }
                }
            }

            let elapsedAfterWrite = max(
                0,
                ProcessInfo.processInfo.systemUptime - animationStartedAt
            )
            let completedSlots = floor(elapsedAfterWrite / frameInterval)
            nextDeadline = animationStartedAt + (completedSlots + 1) * frameInterval
        }
    }

    nonisolated private static func completedOrRolledBack(
        reader: AXWindowReader,
        element: AXUIElement,
        actualFrame: CGRect,
        nativeFrame: CGRect,
        targetFrame: CGRect,
        reliftCount: Int,
        anomalies: [WriteAnomaly],
        primaryScreenHeight: CGFloat
    ) -> OperationOutcome {
        let actualAppKit = WindowLiftAvoidance.appKitFrame(
            fromQuartz: actualFrame,
            primaryScreenHeight: primaryScreenHeight
        )
        let targetAppKit = WindowLiftAvoidance.appKitFrame(
            fromQuartz: targetFrame,
            primaryScreenHeight: primaryScreenHeight
        )
        guard !WindowLiftAvoidance.framesMatch(
            actualAppKit,
            targetAppKit,
            tolerance: WindowLiftAvoidance.verificationTolerance
        ) else {
            return .completed(actualFrame, reliftCount: reliftCount, anomalies: anomalies)
        }

        let reason = AXWindowFrameWriteFailure.verificationMismatch(
            expected: targetFrame,
            actual: actualFrame
        )
        let rollback = rollbackManagedFrame(
            reader: reader,
            element: element,
            nativeFrame: nativeFrame,
            currentFrame: actualFrame
        )
        var finalAnomalies = anomalies
        recordBounded(
            WriteAnomaly(
                reason: reason,
                rollback: rollback,
                decision: .abandonWriteFailed,
                progress: 1
            ),
            in: &finalAnomalies
        )
        return .failed(
            reason: reason,
            rollback: rollback,
            progress: 1,
            reliftCount: reliftCount,
            anomalies: finalAnomalies
        )
    }

    nonisolated private static func animationFailureDecision(
        for reason: AXWindowFrameWriteFailure,
        nativeFrame: CGRect,
        targetFrame: CGRect,
        reliftCount: Int,
        lastAcknowledgedFrame: CGRect,
        primaryScreenHeight: CGFloat
    ) -> WindowLiftAvoidance.AnimationWriteFailureDecision {
        let failure: WindowLiftAvoidance.AnimationWriteFailure
        switch reason {
        // verificationMismatch also carries the real actual value: on slow-app screens (1x external display) reading back right after a write
        // often returns the old value, and treating it as terminal would inevitably give up on the first frame's ~2pt easing step.
        case let .initialFrameMismatch(_, actualFrame),
             let .verificationMismatch(_, actualFrame):
            failure = .initialFrameMismatch(actualFrame: WindowLiftAvoidance.appKitFrame(
                fromQuartz: actualFrame,
                primaryScreenHeight: primaryScreenHeight
            ))
        default:
            failure = .terminalWriteFailure
        }
        let appKitDecision = WindowLiftAvoidance.animationWriteFailureDecision(
            failure,
            nativeFrame: WindowLiftAvoidance.appKitFrame(
                fromQuartz: nativeFrame,
                primaryScreenHeight: primaryScreenHeight
            ),
            targetFrame: WindowLiftAvoidance.appKitFrame(
                fromQuartz: targetFrame,
                primaryScreenHeight: primaryScreenHeight
            ),
            reliftCount: reliftCount,
            lastAcknowledgedFrame: WindowLiftAvoidance.appKitFrame(
                fromQuartz: lastAcknowledgedFrame,
                primaryScreenHeight: primaryScreenHeight
            )
        )
        func quartz(_ frame: CGRect) -> CGRect {
            WindowLiftAvoidance.quartzFrame(
                fromAppKit: frame,
                primaryScreenHeight: primaryScreenHeight
            )
        }
        switch appKitDecision {
        case let .complete(frame):
            return .complete(actualFrame: quartz(frame))
        case let .continueFromActual(frame):
            return .continueFromActual(actualFrame: quartz(frame))
        case let .clearSession(frame):
            return .clearSession(preservingFrame: quartz(frame))
        case let .restartFromNative(frame, nextReliftCount):
            return .restartFromNative(
                nativeFrame: quartz(frame),
                nextReliftCount: nextReliftCount
            )
        case let .reliftLimitReached(frame, count):
            return .reliftLimitReached(
                actualFrame: quartz(frame),
                reliftCount: count
            )
        case .abandonWriteFailed:
            return .abandonWriteFailed
        }
    }

    nonisolated private static func recordBounded(
        _ anomaly: WriteAnomaly,
        in anomalies: inout [WriteAnomaly]
    ) {
        if anomalies.count < 4 {
            anomalies.append(anomaly)
        } else {
            // Keep the beginning of the episode and always preserve the newest decision/result.
            anomalies[anomalies.count - 1] = anomaly
        }
    }

    /// A recovered trajectory mismatch may already be ahead of the elapsed-time sample. Do not
    /// grow the window back toward the native frame while the schedule catches up.
    nonisolated private static func monotonicAttemptedFrame(
        scheduled: CGRect,
        current: CGRect,
        target: CGRect
    ) -> CGRect {
        func component(_ scheduled: CGFloat, _ current: CGFloat, _ target: CGFloat) -> CGFloat {
            if target < current { return max(target, min(scheduled, current)) }
            if target > current { return min(target, max(scheduled, current)) }
            return target
        }
        return CGRect(
            origin: scheduled.origin,
            size: CGSize(
                width: component(scheduled.width, current.width, target.width),
                height: component(scheduled.height, current.height, target.height)
            )
        )
    }

    nonisolated private static func rollbackManagedFrame(
        reader: AXWindowReader,
        element: AXUIElement,
        nativeFrame: CGRect,
        currentFrame: CGRect
    ) -> AXWindowFrameRollbackResult {
        switch reader.setFrame(
            nativeFrame,
            for: element,
            messagingTimeout: windowLiftAXMessagingTimeout,
            verificationTolerance: WindowLiftAvoidance.verificationTolerance,
            onlyIfCurrentMatches: currentFrame,
            restoreOnFailureTo: currentFrame
        ) {
        case let .success(actualFrame):
            return .restored(actualFrame: actualFrame)
        case let .failure(reason, _):
            return .failed(
                reason: reason,
                actualFrame: reader.frame(
                    of: element,
                    messagingTimeout: windowLiftAXMessagingTimeout
                )
            )
        }
    }

    nonisolated private static func rollbackAfterAnimationFailure(
        _ rollback: AXWindowFrameRollbackResult,
        reader: AXWindowReader,
        element: AXUIElement,
        nativeFrame: CGRect,
        currentManagedFrame: CGRect
    ) -> AXWindowFrameRollbackResult {
        guard rollback == .notRequested,
              !WindowLiftAvoidance.framesMatch(currentManagedFrame, nativeFrame) else {
            return rollback
        }
        return rollbackManagedFrame(
            reader: reader,
            element: element,
            nativeFrame: nativeFrame,
            currentFrame: currentManagedFrame
        )
    }

    nonisolated private static func rollbackCancelledWrite(
        reader: AXWindowReader,
        element: AXUIElement,
        nativeFrame: CGRect,
        attemptedFrame: CGRect
    ) {
        let currentFrame = reader.frame(of: element, messagingTimeout: windowLiftAXMessagingTimeout)
        guard case let .restore(frame) = WindowLiftAvoidance.rollbackDecision(
            originalFrame: nativeFrame,
            attemptedFrame: attemptedFrame,
            currentFrame: currentFrame
        ) else {
            return
        }
        _ = reader.setFrame(
            frame,
            for: element,
            messagingTimeout: windowLiftAXMessagingTimeout,
            verificationTolerance: WindowLiftAvoidance.verificationTolerance,
            onlyIfCurrentMatches: attemptedFrame
        )
    }

    private func canContinueOperation(
        for key: WindowLiftAvoidance.WindowKey,
        generation: UInt64,
        context: WindowLiftAvoidanceContext
    ) -> Bool {
        guard hostContexts().contains(context),
              NSRunningApplication(processIdentifier: key.pid)?.isActive == true,
              case let .writing(attempt) = states[key],
              attempt.generation == generation else {
            return false
        }
        return true
    }

    private func canBeginAXWrite(
        for key: WindowLiftAvoidance.WindowKey,
        generation: UInt64,
        context: WindowLiftAvoidanceContext
    ) -> Bool {
        guard validationGenerations[key] == generation else { return false }
        validationGenerations.removeValue(forKey: key)
        return canContinueOperation(for: key, generation: generation, context: context)
    }

    private func finishOperation(
        for key: WindowLiftAvoidance.WindowKey,
        generation: UInt64,
        outcome: OperationOutcome
    ) {
        guard canMutateSessions() else {
            // Cancelling the write task lands here. During freeze it must not casually clear the session --
            // both the `.cancelled` / `.transientValidation` branches lead to clearManagedSession.
            if let writer = writeTasks.removeValue(forKey: key) { pendingDrains.append(writer) }
            return
        }
        guard case let .writing(attempt) = states[key], attempt.generation == generation else {
            return
        }
        if validationGenerations[key] == generation {
            validationGenerations.removeValue(forKey: key)
        }
        writeTasks.removeValue(forKey: key)
        let finishedAt = ProcessInfo.processInfo.systemUptime

        switch outcome {
        case .cancelled:
            clearManagedSession(for: key, cancelWriter: false, reason: "cancelled")

        case let .transientValidation(stage):
            logger.notice(
                "lift validation transient pid=\(key.pid, privacy: .public) wid=\(key.cgWindowID, privacy: .public) stage=\(stage.rawValue, privacy: .public)"
            )
            // Validation has not written the window yet. A moving zoom candidate must return to
            // idle so the next global sample can establish a fresh native frame.
            clearManagedSession(
                for: key,
                cancelWriter: false,
                reason: stage.rawValue
            )

        case let .unsupportedValidation(stage):
            let transition = WindowLiftAvoidance.reduce(
                state: states[key] ?? .idle,
                event: .writeFailed(
                    generation: generation,
                    at: finishedAt,
                    reliftCount: attempt.reliftCount
                )
            )
            store(transition.state, for: key)
            logger.error(
                "lift validation unsupported pid=\(key.pid, privacy: .public) wid=\(key.cgWindowID, privacy: .public) stage=\(stage.rawValue, privacy: .public)"
            )

        case let .externalFrame(actualQuartzFrame, anomalies):
            logWriteAnomalies(anomalies, for: key, terminal: false)
            if let frames = managedFrames[key] {
                let actualAppKit = WindowLiftAvoidance.appKitFrame(
                    fromQuartz: actualQuartzFrame,
                    primaryScreenHeight: frames.primaryScreenHeight
                )
                traceClassification(
                    WindowLiftAvoidance.frameClassification(
                        of: actualAppKit,
                        nativeFrame: frames.nativeAppKit,
                        targetFrame: frames.targetAppKit
                    ),
                    for: key
                )
                if traceEnabled {
                    logger.info(
                        "lift trace preserve external pid=\(key.pid, privacy: .public) wid=\(key.cgWindowID, privacy: .public) frame=\(String(describing: actualAppKit), privacy: .public)"
                    )
                }
            }
            // An external frame during our own write is never the user era.
            clearManagedSession(
                for: key,
                cancelWriter: false,
                reason: "externalFrame",
                suppression: .untilNative(userEra: false)
            )

        case let .reliftLimitReached(_, reliftCount, anomalies):
            logWriteAnomalies(anomalies, for: key, terminal: true)
            let transition = WindowLiftAvoidance.reduce(
                state: states[key] ?? .idle,
                event: .reliftLimitReached(
                    generation: generation,
                    at: finishedAt,
                    reliftCount: reliftCount
                )
            )
            store(transition.state, for: key)
            logger.error(
                "lift abandoned pid=\(key.pid, privacy: .public) wid=\(key.cgWindowID, privacy: .public) reason=reliftLimitReached count=\(reliftCount, privacy: .public)"
            )

        case let .failed(reason, rollback, progress, reliftCount, anomalies):
            logWriteAnomalies(anomalies, for: key, terminal: true)
            let transition = WindowLiftAvoidance.reduce(
                state: states[key] ?? .idle,
                event: .writeFailed(
                    generation: generation,
                    at: finishedAt,
                    reliftCount: reliftCount
                )
            )
            store(transition.state, for: key)
            logger.error(
                "lift write failed pid=\(key.pid, privacy: .public) wid=\(key.cgWindowID, privacy: .public) progress=\(progress, format: .fixed(precision: 3), privacy: .public) reason=\(String(describing: reason), privacy: .public) rollback=\(String(describing: rollback), privacy: .public)"
            )

        case let .completed(actualQuartzFrame, reliftCount, anomalies):
            logWriteAnomalies(anomalies, for: key, terminal: false)
            guard let frames = managedFrames[key] else { return }
            let actualAppKit = WindowLiftAvoidance.appKitFrame(
                fromQuartz: actualQuartzFrame,
                primaryScreenHeight: frames.primaryScreenHeight
            )
            let transition = WindowLiftAvoidance.reduce(
                state: states[key] ?? .idle,
                event: .writeFinished(
                    generation: generation,
                    at: finishedAt,
                    actualFrame: actualAppKit,
                    reliftCount: reliftCount
                )
            )
            store(transition.state, for: key)
            if reliftCount > attempt.reliftCount {
                logger.notice(
                    "lift relift completed pid=\(key.pid, privacy: .public) wid=\(key.cgWindowID, privacy: .public) count=\(reliftCount, privacy: .public)"
                )
            }
            if !WindowLiftAvoidance.framesMatch(actualAppKit, frames.targetAppKit) {
                logger.error(
                    "lift verification mismatch pid=\(key.pid, privacy: .public) wid=\(key.cgWindowID, privacy: .public)"
                )
            }
        }
        updateTrackedProbeLifecycle()
    }

    private func logWriteAnomalies(
        _ anomalies: [WriteAnomaly],
        for key: WindowLiftAvoidance.WindowKey,
        terminal: Bool
    ) {
        for anomaly in anomalies.prefix(4) {
            let progress = String(format: "%.3f", anomaly.progress)
            let message = "lift animation anomaly pid=\(key.pid) wid=\(key.cgWindowID) progress=\(progress) reason=\(String(describing: anomaly.reason)) decision=\(String(describing: anomaly.decision)) rollback=\(String(describing: anomaly.rollback))"
            if terminal {
                logger.error("\(message, privacy: .public)")
            } else {
                logger.notice("\(message, privacy: .public)")
            }
        }
    }

    private func cancelWrites(except activePID: pid_t?) {
        for (key, task) in writeTasks where key.pid != activePID {
            task.cancel()
        }
    }

    private func removeStates(forPID pid: pid_t) {
        let keys = Set(states.keys).union(suppressedFrames.keys).filter { $0.pid == pid }
        for key in keys {
            clearManagedSession(for: key, cancelWriter: true, reason: "applicationTerminated")
        }
    }

    private func pruneDeadWindowStates(
        liveWindowKeys: Set<WindowLiftAvoidance.WindowKey>,
        observationGeneration: UInt64
    ) {
        let deadKeys = WindowLiftAvoidance.prunableDeadWindowKeys(
            tracked: Set(states.keys).union(suppressedFrames.keys),
            live: liveWindowKeys,
            observationGeneration: observationGeneration,
            observationWatermarks: observationWatermarks
        )
        for key in deadKeys {
            observationWatermarks[key] = observationGeneration
            clearManagedSession(for: key, cancelWriter: true, reason: "deadWindowPrune")
        }
    }

    private func restoreSettledWindowsAndClearSessions() {
        guard canMutateSessions() else { return }

        let cancelledWrites = Array(writeTasks.values) + writeDrainTasks.values.flatMap { $0 }
        for task in cancelledWrites { task.cancel() }
        writeTasks.removeAll()
        writeDrainTasks.removeAll()

        // Pending-restore data is owned by the controller as soon as it is enqueued, and an item is removed only after a successful restore -- so if permission is lost midway
        // the freeze mechanism can take over this data, and after authorization returns restore can continue.
        for (key, state) in states {
            guard let frames = managedFrames[key] else { continue }
            switch state {
            case .writing, .lifted, .abandoned:
                pendingRestorations[key] = frames
                pendingRestorationStartTimes[key] = ProcessLiveness.startTime(pid: key.pid)
            case .idle:
                break
            }
        }

        states.removeAll()
        sessionContexts.removeAll()
        managedFrames.removeAll()
        clearAllSuppressions()
        observationWatermarks.removeAll()
        validationGenerations.removeAll()
        lastTraceClassifications.removeAll()
        stopTrackedProbe()
        launchRestoreTask(cancelledWrites: cancelledWrites)
    }

    /// One pass over `pendingRestorations`, after `cancelledWrites` have drained. Scans and the
    /// tracked probe pause while it runs (`restoreTask`), so nothing re-lifts a window mid-restore.
    private func launchRestoreTask(cancelledWrites: [Task<Void, Never>]) {
        guard !pendingRestorations.isEmpty || !cancelledWrites.isEmpty, restoreTask == nil else {
            updatePollTimerLifecycle()
            return
        }

        restoreGeneration &+= 1
        let generation = restoreGeneration
        let items = pendingRestorations
        let startTimes = pendingRestorationStartTimes
        let animate = usesAnimatedLift
        let trace = traceEnabled
        restoreTask = Task.detached { [weak self] in
            // A cancelled AX call cannot be interrupted mid-message. Drain every old writer before
            // allowing the next context to scan, so a late rollback cannot overwrite a new lift.
            for task in cancelledWrites {
                await task.value
            }

            let reader = AXWindowReader()
            let liveWindowKeys = WindowLiftCGWindowProbe.liveWindowKeys()
            for (key, frames) in items {
                guard !Task.isCancelled else { break }
                let outcome = await Self.restoreOne(
                    key: key,
                    frames: frames,
                    expectedStartTime: startTimes[key],
                    reader: reader,
                    liveWindowKeys: liveWindowKeys,
                    animated: animate,
                    trace: trace
                )
                guard outcome == .handled else { continue }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.pendingRestorations.removeValue(forKey: key)
                    self.pendingRestorationStartTimes.removeValue(forKey: key)
                    if let userFrame = frames.userRestoreQuartz {
                        // Pin the memory to the requested frame, not the landing (see the init).
                        self.userFrames[key] = WindowLiftAvoidance.UserFrameMemory(
                            confirmed: WindowLiftAvoidance.appKitFrame(
                                fromQuartz: userFrame,
                                primaryScreenHeight: frames.primaryScreenHeight
                            ),
                            at: ProcessInfo.processInfo.systemUptime
                        )
                        if self.traceEnabled {
                            self.logger.info(
                                "lift trace user frame pinned pid=\(key.pid, privacy: .public) wid=\(key.cgWindowID, privacy: .public)"
                            )
                        }
                    }
                }
            }
            await MainActor.run { [weak self] in
                guard let self, self.restoreGeneration == generation else { return }
                self.restoreTask = nil
                // A user-frame restore queued while this pass ran gets its own pass.
                if self.pendingRestorations.keys.contains(where: { items[$0] == nil }) {
                    self.launchRestoreTask(cancelledWrites: [])
                    return
                }
                self.updatePollTimerLifecycle()
                if self.isEnabled { self.poll() }
            }
        }
        updatePollTimerLifecycle()
    }

    // MARK: - User zoom toggle

    /// Each tracked-probe tick samples the session-wide left-mouse-down counter; two downs within
    /// the double-click interval (or in one tick) are a double-click at the pointer's location.
    private func sampleClicks() {
        let count = CGEventSource.counterForEventType(.combinedSessionState, eventType: .leftMouseDown)
        guard let click = clickSampler.sample(
            count: count,
            location: NSEvent.mouseLocation,
            at: ProcessInfo.processInfo.systemUptime,
            doubleClickInterval: NSEvent.doubleClickInterval + Self.trackedProbeInterval
        ) else { return }
        lastDoubleClick = click
        if traceEnabled {
            logger.info(
                "lift trace double-click x=\(click.location.x, privacy: .public) y=\(click.location.y, privacy: .public)"
            )
        }
    }

    /// Every scan's on-screen list feeds the per-window user-frame memory: windows with no session
    /// and a non-eligible frame. Entries leave with the window (off screen, closed).
    private func rememberUserFrames(
        _ quartzFrames: [WindowLiftAvoidance.WindowKey: CGRect],
        contexts: [WindowLiftAvoidanceContext]
    ) {
        let now = ProcessInfo.processInfo.systemUptime
        let screenCGFrames = contexts.map(\.screenCGFrame)
        userFrames = userFrames.filter {
            quartzFrames[$0.key] != nil || states[$0.key] != nil || pendingRestorations[$0.key] != nil
        }
        for (key, quartzFrame) in quartzFrames {
            guard states[key] == nil,
                  pendingRestorations[key] == nil,
                  let index = WindowLiftAvoidance.owningContextIndex(
                      for: quartzFrame,
                      screenCGFrames: screenCGFrames
                  ) else { continue }
            let context = contexts[index]
            let frame = WindowLiftAvoidance.appKitFrame(
                fromQuartz: quartzFrame,
                primaryScreenHeight: context.primaryScreenHeight
            )
            guard !context.geometry.isLiftEligible(frame, includesTiles: includesTiles) else { continue }
            let before = userFrames[key]?.confirmed
            let candidateBefore = userFrames[key]?.candidate
            if userFrames[key] == nil {
                userFrames[key] = WindowLiftAvoidance.UserFrameMemory(frame: frame, at: now)
            } else {
                userFrames[key]?.observe(frame, at: now)
            }
            if traceEnabled, userFrames[key]?.candidate != candidateBefore {
                logger.info(
                    "lift trace user frame candidate pid=\(key.pid, privacy: .public) wid=\(key.cgWindowID, privacy: .public) was=\(String(describing: candidateBefore), privacy: .public) now=\(String(describing: frame), privacy: .public)"
                )
            }
            if traceEnabled, let after = userFrames[key]?.confirmed, after != before {
                logger.info(
                    "lift trace user frame confirmed pid=\(key.pid, privacy: .public) wid=\(key.cgWindowID, privacy: .public) frame=\(String(describing: after), privacy: .public)"
                )
            }
        }
    }

    /// A lifted window shows its native (maximized) frame again right after a double-click in its
    /// title region: that is the system zoom re-maximizing it instead of undoing the zoom (our
    /// lifted frame is "not zoomed"). Answer with the undo the user asked for. Only `.lifted`
    /// qualifies — during `.writing` the click that maximized the window cannot be told apart.
    private func restoreUserFrameIfZoomToggled(
        for key: WindowLiftAvoidance.WindowKey,
        state: WindowLiftAvoidance.SessionState,
        frames: ManagedFrames
    ) -> Bool {
        guard case let .lifted(session) = state,
              WindowLiftAvoidance.isUserZoomToggle(
                  lastDoubleClick,
                  liftedFrame: frames.targetAppKit,
                  settledAt: session.settledAt,
                  at: ProcessInfo.processInfo.systemUptime
              ) else {
            return false
        }
        lastDoubleClick = nil
        guard let userFrame = userFrames[key]?.confirmed else {
            if traceEnabled {
                logger.info(
                    "lift trace zoom toggle without a user frame pid=\(key.pid, privacy: .public) wid=\(key.cgWindowID, privacy: .public)"
                )
            }
            return false
        }
        restoreUserFrame(userFrame, for: key, frames: frames)
        return true
    }

    /// Puts the window where the system zoom's undo would have: its remembered pre-maximize frame.
    /// Rides the stop-path restore queue so no scan lifts it again before the write lands.
    private func restoreUserFrame(
        _ userFrame: CGRect,
        for key: WindowLiftAvoidance.WindowKey,
        frames: ManagedFrames
    ) {
        guard canMutateSessions() else { return }
        clearManagedSession(for: key, cancelWriter: true, reason: "userZoomToggle")
        let cancelledWrites = writeDrainTasks.removeValue(forKey: key) ?? []
        pendingRestorations[key] = ManagedFrames(
            nativeAppKit: frames.nativeAppKit,
            targetAppKit: frames.targetAppKit,
            nativeQuartz: frames.nativeQuartz,
            targetQuartz: frames.targetQuartz,
            primaryScreenHeight: frames.primaryScreenHeight,
            userRestoreQuartz: WindowLiftAvoidance.quartzFrame(
                fromAppKit: userFrame,
                primaryScreenHeight: frames.primaryScreenHeight
            )
        )
        pendingRestorationStartTimes[key] = ProcessLiveness.startTime(pid: key.pid)
        logger.notice(
            "lift user zoom toggle pid=\(key.pid, privacy: .public) wid=\(key.cgWindowID, privacy: .public) restore=\(String(describing: userFrame), privacy: .public)"
        )
        launchRestoreTask(cancelledWrites: cancelledWrites)
    }

    /// Restoring only after a long freeze means anything may have changed in between, so every item must be re-verified:
    /// whether the process was swapped (pid reuse), whether the window still exists (cgWindowID reuse),
    /// whether the user moved it themselves. If any check doesn't match, discard it and never force a change.
    nonisolated private static func restoreOne(
        key: WindowLiftAvoidance.WindowKey,
        frames: ManagedFrames,
        expectedStartTime: timeval?,
        reader: AXWindowReader,
        liveWindowKeys: Set<WindowLiftAvoidance.WindowKey>?,
        animated: Bool,
        trace: Bool
    ) async -> RestoreOutcome {
        if let expected = expectedStartTime {
            guard let current = ProcessLiveness.startTime(pid: key.pid),
                  current.tv_sec == expected.tv_sec,
                  current.tv_usec == expected.tv_usec else {
                return .handled
            }
        }
        if liveWindowKeys?.contains(key) == false { return .handled }

        guard let handle = reader.captureHandle(
                  forPID: key.pid,
                  cgWindowID: key.cgWindowID,
                  messagingTimeout: windowLiftAXMessagingTimeout
              ),
              let currentAXFrame = reader.frame(
                  of: handle.element,
                  messagingTimeout: windowLiftAXMessagingTimeout
              ) else {
            // Most likely Accessibility permission isn't granted yet. Leave it in the queue and restore once authorization returns.
            return .unreachable
        }

        let currentAppKitFrame = WindowLiftAvoidance.appKitFrame(
            fromQuartz: currentAXFrame,
            primaryScreenHeight: frames.primaryScreenHeight
        )
        switch WindowLiftAvoidance.frameClassification(
            of: currentAppKitFrame,
            nativeFrame: frames.nativeAppKit,
            targetFrame: frames.targetAppKit
        ) {
        case .target, .managedTrajectory:
            break
        case .native:
            // The native frame is where a plain restore wants the window; a user-zoom-toggle
            // restore finds it there and still has to move it.
            guard frames.userRestoreQuartz != nil else { return .handled }
        case .external:
            return .handled
        }

        if let userFrame = frames.userRestoreQuartz, animated {
            await animateUserRestore(
                reader: reader,
                element: handle.element,
                key: key,
                from: currentAXFrame,
                to: userFrame,
                trace: trace
            )
            return .handled
        }
        let result = reader.setFrame(
            frames.userRestoreQuartz ?? frames.nativeQuartz,
            for: handle.element,
            messagingTimeout: windowLiftAXMessagingTimeout,
            verificationTolerance: WindowLiftAvoidance.verificationTolerance,
            onlyIfCurrentMatches: currentAXFrame,
            restoreOnFailureTo: currentAXFrame
        )
        if trace, frames.userRestoreQuartz != nil {
            restoreLogger.info(
                "lift user zoom restore mode=instant pid=\(key.pid, privacy: .public) wid=\(key.cgWindowID, privacy: .public) result=\(String(describing: result), privacy: .public)"
            )
        }
        return .handled
    }

    /// The system's undo-zoom is animated; so is ours. Every write is preconditioned on the last
    /// frame we confirmed. A mismatch whose actual frame already sits on the end frame is done; one
    /// still inside the start→end envelope is the app applying late (stall ≠ failure, as in the lift
    /// loop) and the animation continues; one outside it is a takeover by the user or the app and
    /// the animation stops without forcing the end frame. Scans and the tracked probe are paused
    /// for the whole run (`restoreTask`); how long that is depends on the app's AX responsiveness.
    nonisolated private static func animateUserRestore(
        reader: AXWindowReader,
        element: AXUIElement,
        key: WindowLiftAvoidance.WindowKey,
        from start: CGRect,
        to end: CGRect,
        trace: Bool
    ) async {
        enum Step { case proceed, done, takeover }
        let duration = WindowLiftAvoidance.userRestoreAnimationDuration
        let frameInterval = 1.0 / WindowLiftAvoidance.animationFramesPerSecond
        let startedAt = ProcessInfo.processInfo.systemUptime
        var nextDeadline = startedAt + frameInterval
        var lastAcknowledged = start
        var writtenFrames = 0

        func absorb(_ result: AXWindowFrameWriteResult) -> Step {
            switch result {
            case let .success(actual):
                lastAcknowledged = actual
                writtenFrames += 1
                return WindowLiftAvoidance.framesMatch(actual, end) ? .done : .proceed
            case let .failure(.initialFrameMismatch(_, actual), _),
                 let .failure(.verificationMismatch(_, actual), _):
                switch WindowLiftAvoidance.userRestoreObservation(actual, from: start, to: end) {
                case .reached:
                    lastAcknowledged = actual
                    return .done
                case .late:
                    lastAcknowledged = actual
                    return .proceed
                case .takeover:
                    return .takeover
                }
            case .failure:
                // Unreadable or unwritable this frame: skip it, the loop is time-bounded.
                return .proceed
            }
        }
        func finish(_ step: Step) {
            guard trace else { return }
            let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
            restoreLogger.info(
                "lift user zoom restore mode=animated outcome=\(step == .done ? "done" : "takeover", privacy: .public) pid=\(key.pid, privacy: .public) wid=\(key.cgWindowID, privacy: .public) frames=\(writtenFrames, privacy: .public) elapsed=\(elapsed, privacy: .public) last=\(String(describing: lastAcknowledged), privacy: .public)"
            )
        }
        func write(_ frame: CGRect) -> Step {
            absorb(reader.setFrame(
                frame,
                for: element,
                messagingTimeout: windowLiftAXMessagingTimeout,
                verificationTolerance: WindowLiftAvoidance.verificationTolerance,
                onlyIfCurrentMatches: lastAcknowledged,
                restoreOnFailureTo: nil
            ))
        }

        while ProcessInfo.processInfo.systemUptime - startedAt < duration {
            let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
            let frame = WindowLiftAvoidance.userRestoreFrame(
                from: start,
                to: end,
                progress: elapsed / duration
            )
            let step = write(frame)
            if step != .proceed {
                finish(step)
                return
            }
            let sleepDuration = nextDeadline - ProcessInfo.processInfo.systemUptime
            nextDeadline += frameInterval
            if sleepDuration > 0 {
                try? await Task.sleep(nanoseconds: UInt64(sleepDuration * 1_000_000_000))
            }
        }
        for attempt in 0..<3 {
            let step = write(end)
            if step != .proceed {
                finish(step)
                return
            }
            if attempt < 2 {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        restoreLogger.notice(
            "lift user zoom restore incomplete pid=\(key.pid, privacy: .public) wid=\(key.cgWindowID, privacy: .public) frames=\(writtenFrames, privacy: .public) last=\(String(describing: lastAcknowledged), privacy: .public)"
        )
    }

    private func store(
        _ state: WindowLiftAvoidance.SessionState,
        for key: WindowLiftAvoidance.WindowKey
    ) {
        let previous = states[key] ?? .idle
        if state == .idle {
            states.removeValue(forKey: key)
            lastTraceClassifications.removeValue(forKey: key)
        } else {
            states[key] = state
        }
        if traceEnabled, traceLabel(for: previous) != traceLabel(for: state) {
            let previousLabel = traceLabel(for: previous)
            let stateLabel = traceLabel(for: state)
            logger.info(
                "lift trace transition pid=\(key.pid, privacy: .public) wid=\(key.cgWindowID, privacy: .public) from=\(previousLabel, privacy: .public) to=\(stateLabel, privacy: .public)"
            )
        }
        updateTrackedProbeLifecycle()
        updatePollTimerLifecycle()
    }

    private func clearManagedSession(
        for key: WindowLiftAvoidance.WindowKey,
        cancelWriter: Bool,
        reason: String,
        suppression: SuppressionRequest = .none
    ) {
        guard canMutateSessions() else {
            // During freeze only drop task references; leave session data entirely untouched.
            if let writer = writeTasks.removeValue(forKey: key) {
                if cancelWriter { writer.cancel() }
                pendingDrains.append(writer)
            }
            return
        }
        if cancelWriter, let writer = writeTasks.removeValue(forKey: key) {
            writer.cancel()
            writeDrainTasks[key, default: []].append(writer)
        } else {
            writeTasks.removeValue(forKey: key)
        }
        observationWatermarks[key] = max(
            observationWatermarks[key] ?? 0,
            nextGeneration
        )
        validationGenerations.removeValue(forKey: key)
        let previous = states.removeValue(forKey: key)
        let frames = managedFrames.removeValue(forKey: key)
        if case let .untilNative(userEra) = suppression, let frames {
            setSuppression(frames, userEra: userEra, for: key)
        } else {
            clearSuppression(for: key)
        }
        lastTraceClassifications.removeValue(forKey: key)
        if traceEnabled, previous != nil {
            logger.info(
                "lift trace clear pid=\(key.pid, privacy: .public) wid=\(key.cgWindowID, privacy: .public) reason=\(reason, privacy: .public)"
            )
        }
        updateTrackedProbeLifecycle()
        updatePollTimerLifecycle()
    }

    private func setSuppression(
        _ frames: ManagedFrames,
        userEra: Bool,
        for key: WindowLiftAvoidance.WindowKey
    ) {
        suppressedFrames[key] = frames
        if userEra {
            userEraSuppressedKeys.insert(key)
        } else {
            userEraSuppressedKeys.remove(key)
        }
    }

    private func clearSuppression(for key: WindowLiftAvoidance.WindowKey) {
        suppressedFrames.removeValue(forKey: key)
        userEraSuppressedKeys.remove(key)
    }

    private func clearAllSuppressions() {
        suppressedFrames.removeAll()
        userEraSuppressedKeys.removeAll()
    }

    private func traceClassification(
        _ classification: WindowLiftAvoidance.FrameClassification,
        for key: WindowLiftAvoidance.WindowKey
    ) {
        guard traceEnabled, lastTraceClassifications[key] != classification else { return }
        lastTraceClassifications[key] = classification
        logger.info(
            "lift trace classify pid=\(key.pid, privacy: .public) wid=\(key.cgWindowID, privacy: .public) frame=\(String(describing: classification), privacy: .public)"
        )
    }

    private func traceLabel(for state: WindowLiftAvoidance.SessionState) -> String {
        switch state {
        case .idle:
            return "idle"
        case let .writing(attempt):
            return "writing(reliftCount:\(attempt.reliftCount))"
        case let .lifted(session):
            return "lifted(reliftCount:\(session.reliftCount))"
        case let .abandoned(session):
            return "abandoned(reason:\(String(describing: session.reason)),reliftCount:\(session.reliftCount))"
        }
    }
}
