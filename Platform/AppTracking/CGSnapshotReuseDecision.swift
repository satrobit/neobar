import CoreGraphics
import Foundation

/// Reuse gate for the full CG table on the event read path (DOCK_CG_SNAPSHOT_REUSE=0 turns it off).
///
/// Background: the background task of `scheduleEventRead` used to take a full `.optionAll` table **every time** (measured ~1.5ms
/// CPU per call in a 449-entry environment), and the foreground 0.5s poll takes this path on every tick -- during active use, 2Hz x 1.5ms was
/// the largest single item remaining after the idle rework. In the vast majority of ticks the full table is bit-for-bit identical to the previous one.
///
/// How the gate works: first take a cheap on-screen probe (~0.2ms, same scope as `captureOnScreenWindowIDs`). If all static conditions pass
/// and the probe set matches the probe set from the cached round -> reuse the cached full table; if any fails -> take a fresh full table and refresh the cache.
/// Switching tabs / closing a window / minimizing / changing Space / changing screen all change the on-screen set, and the probe catches it on the spot -> fresh capture, bit-for-bit identical
/// to the gate being off. The only thing deferred is "a purely off-screen change with no AX/workspace event at all" (events are backstopped by the global generation),
/// bounded by `defaultMaxCacheAge`; the batch path of the 5s reconcile always captures fresh and does not go through this gate.
///
/// Hard ordering rule: **probe first, full capture after**. Reversed, the probe would be later than the full capture, and a change between the two would put "old full table +
/// new probe" into the cache -- the next tick's probe would match and reuse a full table missing the change. With the probe first, a change within the same window merely causes one extra
/// capture on the next tick, the conservative direction.
enum CGSnapshotReuseDecision {
    /// Upper bound on cache validity (seconds, monotonic clock). The age is computed when the main thread assembles the ticket, and a background AX read (up to ~0.5s) makes the real
    /// age slightly larger than the judged value -- the bound already includes that margin, so do not lower it to the same order as the read time.
    static let defaultMaxCacheAge: TimeInterval = 2.0

    enum FreshReason: Equatable {
        case disabled          // Kill switch: not even the probe is taken, bit-for-bit identical to before the gate
        case noCache
        case cachedCaptureFailed
        case cacheExpired
        case eventSinceCache   // An AX/workspace event happened after the cached round (the global generation changed)
        case absenceClockRunning
        case phantomCandidate
        case observerInactive  // That pid's AXObserver is absent -> events can never arrive, and the generation criterion is invalid
        case probeChanged
    }

    /// Verdict on the static conditions (the part knowable when the main thread assembles the ticket). The probe comparison is done in the background task (`probeVerdict`).
    enum PreVerdict: Equatable {
        case captureWithoutProbe          // Kill-switch path
        case captureAndPrime(FreshReason) // Capture the full table fresh, and reconnect the cache chain using the probe from the same round
        case probeThenCompare
    }

    struct Input: Equatable {
        let reuseEnabled: Bool
        let hasCache: Bool
        let cachedCaptureFailed: Bool
        let cacheAge: TimeInterval
        let generationMatches: Bool
        let hasAbsenceClock: Bool
        let hasPhantomCandidate: Bool
        let observerActive: Bool
    }

    static func preVerdict(_ input: Input) -> PreVerdict {
        guard input.reuseEnabled else { return .captureWithoutProbe }
        guard input.hasCache else { return .captureAndPrime(.noCache) }
        if input.cachedCaptureFailed { return .captureAndPrime(.cachedCaptureFailed) }
        if input.cacheAge >= defaultMaxCacheAge || input.cacheAge < 0 {
            return .captureAndPrime(.cacheExpired)
        }
        if !input.generationMatches { return .captureAndPrime(.eventSinceCache) }
        if input.hasAbsenceClock { return .captureAndPrime(.absenceClockRunning) }
        if input.hasPhantomCandidate { return .captureAndPrime(.phantomCandidate) }
        if !input.observerActive { return .captureAndPrime(.observerInactive) }
        return .probeThenCompare
    }

    enum ProbeVerdict: Equatable {
        case reuse
        case captureAndPrime(FreshReason)
    }

    /// The probe set is compared only with **the probe set from the cached round**. The probe scope (onScreenOnly + excludeDesktopElements,
    /// layer-0) differs from the scope of the on-screen flag in the full table, so never compare it against `snapshot.onScreenWindowIDs`.
    static func probeVerdict(probe: Set<CGWindowID>, cachedProbe: Set<CGWindowID>) -> ProbeVerdict {
        probe == cachedProbe ? .reuse : .captureAndPrime(.probeChanged)
    }

    /// A cached table may only err toward retention. Its below-normal-layer set is a veto, and the
    /// layer-0 probe cannot see a window leaving that set, so a read that lists such an id must
    /// capture fresh instead of reusing the cache.
    static func cachedLayerVetoApplies(
        axWindowIDs: Set<CGWindowID>,
        cachedBelowNormalLayerIDs: Set<CGWindowID>
    ) -> Bool {
        !axWindowIDs.isDisjoint(with: cachedBelowNormalLayerIDs)
    }
}
