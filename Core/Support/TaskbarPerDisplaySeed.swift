import Foundation

enum TaskbarPerDisplaySeed {
    enum Outcome: Equatable {
        case seedPerDisplay
        case consumeWithoutSeeding
        case wait
        case inert
    }

    static func evaluate(
        isSeedPending: Bool,
        hasStoredPlacementChoice: Bool,
        identifiedDisplayCount: Int
    ) -> Outcome {
        guard isSeedPending else { return .inert }
        guard !hasStoredPlacementChoice else { return .consumeWithoutSeeding }
        return identifiedDisplayCount >= 2 ? .seedPerDisplay : .wait
    }
}
