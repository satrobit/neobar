import Foundation

/// Settle decision for same-window "minimize -> activate" rapid clicks (v2, 2026-08-25).
///
/// v1 (time gate: 0.65s settle floor + 1.0s cap) was vetoed by the owner's measurement: (1) the floor ruins the feel of "reversing mid-genie
/// to interrupt"; (2) one Finder restore measured 887ms, and after the 1.0s anchor expires clicks run unprotected and the sibling still gets brought out.
///
/// v2 semantics: **release on confirmation; safety does not depend on waiting**. The snapshot confirming `.minimized` = the minimize write has
/// landed in the target app (there is write-order proof against the concurrently executing minimize) -> release immediately; the execution layer, holding the `dispatchPrior`
/// prior, is forced into the restore branch (07-05 v3 order, measured safe 5/5; writing unminimize to a non-minimized window is a harmless no-op),
/// skips earlyFocus, and seals the app-level fallback: all three promotion paths of "switching frontmost while the window is off-screen" are blocked,
/// and unminimize landing mid-genie reverses the animation (the source of the feel).
enum MinimizeSettleGate {
    enum Verdict: Equatable {
        case dispatchNow
        case hold(until: Date)
    }

    /// Hold limit when unconfirmed: if minimize truly fails, the second click is dead for at most this long, then released on time (the execution layer still carries the prior).
    static let maxHold: TimeInterval = 1.0
    /// Prior window (the anchor's second lifetime): any activate within this long after the minimize dispatch carries the prior "force knownMinimized
    /// + skip earlyFocus + seal the app fallback". Take 2.0s ~ the measured worst-case animation (Finder 887ms) x2 +
    /// snapshot round-trip margin; the prior costs nothing (safe in both worlds), so it can be much wider than the hold limit. A tunable constant,
    /// calibrated by the owner's Finder-storm acceptance.
    static let priorWindow: TimeInterval = 2.0

    static func verdict(
        requestKind: PlatformActionRequest.ActionKind,
        minimizeDispatchedAt: Date?,
        snapshotConfirmsMinimized: Bool,
        now: Date,
        maxHold: TimeInterval = Self.maxHold
    ) -> Verdict {
        guard requestKind == .activateWindow, let anchor = minimizeDispatchedAt else {
            return .dispatchNow
        }
        let elapsed = now.timeIntervalSince(anchor)
        // Clock anomaly (anchor in the future): release conservatively, falling back to the old rapid-click behavior.
        if elapsed < 0 { return .dispatchNow }
        if elapsed >= maxHold { return .dispatchNow }
        // v2 core: release on confirmation. The snapshot flipping is the write-landed proof; the dangerous branches during the animation are sealed by the prior, no longer blocked by time.
        if snapshotConfirmsMinimized { return .dispatchNow }
        return .hold(until: anchor.addingTimeInterval(maxHold))
    }

    /// The prior "force knownMinimized + skip earlyFocus + seal the app fallback": holds when the anchor is within the prior window.
    /// A clock anomaly (negative elapsed) gives no prior, and everything falls back to the old behavior.
    static func dispatchPrior(
        minimizeDispatchedAt: Date?,
        now: Date,
        priorWindow: TimeInterval = Self.priorWindow
    ) -> Bool {
        guard let anchor = minimizeDispatchedAt else { return false }
        let elapsed = now.timeIntervalSince(anchor)
        return elapsed >= 0 && elapsed < priorWindow
    }
}
