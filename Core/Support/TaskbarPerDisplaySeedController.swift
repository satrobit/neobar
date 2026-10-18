import Foundation

/// Owns only the one-shot seed decision and its bounded UUID-read retries.
/// Panel creation stays in `TaskbarScreenOrchestrator`.
@MainActor
final class TaskbarPerDisplaySeedController {
    typealias ScheduleAfter = (
        _ delay: TimeInterval,
        _ action: @escaping () -> Void
    ) -> DispatchWorkItem

    private static let retryDelays: [TimeInterval] = [0.5, 2.0]

    private let snapshotProvider: @MainActor () -> ScreenTopologySnapshot
    private let isSeedPending: () -> Bool
    private let hasStoredPlacementChoice: () -> Bool
    private let applySnapshot: (ScreenTopologySnapshot) -> Void
    private let applySeed: () -> Void
    private let consumeWithoutSeeding: () -> Void
    private let onRetrySeeded: (ScreenTopologySnapshot) -> Void
    private let scheduleAfter: ScheduleAfter

    private var retryGeneration = 0
    private var retryWorkItems: [DispatchWorkItem] = []

    init(
        snapshotProvider: @escaping @MainActor () -> ScreenTopologySnapshot,
        isSeedPending: @escaping () -> Bool,
        hasStoredPlacementChoice: @escaping () -> Bool,
        applySnapshot: @escaping (ScreenTopologySnapshot) -> Void,
        applySeed: @escaping () -> Void,
        consumeWithoutSeeding: @escaping () -> Void,
        onRetrySeeded: @escaping (ScreenTopologySnapshot) -> Void,
        scheduleAfter: @escaping ScheduleAfter
    ) {
        self.snapshotProvider = snapshotProvider
        self.isSeedPending = isSeedPending
        self.hasStoredPlacementChoice = hasStoredPlacementChoice
        self.applySnapshot = applySnapshot
        self.applySeed = applySeed
        self.consumeWithoutSeeding = consumeWithoutSeeding
        self.onRetrySeeded = onRetrySeeded
        self.scheduleAfter = scheduleAfter
    }

    /// Starts a fresh topology generation. The caller uses the returned snapshot
    /// for its synchronous unit rebuild.
    func prepareForTopologyChange() -> ScreenTopologySnapshot {
        cancelRetries(advanceGeneration: true)
        let snapshot = refreshedSnapshot()
        let outcome = applyDecision(for: snapshot)
        if outcome == .wait, needsUUIDRetry(snapshot) {
            scheduleRetries(for: retryGeneration)
        }
        return snapshot
    }

    func cancel() {
        cancelRetries(advanceGeneration: true)
    }

    private func refreshedSnapshot() -> ScreenTopologySnapshot {
        let snapshot = snapshotProvider()
        applySnapshot(snapshot)
        return snapshot
    }

    @discardableResult
    private func applyDecision(for snapshot: ScreenTopologySnapshot) -> TaskbarPerDisplaySeed.Outcome {
        let outcome = TaskbarPerDisplaySeed.evaluate(
            isSeedPending: isSeedPending(),
            hasStoredPlacementChoice: hasStoredPlacementChoice(),
            identifiedDisplayCount: snapshot.identifiedDisplayUUIDs.count
        )
        switch outcome {
        case .seedPerDisplay:
            applySeed()
        case .consumeWithoutSeeding:
            consumeWithoutSeeding()
        case .wait, .inert:
            break
        }
        return outcome
    }

    private func needsUUIDRetry(_ snapshot: ScreenTopologySnapshot) -> Bool {
        snapshot.physicalDisplayCount >= 2
            && snapshot.identifiedDisplayUUIDs.count < snapshot.physicalDisplayCount
    }

    private func scheduleRetries(for generation: Int) {
        retryWorkItems = Self.retryDelays.map { delay in
            scheduleAfter(delay) { [weak self] in
                MainActor.assumeIsolated {
                    self?.retryFired(generation: generation)
                }
            }
        }
    }

    private func retryFired(generation: Int) {
        guard generation == retryGeneration else { return }
        let snapshot = refreshedSnapshot()
        switch applyDecision(for: snapshot) {
        case .seedPerDisplay:
            cancelRetries(advanceGeneration: false)
            onRetrySeeded(snapshot)
        case .consumeWithoutSeeding, .inert:
            cancelRetries(advanceGeneration: false)
        case .wait:
            // Both retries were scheduled by the original topology event. A retry
            // never schedules another generation.
            break
        }
    }

    private func cancelRetries(advanceGeneration: Bool) {
        if advanceGeneration { retryGeneration &+= 1 }
        retryWorkItems.forEach { $0.cancel() }
        retryWorkItems = []
    }
}
