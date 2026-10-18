import CoreGraphics
import Foundation

struct AXWindowMatchPolicy {
    struct Candidate: Equatable {
        let title: String?
        let bounds: CGRect?
    }

    static func matchScore(
        targetTitle: String?,
        targetBounds: CGRect?,
        candidateTitle: String?,
        candidateBounds: CGRect?
    ) -> Int? {
        var score = 0

        if let targetTitle {
            guard let candidateTitle else {
                return nil
            }

            let targetNormalized = normalizedTitle(targetTitle)
            let candidateNormalized = normalizedTitle(candidateTitle)

            if targetNormalized == candidateNormalized {
                score += 0
            } else if candidateNormalized.contains(targetNormalized) || targetNormalized.contains(candidateNormalized) {
                score += 25
            } else {
                return nil
            }
        }

        if let targetBounds {
            guard let candidateBounds else { return nil }
            guard WindowFrameMatchPolicy.areClose(targetBounds, candidateBounds) else {
                return nil
            }
            return score + WindowFrameMatchPolicy.score(targetBounds, candidateBounds)
        }

        return score
    }

    static func uniqueBestMatchIndex(
        targetTitle: String?,
        targetBounds: CGRect?,
        candidates: [Candidate]
    ) -> Int? {
        let scored = candidates.enumerated().compactMap { index, candidate -> (Int, Int)? in
            matchScore(
                targetTitle: targetTitle,
                targetBounds: targetBounds,
                candidateTitle: candidate.title,
                candidateBounds: candidate.bounds
            ).map { (index, $0) }
        }
        guard let bestScore = scored.map(\.1).min() else { return nil }
        let bestMatches = scored.filter { $0.1 == bestScore }
        return bestMatches.count == 1 ? bestMatches[0].0 : nil
    }

    private static func normalizedTitle(_ title: String) -> String {
        title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}
