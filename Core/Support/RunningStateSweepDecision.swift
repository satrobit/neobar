import Foundation

/// Pure reconciliation between the launch-notification projection and a fresh workspace sample.
/// Missing workspace observations are deliberately unknown; POSIX generation is the only death signal.
enum RunningStateSweepDecision {
    struct Generation: Hashable {
        let pid: pid_t
        let startTimeSeconds: Int64
        let startTimeMicroseconds: Int64
    }

    struct Tracked: Equatable {
        let generation: Generation
        let bundleID: String
        let isHidden: Bool
    }

    enum ActivationPolicy: Equatable {
        case regular
        case nonRegular
    }

    struct Observation: Equatable {
        let generation: Generation
        let bundleID: String
        let isHidden: Bool
        let activationPolicy: ActivationPolicy
    }

    enum RemovalReason: Equatable {
        case processGone
        case generationChanged
    }

    struct Removal: Equatable {
        let pid: pid_t
        let generation: Generation
        let reason: RemovalReason
    }

    struct Plan: Equatable {
        let removals: [Removal]
        let regularUpserts: [Observation]
        let nonRegularConfirmations: [Observation]
    }

    static func plan(
        trackedByPID: [pid_t: Tracked],
        observationsByPID: [pid_t: Observation],
        currentGenerationsByPID: [pid_t: Generation?]
    ) -> Plan {
        var removals: [Removal] = []
        var regularUpserts: [Observation] = []
        var nonRegularConfirmations: [Observation] = []

        for pid in trackedByPID.keys.sorted() {
            guard let tracked = trackedByPID[pid] else { continue }
            guard let sampled = currentGenerationsByPID[pid] ?? nil else {
                removals.append(Removal(pid: pid, generation: tracked.generation, reason: .processGone))
                continue
            }
            guard sampled == tracked.generation else {
                removals.append(Removal(pid: pid, generation: tracked.generation, reason: .generationChanged))
                continue
            }
        }

        for pid in observationsByPID.keys.sorted() {
            guard let observation = observationsByPID[pid],
                  (currentGenerationsByPID[pid] ?? nil) == observation.generation else { continue }
            switch observation.activationPolicy {
            case .regular:
                regularUpserts.append(observation)
            case .nonRegular:
                if let tracked = trackedByPID[pid],
                   tracked.generation == observation.generation,
                   tracked.bundleID == observation.bundleID {
                    nonRegularConfirmations.append(observation)
                }
            }
        }

        return Plan(
            removals: removals,
            regularUpserts: regularUpserts,
            nonRegularConfirmations: nonRegularConfirmations
        )
    }
}
