import CoreGraphics
import Foundation

/// Pure decision layer for Pass B "minimize fold": for an unclaimed, eligible window that AX reports as minimized, is it a background tab of an already-seated
/// physical window (-> fold, no new seat) or a genuinely independent window (-> create a new seat)?
///
/// Background: when a multi-tab window is minimized, Ghostty exposes all of its tabs as AX windows at once, all reporting
/// min=true. Background tabs are order-out windows and receive no moved/resized notifications -- after the window has been moved/resized,
/// their AX position and size stay at stale values and pure geometric matching fails (one tab splits into a separate card).
///
/// Four decision levels, strongest to weakest:
/// 1. **Membership**: the candidate cgID was once some placed seat's activeCgID (a tab becomes the active tab when created => every
///    background tab has been through its seat's history). Completely independent of geometry and the min flag -- immune to both
///    "AX geometry stale after move/resize" and "min lag race" fold failures. Note the history is **session state** (cleared when the dock restarts).
/// 2. **Shadow tab pool**: the candidate cgID was, at the previous reconcile, "in the full CG list but not in AXWindows" -- this is
///    the signature of an order-out background tab. (Not unique: a window on another Space also leaves AXWindows
///    while staying in CG — seated ids are kept out of the pool for that reason.) The pool is rebuilt from live signals every round, **naturally immune to dock restarts**, and is the restart-safe layer after the membership history is cleared.
///    Effective only when a seated seat already exists: with zero seats nothing is folded (the representative tab of a truly minimized window group must be able to create a seat).
/// 3. **Exact frame match**: the background tab has a pixel-identical frame to its window (holds when the window hasn't moved).
/// 4. **Size fallback**: same width/height +-3 + off-screen + the corresponding seat already marked minimized (holds when the window moved but wasn't resized).
/// All four levels fail -> create a new seat (for a min=true candidate this is a potential split point; the caller writes a diagnostic log).
enum TabFoldDecision {

    /// Fold-view summary of the seats placed in this reconcile round. `activeCgID` serves only as a write-back index (membership learning), not an identity.
    struct PlacedSeat {
        let activeCgID: CGWindowID
        let bounds: CGRect?
        let isMinimized: Bool
        let formerCgIDs: Set<CGWindowID>
    }

    enum Reason: String {
        case membership   // Was once this seat's active tab
        case shadowPool   // In CG but not in AX at the previous round (order-out background tab signature)
        case exactFrame   // Frame matches pixel for pixel
        case sameSize     // Same size + off-screen fallback
    }

    enum Verdict: Equatable {
        /// Fold into an existing seat, no new one. `ownerActiveCgID` non-nil = ownership is uniquely determined, and the caller may record the candidate
        /// cgID in that seat's history (membership learning: next time the fold no longer depends on geometry); nil = ownership is ambiguous, fold only, no learning.
        case fold(ownerActiveCgID: CGWindowID?, reason: Reason)
        case newSeat
    }

    static func verdict(
        candidateCgID: CGWindowID,
        candidateBounds: CGRect?,
        candidateIsMinimized: Bool,
        candidateIsOnScreen: Bool,
        candidateIsKnownShadow: Bool,
        placedSeats: [PlacedSeat],
        frameKey: (CGRect?) -> String?
    ) -> Verdict {
        // An unclaimed non-min window is a legitimate new window (including the "two independent windows overlapping" and "tab dragged out and made visible" scenarios),
        // and a seat is created as usual -- the shadow pool never applies to min=false candidates.
        guard candidateIsMinimized else { return .newSeat }

        // 1. Membership
        let owners = placedSeats.filter { $0.formerCgIDs.contains(candidateCgID) }
        if owners.count == 1 { return .fold(ownerActiveCgID: owners[0].activeCgID, reason: .membership) }
        if owners.count > 1 { return .fold(ownerActiveCgID: nil, reason: .membership) }

        // 2. Shadow tab pool: a unique seat -> ownership + learning; multiple seats -> fold only, no learning (better to learn too little than to record wrongly).
        // With zero seats don't fold -- otherwise a truly minimized window group couldn't even create a single card.
        if candidateIsKnownShadow, !placedSeats.isEmpty {
            if placedSeats.count == 1 { return .fold(ownerActiveCgID: placedSeats[0].activeCgID, reason: .shadowPool) }
            return .fold(ownerActiveCgID: nil, reason: .shadowPool)
        }

        // 3. Exact frame match
        if let key = frameKey(candidateBounds) {
            let matches = placedSeats.filter { frameKey($0.bounds) == key }
            if matches.count == 1 { return .fold(ownerActiveCgID: matches[0].activeCgID, reason: .exactFrame) }
            if matches.count > 1 { return .fold(ownerActiveCgID: nil, reason: .exactFrame) }
        }

        // 4. Size fallback: off-screen (non-active tab) + same width/height as some placed minimized seat
        if !candidateIsOnScreen, let sb = candidateBounds {
            let matches = placedSeats.filter { seat in
                guard seat.isMinimized, let pb = seat.bounds else { return false }
                return abs(pb.size.width - sb.size.width) < 3 &&
                       abs(pb.size.height - sb.size.height) < 3
            }
            if matches.count == 1 { return .fold(ownerActiveCgID: matches[0].activeCgID, reason: .sameSize) }
            if matches.count > 1 { return .fold(ownerActiveCgID: nil, reason: .sameSize) }
        }

        return .newSeat
    }
}

/// Pure decision layer for Pass A "merge into tab": for a seated seat that is **not minimized and whose app is not hidden**, its activeCgID this round
/// left AX yet is still in CG with no destroy tombstone -- was it merged into another window ("Merge All Windows" / dragging a tab
/// into another window's tab bar), or is it just an AX misread?
///
/// A native tab = N real NSWindows; after merging, the original window becomes an order-out background tab: leaves AX, stays in CG, `onscreen=false`,
/// and its CG bounds get rewritten by the system to the owning window's frame. This path used to keep the seat unconditionally ("AX absence can't prove the window closed"), so
/// one window got two cards; then with two old seats at the same frame, the take-over rule for tab switching refuses to take it, splitting one more card per switch (measured 2026-09-12).
///
/// Release conditions (all must hold): the candidate is **not on screen** in CG (when a truly visible window is misread, CG says onscreen=true and it isn't released);
/// the candidate's **CG bounds** (not the stale AX frame in the seat) are pixel-identical to the frame of at least one sibling seat that is **AX-present and min=false**.
/// When ownership is unique, return the owner, and the caller records the candidate in its history (so the next minimize burst folds instantly by membership).
enum TabMergeDecision {

    /// Summary of sibling seats that are AX-present this round (activeCgID still in eligible); `bounds` takes the frame from this round's AX snapshot.
    struct AXPresentSeat {
        let activeCgID: CGWindowID
        let bounds: CGRect?
        let isMinimized: Bool
    }

    enum Verdict: Equatable {
        /// Merged into a tab -> release the seat. `ownerActiveCgID` non-nil = unique ownership, and the caller does membership learning.
        case release(ownerActiveCgID: CGWindowID?)
        case retain
    }

    static func verdict(
        candidateIsOnScreen: Bool,
        candidateCGBounds: CGRect?,
        candidateSeatBounds: CGRect?,
        axPresentSeats: [AXPresentSeat],
        frameKey: (CGRect?) -> String?
    ) -> Verdict {
        guard !candidateIsOnScreen else { return .retain }
        guard let key = frameKey(candidateCGBounds ?? candidateSeatBounds) else { return .retain }
        let owners = axPresentSeats.filter { !$0.isMinimized && frameKey($0.bounds) == key }
        if owners.count == 1 { return .release(ownerActiveCgID: owners[0].activeCgID) }
        if owners.count > 1 { return .release(ownerActiveCgID: nil) }
        return .retain
    }
}

/// Pure decision layer for ghost-seat self-healing.
///
/// A ghost seat = an extra seat split off from a min=true burst candidate when the fold decision missed (typical: the window was already minimized
/// when the dock launched, so the seed has no history and no shadow pool is available). It is marked min=true and is held forever by the "minimizing doesn't release the seat" keep rule
/// -- after the window is restored its cgID merely leaves AX while staying in CG, so the card stays split.
///
/// Five self-healing gates (release only if all are met; better not to heal than to delete wrongly):
/// - `everSeenVisible == false`: the seat's activeCgID has never appeared in AX with min=false during this session.
///   A real window has almost certainly been visible; this gate protects Safari-style real windows that leave AX entirely as soon as they are minimized.
/// - AX absent consecutively >= threshold: not just a round or two of misreads.
/// - cgID still in CG: if it's not, it's a real close, handled by the existing delete path, and self-healing never gets a turn.
/// - This round's AX read the app's windows: when the app is hung / AX read fails, do nothing.
/// - At least one seat of the same pid is currently in AX: an orphan seat never self-heals (to avoid deleting an app's only card).
enum PhantomSeatDecision {
    enum HoldReason: String, Codable, Hashable {
        case everSeenVisible
        case absenceGraceNotElapsed
        case cgMissing
        case noEligibleWindows
        case noAXPresentSibling
    }

    struct Evaluation: Equatable {
        let shouldRelease: Bool
        let holdReasons: Set<HoldReason>
    }

    static func evaluate(
        everSeenVisible: Bool,
        axAbsentFor: TimeInterval,
        threshold: TimeInterval,
        cgStillPresent: Bool,
        axReadSawWindows: Bool,
        axPresentSiblingCount: Int
    ) -> Evaluation {
        var reasons: Set<HoldReason> = []
        if everSeenVisible { reasons.insert(.everSeenVisible) }
        if axAbsentFor < threshold { reasons.insert(.absenceGraceNotElapsed) }
        if !cgStillPresent { reasons.insert(.cgMissing) }
        if !axReadSawWindows { reasons.insert(.noEligibleWindows) }
        if axPresentSiblingCount < 1 { reasons.insert(.noAXPresentSibling) }
        return Evaluation(shouldRelease: reasons.isEmpty, holdReasons: reasons)
    }

    static func shouldRelease(
        everSeenVisible: Bool,
        axAbsentFor: TimeInterval,
        threshold: TimeInterval,
        cgStillPresent: Bool,
        axReadSawWindows: Bool,
        axPresentSiblingCount: Int
    ) -> Bool {
        evaluate(
            everSeenVisible: everSeenVisible,
            axAbsentFor: axAbsentFor,
            threshold: threshold,
            cgStillPresent: cgStillPresent,
            axReadSawWindows: axReadSawWindows,
            axPresentSiblingCount: axPresentSiblingCount
        ).shouldRelease
    }
}
