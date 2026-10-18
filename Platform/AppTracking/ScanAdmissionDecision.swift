import Foundation

/// Pure admission-decision layer for the supplementary scan (`AppTracker.scanNonAdmittedApps`).
///
/// The supplementary scan picks up Apps that didn't answer at seed time. It must obey two rules identical to seed's, both of which have bitten us historically:
///
/// 1. **Admission looks at the set after the eligible filter, not the raw AX list**. A non-empty raw list ≠ having a window that can go on the taskbar:
///    transparent panels, extensions, and internal system windows are all in AX. The cost of a wrong admission is permanent: `reconcile()` only clears
///    dead processes, and **an `AppEntry` that is alive but has zero seats is never deleted**, so `rebuildSnapshot` keeps projecting its
///    `app-*` fallback record, leaving an App-level card on the taskbar that can't be erased.
/// 2. **The filtering happens here, and the filtered result is handed to the caller as is**. If this type took only an
///    `eligibleCount: Int`, then "production code mistakenly passes `snaps.count`", which is exactly this bug's failure mode, would still leave the unit tests all green.
///    So `prepare` runs the filter itself and carries the `eligible` array out, and `AppTracker` feeds it directly to
///    `reconcileSeats(preloadedEligible:)`, which also means a second AX read with no timeout is no longer triggered.
///
/// The window type is generic: `AXWindowSnapshot` contains a non-optional `AXUIElement` that unit tests can't construct from nothing; with generics the tests can use
/// a fake window type to cover the filter wiring, and the pure decision layer doesn't have to depend on ApplicationServices.
enum ScanAdmissionDecision {

    /// Process generation identity. A pid gets reused: the AX element obtained by a background probe belongs to the process instance at the moment of the probe,
    /// and at callback time we must confirm that the pid is still the same instance. `startTime` comes from the POSIX
    /// `ProcessLiveness.startTime(pid:)` (a live process always has a value).
    struct ProcessIdentity: Equatable {
        let pid: pid_t
        let startTimeSec: Int64?
        let startTimeUsec: Int32?
        let bundleID: String?

        init(pid: pid_t, startTimeSec: Int64?, startTimeUsec: Int32?, bundleID: String?) {
            self.pid = pid
            self.startTimeSec = startTimeSec
            self.startTimeUsec = startTimeUsec
            self.bundleID = bundleID
        }

        /// All three items equal to count as the same process instance. A start time missing on either side is judged a mismatch (conservative): being unable to read the start time
        /// means the process is already gone and should not be adopted anyway; wait for the next supplementary scan.
        static func matches(probed: Self, current: Self) -> Bool {
            guard probed.pid == current.pid, probed.bundleID == current.bundleID else { return false }
            guard let probedSec = probed.startTimeSec, let currentSec = current.startTimeSec,
                  let probedUsec = probed.startTimeUsec, let currentUsec = current.startTimeUsec
            else { return false }
            return probedSec == currentSec && probedUsec == currentUsec
        }
    }

    /// Filtering result of one probe. `eligible` is the set after admission that is handed to `reconcileSeats`.
    struct Prepared<Window> {
        let eligible: [Window]
        let rawCount: Int
        let readFailed: Bool
    }

    enum Verdict: Equatable {
        case admit
        case skipNotRegular
        case skipTerminated
        case skipAlreadyTracked
        case skipIdentityMismatch
        case skipUnread
        case skipNoEligible
    }

    /// `rawWindows == nil` means this AX read failed (`.unread`), to be distinguished from "read 0 windows": the former
    /// just didn't answer, the latter really has no windows.
    static func prepare<Window>(
        rawWindows: [Window]?,
        isEligible: (Window) -> Bool
    ) -> Prepared<Window> {
        guard let rawWindows else {
            return Prepared(eligible: [], rawCount: 0, readFailed: true)
        }
        return Prepared(
            eligible: rawWindows.filter(isEligible),
            rawCount: rawWindows.count,
            readFailed: false
        )
    }

    /// Decision order: process state → process generation → read result → eligible windows.
    /// The generation comparison is done internally (no `identityMatches: Bool` parameter, since such an argument would be passed wrongly too).
    static func verdict<Window>(
        _ prepared: Prepared<Window>,
        probedIdentity: ProcessIdentity,
        currentIdentity: ProcessIdentity,
        isRegularNonSelf: Bool,
        isTerminated: Bool,
        alreadyTracked: Bool
    ) -> Verdict {
        if !isRegularNonSelf { return .skipNotRegular }
        if isTerminated { return .skipTerminated }
        if alreadyTracked { return .skipAlreadyTracked }
        if !ProcessIdentity.matches(probed: probedIdentity, current: currentIdentity) {
            return .skipIdentityMismatch
        }
        if prepared.readFailed { return .skipUnread }
        if prepared.eligible.isEmpty { return .skipNoEligible }
        return .admit
    }
}
