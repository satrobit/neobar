import Foundation

/// Pure determination of the unit set for multi-screen strips (items 3 and 4, 2026-09-02). The orchestration layer uses it to decide which
/// `PanelCoordinator` units to create / tear down. **Screens are recorded by display UUID, never by `NSScreen.screens` index.**
enum TaskbarDisplaySet {
    struct Diff: Equatable {
        /// Order is consistent with `current`.
        let added: [String]
        /// Order is consistent with `previous`.
        let removed: [String]
        /// Order is consistent with `current`.
        let kept: [String]
    }

    static func diff(previous: [String], current: [String]) -> Diff {
        let previousSet = Set(previous)
        let currentSet = Set(current)
        return Diff(
            added: current.filter { !previousSet.contains($0) },
            removed: previous.filter { !currentSet.contains($0) },
            kept: current.filter { previousSet.contains($0) }
        )
    }

    /// The unit keys that should exist: items 1 and 2 have exactly one "follow settings" unit (nil), items 3 and 4 have one per present screen.
    /// When `connectedKeys` is empty (all screens unplugged, or no UUID could be read) it degrades to a single unit, so the strip does not vanish into thin air.
    static func desiredUnitKeys(placement: TaskbarScreenPlacement, connectedKeys: [String]) -> [String?] {
        guard placement.showsOnEveryDisplay, !connectedKeys.isEmpty else { return [nil] }
        return connectedKeys
    }
}
