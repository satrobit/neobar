import Foundation

/// Per-tick read plan for badge polling (pure decision). Hard product constraint: **while visible, the cadence stays at 0.5s** —
/// this type only decides "what to read and how to read it" on this tick, and never lengthens the interval:
/// - `pause`: no readable messaging app (visible ∩ running is empty) or the taskbar is logically hidden → zero AX traffic this tick.
///   When the resume condition appears, the caller **reads once immediately** (zero-perceived-latency gating; see the board card "pause badge polling when there are no messaging apps").
/// - `fullWalk`: the Dock item element cache must be rebuilt (no cache / a re-walk was requested / the 10s self-heal expired; the self-heal covers
///   pathological cases with no error signal such as a pinned Dock icon or a reorder, with a worst-case staleness bound of 10s).
/// - `targeted`: read directly via cached elements (1–3 AX round trips, instead of 25–45 for the whole Dock tree).
enum BadgeReadPlan {
    static let defaultFullWalkInterval: TimeInterval = 10

    struct Input {
        /// Apps whose badge must be read this tick: messaging area visible **∩** running (a kept app that is not running has no Dock tile).
        var messagingBundleIDs: [String]
        var taskbarVisible: Bool
        var hasCache: Bool
        var cacheAgeSeconds: TimeInterval
        var rewalkRequested: Bool
        var fullWalkInterval: TimeInterval = BadgeReadPlan.defaultFullWalkInterval
    }

    enum WalkReason: String, Equatable {
        case noCache
        case rewalkRequested
        case selfHealDue
    }

    enum Verdict: Equatable {
        case pause
        case fullWalk(WalkReason)
        case targeted([String])
    }

    static func verdict(_ input: Input) -> Verdict {
        if input.messagingBundleIDs.isEmpty || !input.taskbarVisible { return .pause }
        if !input.hasCache { return .fullWalk(.noCache) }
        if input.rewalkRequested { return .fullWalk(.rewalkRequested) }
        if input.cacheAgeSeconds >= input.fullWalkInterval { return .fullWalk(.selfHealDue) }
        return .targeted(input.messagingBundleIDs)
    }
}
