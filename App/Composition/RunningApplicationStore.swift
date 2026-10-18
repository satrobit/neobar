import AppKit
import Combine
import Foundation
import os

/// Process-state projection for app-level launcher chips.
///
/// `AppTracker` remains the sole window-inventory authority and intentionally omits
/// ordinary apps with no eligible windows. This store independently observes regular
/// `NSRunningApplication` processes so a pinned icon can still show running/hidden
/// state after its last window closes. It never reads or mutates a window snapshot.
@MainActor
final class RunningApplicationStore: ObservableObject {
    @Published private(set) var runningBundleIDs: Set<String> = []
    @Published private(set) var hiddenBundleIDs: Set<String> = []

    typealias ProcessGeneration = RunningStateSweepDecision.Generation

    private struct ProcessIdentity: Equatable {
        let generation: ProcessGeneration
        let bundleID: String
    }

    private struct ProcessState: Equatable {
        let identity: ProcessIdentity
        let bundleID: String
        var isHidden: Bool
    }

    private struct PolicyRecheck {
        let identity: ProcessIdentity
        let token: UUID
        var application: NSRunningApplication
        var removeTrackedOnNextNonRegularConfirmation: Bool
        let task: Task<Void, Never>
    }

    private struct TerminationRecheck {
        let generation: ProcessGeneration
        let token: UUID
        let task: Task<Void, Never>
    }

    /// KVO on a tracked process's `activationPolicy`. Books quits into a `.prohibited` resident
    /// and a menu-bar app drops back to `.accessory` when its settings window closes; neither
    /// posts a workspace notification, so without this the running dot outlives the Dock icon
    /// until some unrelated activation finally runs a sweep.
    ///
    /// Holds the `NSRunningApplication` strongly: the instances handed out by workspace
    /// notifications and `runningApplications` are transient, and an observed one deallocating
    /// under a live observation crashes the process (AppKit logs "being deallocated while
    /// observers are still registered" first). `deinit` invalidates before the object is released,
    /// so every removal path — prune, `stop()`, store deinit — unregisters in the right order.
    private final class PolicyObservation {
        let identity: ProcessIdentity
        let application: NSRunningApplication
        let observation: NSKeyValueObservation

        init(identity: ProcessIdentity, application: NSRunningApplication, observation: NSKeyValueObservation) {
            self.identity = identity
            self.application = application
            self.observation = observation
        }

        deinit {
            observation.invalidate()
        }
    }

    /// Absolute retry times are 0.2/0.5/1/2/4/8/12/20s after the notification.
    /// The final bound matches the launch-session fallback: after that the UI has already
    /// stopped presenting the process as an active launch.
    private static let policyRecheckSleepNanoseconds: [UInt64] = [
        200_000_000,
        300_000_000,
        500_000_000,
        1_000_000_000,
        2_000_000_000,
        4_000_000_000,
        4_000_000_000,
        8_000_000_000,
    ]

    /// Absolute retry times are 0.05s, 0.15s, 0.5s, 1s, and 2s after termination.
    private static let terminationRecheckSleepNanoseconds: [UInt64] = [
        50_000_000,
        100_000_000,
        350_000_000,
        500_000_000,
        1_000_000_000,
    ]
    private static let terminationSlowRecheckNanoseconds: UInt64 = 5_000_000_000
    private static let workspaceSweepInterval: TimeInterval = 2.0

    private let workspace: NSWorkspace
    private let generationProvider: (pid_t) -> ProcessGeneration?
    private let workspaceObservationProvider: (() -> [RunningStateSweepDecision.Observation])?
    private let uptimeProvider: () -> TimeInterval
    private var processesByPID: [pid_t: ProcessState] = [:]
    private var policyObservationsByPID: [pid_t: PolicyObservation] = [:]
    private var policyRechecksByPID: [pid_t: PolicyRecheck] = [:]
    private var terminationRechecksByPID: [pid_t: TerminationRecheck] = [:]
    private var observers: [NSObjectProtocol] = []
    private var pendingWorkspaceSweepTask: Task<Void, Never>?
    private var lastWorkspaceSweepAt: TimeInterval?
    private var isStarted = false
    private let logger = Logger(subsystem: "app.neobar.NeoBar", category: "running-state")

    init(
        workspace: NSWorkspace = .shared,
        generationProvider: ((pid_t) -> ProcessGeneration?)? = nil,
        workspaceObservationProvider: (() -> [RunningStateSweepDecision.Observation])? = nil,
        uptimeProvider: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.workspace = workspace
        self.generationProvider = generationProvider ?? { pid in
            guard ProcessLiveness.isAlive(pid: pid),
                  let startTime = ProcessLiveness.startTime(pid: pid) else { return nil }
            return ProcessGeneration(
                pid: pid,
                startTimeSeconds: Int64(startTime.tv_sec),
                startTimeMicroseconds: Int64(startTime.tv_usec)
            )
        }
        self.workspaceObservationProvider = workspaceObservationProvider
        self.uptimeProvider = uptimeProvider
    }

    deinit {
        for recheck in policyRechecksByPID.values {
            recheck.task.cancel()
        }
        for recheck in terminationRechecksByPID.values {
            recheck.task.cancel()
        }
        pendingWorkspaceSweepTask?.cancel()
        for observer in observers {
            workspace.notificationCenter.removeObserver(observer)
        }
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        subscribeWorkspaceNotifications()
        if workspaceObservationProvider == nil {
            seedRunningApplications()
        } else {
            reconcileWithWorkspace()
        }
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        for observer in observers {
            workspace.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
        cancelAllPolicyRechecks()
        cancelAllTerminationRechecks()
        pendingWorkspaceSweepTask?.cancel()
        pendingWorkspaceSweepTask = nil
        lastWorkspaceSweepAt = nil
        processesByPID.removeAll()
        publishProjection()
    }

    func isRunning(_ bundleID: String) -> Bool {
        runningBundleIDs.contains(bundleID)
    }

    func isHidden(_ bundleID: String) -> Bool {
        hiddenBundleIDs.contains(bundleID)
    }

    private func seedRunningApplications() {
        processesByPID.removeAll()
        for application in workspace.runningApplications {
            handleAdmissionCandidate(application, publishImmediately: false)
        }
        publishProjection()
    }

    private func subscribeWorkspaceNotifications() {
        let notificationCenter = workspace.notificationCenter

        observers.append(notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = Self.application(from: notification) else { return }
            Task { @MainActor [weak self] in
                guard let self, self.isStarted else { return }
                self.handleAdmissionCandidate(application)
                self.requestWorkspaceSweep()
            }
        })

        observers.append(notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = Self.application(from: notification) else { return }
            Task { @MainActor [weak self] in
                guard let self, self.isStarted else { return }
                self.handleAdmissionCandidate(application)
                self.requestWorkspaceSweep()
            }
        })

        observers.append(notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = Self.application(from: notification) else { return }
            Task { @MainActor [weak self] in
                guard let self, self.isStarted else { return }
                self.handleTermination(application)
                self.publishProjection()
                self.requestWorkspaceSweep()
            }
        })

        observers.append(notificationCenter.addObserver(
            forName: NSWorkspace.didHideApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = Self.application(from: notification) else { return }
            Task { @MainActor [weak self] in
                guard let self, self.isStarted else { return }
                self.update(application, isHidden: true)
                self.publishProjection()
            }
        })

        observers.append(notificationCenter.addObserver(
            forName: NSWorkspace.didUnhideApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = Self.application(from: notification) else { return }
            Task { @MainActor [weak self] in
                guard let self, self.isStarted else { return }
                self.update(application, isHidden: false)
                self.publishProjection()
            }
        })

        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(notificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.isStarted else { return }
                    self.requestWorkspaceSweep(force: true)
                }
            })
        }
    }

    private func handleAdmissionCandidate(
        _ application: NSRunningApplication,
        publishImmediately: Bool = true
    ) {
        if upsert(application) {
            cancelPolicyRecheck(forPID: application.processIdentifier)
            if publishImmediately {
                publishProjection()
            }
            return
        }

        guard application.activationPolicy != .regular,
              let identity = processIdentity(for: application) else { return }
        let removedStaleProcess = evictStaleProcessState(for: identity)
        schedulePolicyRechecks(for: application, identity: identity)
        if removedStaleProcess, publishImmediately {
            publishProjection()
        }
    }

    @discardableResult
    private func upsert(
        _ application: NSRunningApplication,
        expectedIdentity: ProcessIdentity? = nil
    ) -> Bool {
        guard application.activationPolicy == .regular,
              let identity = processIdentity(for: application),
              expectedIdentity == nil || expectedIdentity == identity else { return false }
        evictStaleProcessState(for: identity)
        cancelTerminationRecheck(forPID: application.processIdentifier)
        processesByPID[application.processIdentifier] = ProcessState(
            identity: identity,
            bundleID: identity.bundleID,
            isHidden: application.isHidden
        )
        observePolicy(of: application, identity: identity)
        return true
    }

    @discardableResult
    private func evictStaleProcessState(for identity: ProcessIdentity) -> Bool {
        let pid = identity.generation.pid
        guard let state = processesByPID[pid],
              state.identity.generation != identity.generation else { return false }
        processesByPID.removeValue(forKey: pid)
        return true
    }

    private func update(_ application: NSRunningApplication, isHidden: Bool) {
        let pid = application.processIdentifier
        guard application.activationPolicy == .regular,
              let identity = processIdentity(for: application) else {
            processesByPID.removeValue(forKey: pid)
            return
        }

        if var state = processesByPID[pid] {
            guard state.identity == identity else { return }
            state.isHidden = isHidden
            processesByPID[pid] = state
            return
        }
        processesByPID[pid] = ProcessState(
            identity: identity,
            bundleID: identity.bundleID,
            isHidden: isHidden
        )
        observePolicy(of: application, identity: identity)
    }

    private func handleTermination(_ application: NSRunningApplication) {
        let pid = application.processIdentifier
        let currentGeneration = processGeneration(pid: pid)

        guard let currentGeneration else {
            processesByPID.removeValue(forKey: pid)
            cancelPolicyRecheck(forPID: pid)
            cancelTerminationRecheck(forPID: pid)
            return
        }

        if let state = processesByPID[pid], state.identity.generation != currentGeneration {
            processesByPID.removeValue(forKey: pid)
        }

        if let recheck = policyRechecksByPID[pid],
           recheck.identity.generation != currentGeneration || recheck.application === application {
            cancelPolicyRecheck(forPID: pid)
        }

        guard processesByPID[pid]?.identity.generation == currentGeneration else {
            cancelTerminationRecheck(forPID: pid)
            return
        }
        scheduleTerminationRechecks(pid: pid, generation: currentGeneration)
    }

    private func schedulePolicyRechecks(
        for application: NSRunningApplication,
        identity: ProcessIdentity,
        removeTrackedOnNextNonRegularConfirmation: Bool = false
    ) {
        let pid = identity.generation.pid
        if !removeTrackedOnNextNonRegularConfirmation {
            cancelTerminationRecheck(forPID: pid)
        }
        if var existing = policyRechecksByPID[pid], existing.identity == identity {
            existing.application = application
            existing.removeTrackedOnNextNonRegularConfirmation =
                existing.removeTrackedOnNextNonRegularConfirmation
                    || removeTrackedOnNextNonRegularConfirmation
            policyRechecksByPID[pid] = existing
            return
        }

        cancelPolicyRecheck(forPID: pid)
        let token = UUID()
        let task = Task { @MainActor [weak self] in
            for sleepNanoseconds in Self.policyRecheckSleepNanoseconds {
                do {
                    try await Task.sleep(nanoseconds: sleepNanoseconds)
                } catch {
                    return
                }

                guard let self else { return }
                guard self.recheckPolicy(identity: identity, token: token) else { return }
            }
            self?.cancelPolicyRecheck(forPID: pid, token: token)
        }
        policyRechecksByPID[pid] = PolicyRecheck(
            identity: identity,
            token: token,
            application: application,
            removeTrackedOnNextNonRegularConfirmation: removeTrackedOnNextNonRegularConfirmation,
            task: task
        )
    }

    /// Returns true while the bounded retry sequence should continue.
    private func recheckPolicy(identity: ProcessIdentity, token: UUID) -> Bool {
        let pid = identity.generation.pid
        guard isStarted,
              let recheck = policyRechecksByPID[pid],
              recheck.token == token,
              recheck.identity == identity,
              processGeneration(pid: pid) == identity.generation,
              recheck.application.processIdentifier == pid,
              recheck.application.bundleIdentifier == identity.bundleID else {
            cancelPolicyRecheck(forPID: pid, token: token)
            return false
        }

        guard recheck.application.activationPolicy == .regular else {
            if recheck.removeTrackedOnNextNonRegularConfirmation {
                confirmNonRegular(
                    pid: pid,
                    generation: identity.generation,
                    bundleID: identity.bundleID
                )
                if var current = policyRechecksByPID[pid], current.token == token {
                    current.removeTrackedOnNextNonRegularConfirmation = false
                    policyRechecksByPID[pid] = current
                }
            }
            return true
        }
        guard upsert(recheck.application, expectedIdentity: identity) else {
            cancelPolicyRecheck(forPID: pid, token: token)
            return false
        }

        cancelPolicyRecheck(forPID: pid, token: token)
        publishProjection()
        return false
    }

    private func scheduleTerminationRechecks(pid: pid_t, generation: ProcessGeneration) {
        if terminationRechecksByPID[pid]?.generation == generation { return }

        cancelTerminationRecheck(forPID: pid)
        let token = UUID()
        let task = Task { @MainActor [weak self] in
            for sleepNanoseconds in Self.terminationRecheckSleepNanoseconds {
                do {
                    try await Task.sleep(nanoseconds: sleepNanoseconds)
                } catch {
                    return
                }

                guard let self else { return }
                guard self.recheckTermination(generation: generation, token: token) else { return }
            }
            // A didTerminate notification can precede POSIX disappearance while an app
            // performs a long shutdown. Keep a very cheap liveness check until that exact
            // process generation is gone; otherwise the running projection can stay stale
            // forever because there will be no second termination notification.
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: Self.terminationSlowRecheckNanoseconds)
                } catch {
                    return
                }
                guard let self else { return }
                guard self.recheckTermination(generation: generation, token: token) else { return }
            }
        }
        terminationRechecksByPID[pid] = TerminationRecheck(
            generation: generation,
            token: token,
            task: task
        )
    }

    /// Returns true while the bounded liveness recheck sequence should continue.
    private func recheckTermination(generation: ProcessGeneration, token: UUID) -> Bool {
        let pid = generation.pid
        guard isStarted,
              let recheck = terminationRechecksByPID[pid],
              recheck.token == token,
              recheck.generation == generation else {
            cancelTerminationRecheck(forPID: pid, token: token)
            return false
        }

        guard processGeneration(pid: pid) == generation else {
            if processesByPID[pid]?.identity.generation == generation {
                processesByPID.removeValue(forKey: pid)
                publishProjection()
            }
            cancelTerminationRecheck(forPID: pid, token: token)
            return false
        }
        return true
    }

    private func processIdentity(for application: NSRunningApplication) -> ProcessIdentity? {
        guard let bundleID = application.bundleIdentifier, !bundleID.isEmpty,
              let generation = processGeneration(pid: application.processIdentifier) else { return nil }
        return ProcessIdentity(generation: generation, bundleID: bundleID)
    }

    private func processGeneration(pid: pid_t) -> ProcessGeneration? {
        generationProvider(pid)
    }

    /// Event-driven full reconciliation. A short one-shot task coalesces ordinary workspace
    /// notifications; wake/session-resume bypass it because those are the notification-loss boundary.
    private func requestWorkspaceSweep(force: Bool = false) {
        guard isStarted else { return }
        let now = uptimeProvider()
        if force || lastWorkspaceSweepAt == nil
            || now - (lastWorkspaceSweepAt ?? now) >= Self.workspaceSweepInterval {
            pendingWorkspaceSweepTask?.cancel()
            pendingWorkspaceSweepTask = nil
            reconcileWithWorkspace()
            return
        }

        guard pendingWorkspaceSweepTask == nil, let lastWorkspaceSweepAt else { return }
        let delay = max(0, Self.workspaceSweepInterval - (now - lastWorkspaceSweepAt))
        pendingWorkspaceSweepTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                return
            }
            guard let self, self.isStarted else { return }
            self.pendingWorkspaceSweepTask = nil
            self.reconcileWithWorkspace()
        }
    }

    /// Internal for deterministic store tests; production callers go through the throttled request path.
    func reconcileWithWorkspace() {
        guard isStarted else { return }
        lastWorkspaceSweepAt = uptimeProvider()

        let liveApplications = workspaceObservationProvider == nil ? workspace.runningApplications : []
        let observations: [RunningStateSweepDecision.Observation]
        if let workspaceObservationProvider {
            observations = workspaceObservationProvider()
        } else {
            observations = liveApplications.compactMap { application in
                let pid = application.processIdentifier
                guard let bundleID = application.bundleIdentifier, !bundleID.isEmpty,
                      let generation = processGeneration(pid: pid) else { return nil }
                return RunningStateSweepDecision.Observation(
                    generation: generation,
                    bundleID: bundleID,
                    isHidden: application.isHidden,
                    activationPolicy: application.activationPolicy == .regular ? .regular : .nonRegular
                )
            }
        }
        let observationsByPID = Dictionary(observations.map { ($0.generation.pid, $0) },
                                           uniquingKeysWith: { first, _ in first })
        let trackedByPID = processesByPID.mapValues { state in
            RunningStateSweepDecision.Tracked(
                generation: state.identity.generation,
                bundleID: state.bundleID,
                isHidden: state.isHidden
            )
        }
        // The generation in the observation was just sampled, so **reuse it directly**; only re-sample the pids that are "tracked but not observed this round".
        // Re-sampling everything is dozens to hundreds of processes x two system calls, and this runs on the main thread and may run on every app switch.
        var currentGenerations: [pid_t: ProcessGeneration?] = observationsByPID.mapValues { Optional($0.generation) }
        for pid in trackedByPID.keys where !currentGenerations.keys.contains(pid) {
            currentGenerations[pid] = processGeneration(pid: pid)
        }
        let plan = RunningStateSweepDecision.plan(
            trackedByPID: trackedByPID,
            observationsByPID: observationsByPID,
            currentGenerationsByPID: currentGenerations
        )
        let applicationsByPID = Dictionary(liveApplications.map { ($0.processIdentifier, $0) },
                                           uniquingKeysWith: { first, _ in first })
        apply(plan, applicationsByPID: applicationsByPID)
    }

    /// Shared tail of the full workspace sweep and the one-process KVO sweep.
    private func apply(
        _ plan: RunningStateSweepDecision.Plan,
        applicationsByPID: [pid_t: NSRunningApplication]
    ) {
        for removal in plan.removals {
            guard processesByPID[removal.pid]?.identity.generation == removal.generation else { continue }
            processesByPID.removeValue(forKey: removal.pid)
            cancelPolicyRecheck(forPID: removal.pid)
            cancelTerminationRecheck(forPID: removal.pid)
        }
        for observation in plan.regularUpserts {
            let identity = ProcessIdentity(generation: observation.generation, bundleID: observation.bundleID)
            evictStaleProcessState(for: identity)
            cancelPolicyRecheck(forPID: observation.generation.pid)
            processesByPID[observation.generation.pid] = ProcessState(
                identity: identity,
                bundleID: observation.bundleID,
                isHidden: observation.isHidden
            )
            if let application = applicationsByPID[observation.generation.pid] {
                observePolicy(of: application, identity: identity)
            }
        }
        for observation in plan.nonRegularConfirmations {
            guard let application = applicationsByPID[observation.generation.pid] else { continue }
            schedulePolicyRechecks(
                for: application,
                identity: ProcessIdentity(
                    generation: observation.generation,
                    bundleID: observation.bundleID
                ),
                removeTrackedOnNextNonRegularConfirmation: true
            )
        }
        publishProjection()
    }

    func confirmNonRegular(pid: pid_t, generation: ProcessGeneration, bundleID: String) {
        guard let state = processesByPID[pid],
              state.identity.generation == generation,
              state.bundleID == bundleID else { return }
        processesByPID.removeValue(forKey: pid)
        logger.info("non-regular confirmed: pid=\(pid) \(bundleID, privacy: .public) dropped from the running projection")
        publishProjection()
    }

    // MARK: - Activation Policy Observation

    private func observePolicy(of application: NSRunningApplication, identity: ProcessIdentity) {
        let pid = identity.generation.pid
        if policyObservationsByPID[pid]?.identity == identity { return }
        let observation = application.observe(\.activationPolicy) { [weak self] application, _ in
            Task { @MainActor [weak self] in
                self?.handlePolicyChange(application, identity: identity)
            }
        }
        policyObservationsByPID[pid] = PolicyObservation(
            identity: identity,
            application: application,
            observation: observation
        )
    }

    /// A one-process sweep through the same pure plan as the full sweep: a flip back to
    /// `.regular` is an ordinary upsert, an explicit non-regular policy enters the existing
    /// recheck-then-confirm sequence (0.2s later, same generation and bundle), and an
    /// unreadable observation is unknown and changes nothing.
    private func handlePolicyChange(_ application: NSRunningApplication, identity: ProcessIdentity) {
        let pid = identity.generation.pid
        guard isStarted, let state = processesByPID[pid], state.identity == identity else { return }
        let currentGeneration = processGeneration(pid: pid)
        var observationsByPID: [pid_t: RunningStateSweepDecision.Observation] = [:]
        if let currentGeneration,
           let bundleID = application.bundleIdentifier, !bundleID.isEmpty {
            let isRegular = application.activationPolicy == .regular
            observationsByPID[pid] = RunningStateSweepDecision.Observation(
                generation: currentGeneration,
                bundleID: bundleID,
                isHidden: application.isHidden,
                activationPolicy: isRegular ? .regular : .nonRegular
            )
            if !isRegular {
                logger.info("policy left .regular: pid=\(pid) \(bundleID, privacy: .public), confirming before dropping the running dot")
            }
        }
        let plan = RunningStateSweepDecision.plan(
            trackedByPID: [pid: RunningStateSweepDecision.Tracked(
                generation: state.identity.generation,
                bundleID: state.bundleID,
                isHidden: state.isHidden
            )],
            observationsByPID: observationsByPID,
            currentGenerationsByPID: [pid: currentGeneration]
        )
        apply(plan, applicationsByPID: [pid: application])
    }

    private func cancelPolicyRecheck(forPID pid: pid_t, token: UUID? = nil) {
        guard let recheck = policyRechecksByPID[pid],
              token == nil || recheck.token == token else { return }
        policyRechecksByPID.removeValue(forKey: pid)
        recheck.task.cancel()
    }

    private func cancelAllPolicyRechecks() {
        let rechecks = Array(policyRechecksByPID.values)
        policyRechecksByPID.removeAll()
        for recheck in rechecks {
            recheck.task.cancel()
        }
    }

    private func cancelTerminationRecheck(forPID pid: pid_t, token: UUID? = nil) {
        guard let recheck = terminationRechecksByPID[pid],
              token == nil || recheck.token == token else { return }
        terminationRechecksByPID.removeValue(forKey: pid)
        recheck.task.cancel()
    }

    private func cancelAllTerminationRechecks() {
        let rechecks = Array(terminationRechecksByPID.values)
        terminationRechecksByPID.removeAll()
        for recheck in rechecks {
            recheck.task.cancel()
        }
    }

    private func publishProjection() {
        // Every removal path ends here; dropping the entry invalidates its KVO observation.
        policyObservationsByPID = policyObservationsByPID.filter { pid, observation in
            processesByPID[pid]?.identity == observation.identity
        }
        let grouped = Dictionary(grouping: processesByPID.values, by: \ProcessState.bundleID)
        let nextRunning = Set(grouped.keys)
        let nextHidden = Set(grouped.compactMap { bundleID, processes in
            processes.allSatisfy(\.isHidden) ? bundleID : nil
        })

        if runningBundleIDs != nextRunning {
            runningBundleIDs = nextRunning
        }
        if hiddenBundleIDs != nextHidden {
            hiddenBundleIDs = nextHidden
        }
    }

    private nonisolated static func application(from notification: Notification) -> NSRunningApplication? {
        notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
    }
}
