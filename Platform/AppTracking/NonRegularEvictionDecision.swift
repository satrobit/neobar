import Foundation

/// Pure gate for dropping a tracked process that left `.regular` with no seats left.
///
/// The system Dock lists a process only while its activation policy is `.regular`. Menu-bar apps
/// such as Ice flip to `.regular` while their settings window is open and back to `.accessory`
/// when it closes; admission happened while the window was open, and after the close the
/// zero-seat `AppEntry` kept projecting its `app-*` fallback chip for the rest of the process's
/// life — a card the Dock never shows. Liveness is not judged here (`reconcile()` owns it via
/// `ProcessLiveness`); this only decides whether a live, zero-seat entry still deserves its slot.
enum NonRegularEvictionDecision {
    enum Verdict: Equatable {
        case evict
        case keepUntracked
        case keepFinder
        case keepHasSeats
        case keepIdentityChanged
        /// LaunchServices could not resolve the pid. `NSRunningApplication(processIdentifier:)`
        /// transiently returns nil for live processes, so "unknown" is never evidence of anything.
        case keepPolicyUnknown
        case keepRegular
    }

    /// Gate order: tracked → not Finder → no seats → same process generation → policy known and
    /// not `.regular`. A process with seats keeps them even after leaving `.regular` — the window
    /// is still real and user-operable; only the seatless fallback chip is the Dock mismatch.
    static func verdict(
        isTracked: Bool,
        isFinder: Bool,
        hasSeats: Bool,
        identityMatches: Bool,
        isRegular: Bool?
    ) -> Verdict {
        if !isTracked { return .keepUntracked }
        if isFinder { return .keepFinder }
        if hasSeats { return .keepHasSeats }
        if !identityMatches { return .keepIdentityChanged }
        guard let isRegular else { return .keepPolicyUnknown }
        return isRegular ? .keepRegular : .evict
    }
}
