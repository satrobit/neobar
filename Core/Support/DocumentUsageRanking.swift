import Foundation

/// Usage count of one file. `count` accumulates only from when the feature went live (macOS doesn't record historical open counts).
struct DocumentUsageRecord: Equatable, Codable {
    var count: Int
    var lastOpened: Date
}

/// The count ledger of one app. `lastTop` = the top of the system recents list at the last sample (used to judge "was something newly opened"),
/// `touchedAt` = the last time this ledger changed (used for bundle-level eviction).
struct BundleDocumentUsage: Equatable, Codable {
    var files: [String: DocumentUsageRecord] = [:]
    var lastTop: String?
    var touchedAt: Date = .distantPast
}

/// Pure logic for "most used files": sorting, counting, eviction. Side effects (disk, subscriptions, menu) are in `DocumentUsageStore`.
enum DocumentUsageRanking {
    static let fileCap = 200
    static let bundleCap = 40

    /// Ranking: count descending -> lastOpened descending -> system recents order. Files that appear only in the recents list and were never counted rank
    /// as 0 counts after all counted ones, so in the first days after the upgrade the menu matches the old "Recents" and gets more accurate with use.
    /// Candidates = system recents list ∪ counted files (deduplicated by path).
    static func ranked(
        counts: [String: DocumentUsageRecord],
        recentPaths: [String],
        limit: Int = 10
    ) -> [String] {
        var recentOrder: [String: Int] = [:]
        for (index, path) in recentPaths.enumerated() where recentOrder[path] == nil {
            recentOrder[path] = index
        }
        var candidates = Set(recentPaths)
        candidates.formUnion(counts.keys)
        let sorted = candidates.sorted { a, b in
            let na = counts[a]?.count ?? 0
            let nb = counts[b]?.count ?? 0
            if na != nb { return na > nb }
            let da = counts[a]?.lastOpened ?? .distantPast
            let db = counts[b]?.lastOpened ?? .distantPast
            if da != db { return da > db }
            let oa = recentOrder[a] ?? Int.max
            let ob = recentOrder[b] ?? Int.max
            if oa != ob { return oa < ob }
            return a < b
        }
        return Array(sorted.prefix(limit))
    }

    /// +1 for a file. When `cap` is exceeded, evict the one with "lowest count, and among those the longest unopened" (never evicting the one just incremented).
    static func bumped(
        _ files: [String: DocumentUsageRecord],
        path: String,
        at date: Date,
        cap: Int = fileCap
    ) -> [String: DocumentUsageRecord] {
        var files = files
        var record = files[path] ?? DocumentUsageRecord(count: 0, lastOpened: date)
        record.count += 1
        record.lastOpened = date
        files[path] = record
        while files.count > cap {
            let victim = files.min { a, b in
                if a.value.count != b.value.count { return a.value.count < b.value.count }
                if a.value.lastOpened != b.value.lastOpened { return a.value.lastOpened < b.value.lastOpened }
                return a.key < b.key
            }?.key
            guard let victim, victim != path else { break }
            files.removeValue(forKey: victim)
        }
        return files
    }

    /// Only a change of the top counts as one open. The first sample (previous == nil) only establishes the baseline without counting, since that may be
    /// a stale top rather than an open that just happened; a cleared list (new == nil) doesn't count either.
    static func shouldCountTopChange(previousTop: String?, newTop: String?) -> Bool {
        guard let previousTop, let newTop else { return false }
        return previousTop != newTop
    }

    /// Bundle-level eviction: keep only the `maxBundles` most recently touched ledgers.
    static func prunedBundles(
        _ store: [String: BundleDocumentUsage],
        maxBundles: Int = bundleCap
    ) -> [String: BundleDocumentUsage] {
        guard store.count > maxBundles else { return store }
        let kept = store.sorted { $0.value.touchedAt > $1.value.touchedAt }.prefix(maxBundles)
        return Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
    }
}
