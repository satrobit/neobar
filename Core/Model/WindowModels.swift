import Foundation
import CoreGraphics

struct WindowRecord: Hashable, Sendable {
    let id: WindowID
    let appID: AppID
    let pid: Int32
    let bundleIdentifier: String?
    var title: String
    var bounds: CGRect?
    var status: WindowStatus
    var cgWindowID: CGWindowID?
    var isOnDesktop: Bool
    /// Stable group identity (root fix for tab groups). All native tab seats of the same physical window share the same token; once assigned it
    /// **does not change with the CGWindowID of the currently active tab**; an ordinary single window is a token that forms a group of its own. The strip merges by it,
    /// and uses it as the card's stable id (switching tabs / background tabs coming and going don't change the identity → the card neither jumps nor splits).
    /// Default empty string = degrades to each `id` being independent (compatible with unassigned paths).
    var groupID: String
    /// Which screen the window is on (display UUID, a coarse ownership key; multi-screen ④ filters window cards by it). nil = the inventory can't read a position
    /// (fallback cards, frames not yet read): landing on the main screen is decided by the projection layer, and we don't guess here. While minimized / hidden it is frozen at the last visible screen.
    var displayUUID: String?

    init(
        id: WindowID,
        appID: AppID,
        pid: Int32,
        bundleIdentifier: String?,
        title: String,
        bounds: CGRect?,
        status: WindowStatus,
        cgWindowID: CGWindowID? = nil,
        isOnDesktop: Bool = false,
        groupID: String = "",
        displayUUID: String? = nil
    ) {
        self.id = id
        self.appID = appID
        self.pid = pid
        self.bundleIdentifier = bundleIdentifier
        self.title = title
        self.bounds = bounds
        self.status = status
        self.cgWindowID = cgWindowID
        self.isOnDesktop = isOnDesktop
        self.groupID = groupID.isEmpty ? id.rawValue : groupID
        self.displayUUID = displayUUID
    }
}

enum WindowStatus: String, Hashable, Codable, Sendable {
    case active
    case inactive
    case minimized
    case hidden
    case closedPending
    case disappeared
}

/// Optimistic-state overlay (interaction polish 2026-06-13): at the instant a click issues a show/hide-type action (activate / minimize /
/// hide), first assume locally that the window has already become the target state; the UI and the next toggle planning both read it first,
/// without waiting for the snapshot round trip. This is the root of "interruptible / rapid-click handoff". It is cleared (silent rollback) once the real snapshot
/// fulfills the prediction or it times out. close / quit don't write optimistic state (the window is going away, and a failure rollback would flash).
///
/// Only the status is predicted, not the foreground axis (2026-07-05): the foreground axis has an immediate and accurate system reading (isActive of a newly created
/// NSRunningApplication instance, which flips right after a SkyLight switch), and predicting it would only go wrong:
/// a leftover isAppFrontmost=true lasting a full 4s once made "click a card while another app is in front" get planned as minimize.
struct OptimisticWindowState: Hashable, Sendable {
    let status: WindowStatus
    let createdAt: Date
    /// This .active prediction describes "focus is arriving at this window through a system transition": a restore animation (clicking a minimized window to
    /// restore it), or a collapse handoff (the successor the system promotes after the focused window is collapsed). During the transition the snapshot may briefly
    /// confirm a sibling .active (ghost), and takeover clearing gives this kind of prediction a 1.5s grace
    /// (see `supersededByActiveSibling`). Omitted means false (an ordinary activation from a user click on a visible window).
    let focusHandoffGrace: Bool
    /// This prediction was inferred by the system (the successor prediction of a collapse handoff) rather than from a user click. The evidence strength of a system prediction
    /// is lower than a user action: when the snapshot disproves it (the window is actually minimized/hidden) it is cleared immediately; see
    /// `systemPredictionFalsified`. Omitted means false (user-action origin, correct semantics).
    let systemPredicted: Bool

    init(status: WindowStatus, createdAt: Date, focusHandoffGrace: Bool = false, systemPredicted: Bool = false) {
        self.status = status
        self.createdAt = createdAt
        self.focusHandoffGrace = focusHandoffGrace
        self.systemPredicted = systemPredicted
    }
}

extension OptimisticWindowState {
    /// Sibling takeover clears immediately (2026-08-22): a predicted .active has not been fulfilled while another window of the same app is already confirmed by the snapshot as
    /// .active; focus has been taken by the sibling, and keeping this prediction for a full 4 seconds would only get the next click planned as minimize.
    /// macOS 26 once silently disabled SkyLight make-key, and wrongly minimizing was triggered exactly by this kind of leftover; keeping this layer of defense means that
    /// when the focus channel silently fails again in the future, the symptom degrades to "a redundant activate" instead of "a wrong minimize".
    /// Only .active predictions are cleared: the fulfillment semantics of minimize / hidden (including disappeared) are unrelated to sibling state.
    /// Transition grace (2026-08-26, the original "restore grace" extended to collapse handoff): an .active prediction originating from a focus transition
    /// is not cleared by sibling takeover within this window. Finder measurement: during the transition the app is already foreground and focus still sits on a visible
    /// sibling, the snapshot briefly confirms the sibling .active, the prediction gets displaced after 10–530ms, and afterwards collapse
    /// clicks within ~1s were all downgraded into empty activates (owner: "clicked but didn't collapse"). The 1.5s cap covers Finder's 887ms animation.
    static let handoffSupersessionGrace: TimeInterval = 1.5

    /// System-prediction falsification (measured in the 2026-08-26 Release storm): a handoff prediction may land on a window that has actually been collapsed
    /// (snapshot lag + the window is still in the CG on-screen list during the collapse animation); this wrong .active survives with its grace and would get
    /// the later wake click planned as a collapse, repeatedly ineffective until the 4s timeout. If the snapshot says this window is minimized/hidden, that
    /// contradicts "about to become focus" → clear immediately, and the click returns to activate (= restore, exactly the user's intent).
    /// **Only system predictions are cleared**: the user's own "restore → collapse again" alternating state (optimistic .active + snapshot .minimized)
    /// is a normal in-flight state and must never be cleared.
    static func systemPredictionFalsified(state: OptimisticWindowState, actual: WindowStatus) -> Bool {
        guard state.systemPredicted, state.status == .active else { return false }
        return actual == .minimized || actual == .hidden
    }

    /// Full decision for takeover clearing (used by reconcile).
    ///
    /// Sibling "confirmed .active" has an **in-flight discount**: when the sibling itself holds an in-flight optimistic .minimized /
    /// .hidden (the user just collapsed/hid it), the .active in its snapshot is a ghost contradicted by the user's action and does not count as a
    /// focus successor; otherwise, while collapsing window 1 is in flight, its active ghost would immediately displace the prediction just written for successor window 2.
    ///
    /// The grace exemption requires all of these at once: the prediction carries `focusHandoffGrace`, grace has not expired, and no same-pid sibling
    /// itself holds an optimistic .active (having one = the user really clicked the sibling card, focus really was taken, and the prediction is cleared as usual,
    /// preserving the bottom line "better a redundant activate than a wrong minimize").
    static func supersededByActiveSibling(
        windowID: String,
        state: OptimisticWindowState,
        now: Date,
        optimisticStates: [String: OptimisticWindowState],
        snapshot: DockSnapshot,
        handoffGraceEnabled: Bool
    ) -> Bool {
        guard state.status == .active else { return false }
        guard let record = snapshot.windows[WindowID(rawValue: windowID)] else { return false }
        let crediblyActiveSibling = snapshot.windows.values.contains { sibling in
            guard sibling.pid == record.pid, sibling.id != record.id, sibling.status == .active else {
                return false
            }
            let inFlight = optimisticStates[sibling.id.rawValue]?.status
            return inFlight != .minimized && inFlight != .hidden
        }
        guard crediblyActiveSibling else { return false }
        guard handoffGraceEnabled,
              state.focusHandoffGrace,
              now.timeIntervalSince(state.createdAt) <= Self.handoffSupersessionGrace
        else { return true }
        let siblingActivationClicked = optimisticStates.contains { key, sibling in
            guard key != windowID, sibling.status == .active else { return false }
            guard let siblingRecord = snapshot.windows[WindowID(rawValue: key)] else { return false }
            return siblingRecord.pid == record.pid
        }
        return siblingActivationClicked
    }

    /// Sibling activation in flight (2026-08-25): another window of the same app holds an optimistic .active not yet fulfilled by the snapshot;
    /// focus is mid-handoff, and at this moment this window's "active" reading (snapshot or optimistic leftover) can't be trusted: when quickly
    /// clicking back and forth between two visible windows, clicking the background window was once wrongly collapsed (measured in Release, 6 cases in click-latency
    /// of "snapshot inactive but planned as minimize"). Used to downgrade the collapse decision in toggle planning
    /// (see LifecycleActionPlanner), same philosophy as the previous item: better a redundant activate than a wrong minimize.
    static func siblingActivationInFlight(
        windowID: String,
        optimisticStates: [String: OptimisticWindowState],
        snapshot: DockSnapshot
    ) -> Bool {
        guard let record = snapshot.windows[WindowID(rawValue: windowID)] else { return false }
        let ownActivationCreatedAt: Date? = {
            guard let own = optimisticStates[windowID], own.status == .active else { return nil }
            return own.createdAt
        }()
        return optimisticStates.contains { key, state in
            guard key != windowID, state.status == .active else { return false }
            guard let sibling = snapshot.windows[WindowID(rawValue: key)] else { return false }
            guard sibling.pid == record.pid, sibling.status != .active else { return false }
            // Timing ruling (2026-08-26, measured in Release batch restore): this window's own optimistic .active is newer than that
            // sibling's → the user's most recent activation intent landed on this window, and the second click is a strict same-window alternation (should collapse),
            // no downgrade; otherwise after a batch restore, collapsing window by window would all be flattened into empty activations. If the sibling's is newer (or this window has no optimistic state and
            // only a snapshot ghost) → focus is flowing to the sibling, keep the 08-25 downgrade, and the wrong-collapse bottom line is not broken.
            if let own = ownActivationCreatedAt, own > state.createdAt { return false }
            return true
        }
    }
}
