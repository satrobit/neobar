import CoreGraphics
import Foundation

/// Per-candidate probe gate for `scanNonAdmittedApps()`. Before the rework, every background regular app that would "never be admitted"
/// took a 100ms-timeout AX probe every 5 seconds, endlessly; this gate drops steady-state probing to zero with two free criteria:
/// - **CG presence criterion**: the candidate has no window at all in this tick's full CG table (layer-0, including minimized/hidden/other Spaces)
///   -> nothing admissible (seat creation needs a resolvable cgWindowID), skip.
/// - **Memory criterion**: the last probe concluded "no qualifying window", the process generation is unchanged, and the CG window set is unchanged -> the conclusion still
///   holds, skip. `.unread` (a hung app) is **never remembered**, keeping the original 5s retry.
/// The fallbacks of three forced probes take priority over every skip: CG capture failure (failure is indistinguishable from an empty set, a hard constraint in Docs/26),
/// the 60s slow full scan coming due (sealing any gate loophole), and the workspace launch notification marking it dirty.
/// The four rescan rounds at 0.5/1/2/4s after launch bypass this gate completely (not passing the tick snapshot bypasses it).
enum ScanProbeGateDecision {
    static let defaultFullScanInterval: TimeInterval = 60

    struct Memo: Equatable {
        var identity: ScanAdmissionDecision.ProcessIdentity
        var lastCGIDs: Set<CGWindowID>
        var verdictWasNoEligible: Bool
    }

    struct Input {
        var captureFailed: Bool
        var cgWindowIDs: Set<CGWindowID>
        var memo: Memo?
        var currentIdentity: ScanAdmissionDecision.ProcessIdentity
        var workspaceDirty: Bool
        var slowFullScanDue: Bool
    }

    enum Reason: String, Equatable {
        case captureFailed
        case fullScanDue
        case workspaceDirty
        case noMemo
        case identityChanged
        case cgSetChanged
        case memoNotConclusive
    }

    enum Verdict: Equatable {
        case probe(Reason)
        case skipNoCGWindows
        case skipMemoized
    }

    static func verdict(_ input: Input) -> Verdict {
        if input.captureFailed { return .probe(.captureFailed) }
        if input.slowFullScanDue { return .probe(.fullScanDue) }
        if input.workspaceDirty { return .probe(.workspaceDirty) }
        if input.cgWindowIDs.isEmpty { return .skipNoCGWindows }
        guard let memo = input.memo else { return .probe(.noMemo) }
        guard ScanAdmissionDecision.ProcessIdentity.matches(
            probed: memo.identity,
            current: input.currentIdentity
        ) else { return .probe(.identityChanged) }
        if memo.lastCGIDs != input.cgWindowIDs { return .probe(.cgSetChanged) }
        guard memo.verdictWasNoEligible else { return .probe(.memoNotConclusive) }
        return .skipMemoized
    }
}
