import Foundation

/// Pure decision: which strip chips draw the **front-window bar** (the running dot stretched
/// into a short capsule) because they stand for the window that is in front right now.
///
/// Window-level by design (owner 2026-10-16): only the focused window of the frontmost app,
/// never every window of that app. `app-*` fallback chips stand for an application, not a
/// window — their status never carries `.active` and they are excluded explicitly so that
/// never changes by accident. With no focused window on the bar (desktop clicked, frontmost
/// app has no window) nothing widens: that is the truthful answer.
///
/// The optimistic overlay wins over the snapshot so the bar moves the moment a card is
/// clicked instead of waiting for the next inventory round; the newest `.active` prediction
/// is the user's latest intent. A chip whose own window holds an in-flight minimize / hide
/// prediction is dropped even if the snapshot still says `.active` — the bar must not stay
/// on a card that is visibly folding away.
enum FrontWindowIndicatorDecision {
    static func frontWindowChipIDs(
        items: [StripItem],
        optimisticStates: [String: OptimisticWindowState]
    ) -> Set<String> {
        let candidates = items.filter { !$0.isAppLevelFallback }
        let predicted = candidates.compactMap { item -> (id: String, createdAt: Date)? in
            guard let state = optimisticStates[item.actionWindowID], state.status == .active else {
                return nil
            }
            return (item.id, state.createdAt)
        }
        if let newest = predicted.max(by: { $0.createdAt < $1.createdAt }) {
            return [newest.id]
        }
        let confirmed = candidates.filter { item in
            guard item.status == WindowStatus.active.rawValue else { return false }
            guard let inFlight = optimisticStates[item.actionWindowID] else { return true }
            return inFlight.status == .active
        }
        return Set(confirmed.map(\.id))
    }
}
