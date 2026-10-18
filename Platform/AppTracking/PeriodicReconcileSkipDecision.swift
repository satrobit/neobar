import CoreGraphics
import Foundation

/// Per-pid skip-read gate for the periodic reconcile (5s tick). **The AX read of that pid may be skipped only if all conditions hold**; if any one
/// fails a full read is forced. A skipped round follows the existing `.unread` semantics (seats, absence clock, shadow pool, phantom state
/// all stay unadvanced). Conditions and reasons (guardrails; read `Docs/26` before touching any of them):
/// - `captureFailed`: the CG capture failed this round -> "nothing changed" cannot be claimed, so a full read is forced (hard constraint in Docs/26).
/// - `neverRead`: this pid has never had a successful full read.
/// - `refreshDue`: at least `maxSkipInterval` since the last successful full read (monotonic clock) -- a fallback for silent drift with no events and unchanged CG
///   (the only known real case is native tab switching, which happens only in the foreground and is covered by the 2Hz foreground poll).
/// - `observerInactive`: that pid's AXObserver was not set up (AXObserverCreate can fail),
///   and with no event coverage it is never skipped.
/// - `subscriptionIncomplete`: some seat's per-window notifications are not all registered
///   (`WindowSubscriptionLedger.isCovered`), so events do not cover it either; reading keeps the
///   subscription retries moving in a quiet app instead of waiting for `refreshDue`.
/// - `lastReadUnread`: the last read failed and must be retried.
/// - `dirtyEvents`: there have been AX/workspace events for that pid since the last successful full read.
/// - `cgSetChanged`: that pid's set of CG layer-0 window ids changed (a real close / new window / tab switch necessarily changes the CG set).
/// - `absenceClockRunning`: some seat is running its absence clock (minAbsentSince) -- phantom evidence must be sampled at the original
///   5s cadence, and skipping reads would slow self-healing.
/// - `phantomCandidate`: there is a seat with everSeenVisible == false -- it may start an absence episode with no events at all,
///   and forcing the read keeps the phantom self-healing latency exactly the same as before the rework (<= 10s grace + 5s tick).
/// - `lastRoundChanged`: the previous round changed the landed seat signature or the shadow pool -> convergence is not finished, keep reading consecutively.
/// - `seatOnScreenChanged`: a seated window went on- or off-screen since the last full read. A window
///   an app hides without any AX notification changes neither the CG id set nor the dirty flag; this
///   is what lets the absence fallback (`AbsentSeatReleaseDecision`) notice it within one tick.
enum PeriodicReconcileSkipDecision {
    static let defaultMaxSkipInterval: TimeInterval = 30

    struct Input {
        var captureFailed: Bool
        var currentCGIDs: Set<CGWindowID>
        /// The set of CG window ids of that pid at the last successful full read; nil = never read.
        var lastObservedCGIDs: Set<CGWindowID>?
        var dirtySinceLastRead: Bool
        var hasAbsenceClock: Bool
        var hasPhantomCandidate: Bool
        var lastReadWasUnread: Bool
        var lastRoundChanged: Bool
        var observerActive: Bool
        var allSeatsSubscribed: Bool
        var uptimeSinceLastFullRead: TimeInterval
        var maxSkipInterval: TimeInterval = PeriodicReconcileSkipDecision.defaultMaxSkipInterval
        var seatOnScreenChanged: Bool = false
    }

    enum Reason: String, Equatable {
        case captureFailed
        case neverRead
        case refreshDue
        case observerInactive
        case subscriptionIncomplete
        case lastReadUnread
        case dirtyEvents
        case cgSetChanged
        case absenceClockRunning
        case phantomCandidate
        case lastRoundChanged
        case seatOnScreenChanged
    }

    enum Verdict: Equatable {
        case fullRead(Reason)
        case skip
    }

    static func verdict(_ input: Input) -> Verdict {
        if input.captureFailed { return .fullRead(.captureFailed) }
        guard let lastObserved = input.lastObservedCGIDs else { return .fullRead(.neverRead) }
        if input.uptimeSinceLastFullRead >= input.maxSkipInterval { return .fullRead(.refreshDue) }
        if !input.observerActive { return .fullRead(.observerInactive) }
        if !input.allSeatsSubscribed { return .fullRead(.subscriptionIncomplete) }
        if input.lastReadWasUnread { return .fullRead(.lastReadUnread) }
        if input.dirtySinceLastRead { return .fullRead(.dirtyEvents) }
        if input.currentCGIDs != lastObserved { return .fullRead(.cgSetChanged) }
        if input.seatOnScreenChanged { return .fullRead(.seatOnScreenChanged) }
        if input.hasAbsenceClock { return .fullRead(.absenceClockRunning) }
        if input.hasPhantomCandidate { return .fullRead(.phantomCandidate) }
        if input.lastRoundChanged { return .fullRead(.lastRoundChanged) }
        return .skip
    }
}
