import Foundation

/// State container of the old observation pipeline (`ObservationPipeline`). **The shipping App doesn't use it**: only the window-lab
/// diagnostic tool instantiates this pipeline; the App's window truth is built inline by `AppTracker.reconcile()` and published as
/// `DockSnapshot` (`Core/Model/DockSnapshot.swift`).
@MainActor
final class DockState {
    private(set) var snapshot: DockSnapshot = .empty

    func commit(_ update: StateUpdate) {
        var next = snapshot
        if let windowRecord = update.windowRecord {
            next.windows[windowRecord.id] = windowRecord
        } else {
            next.windows.removeValue(forKey: update.windowID)
        }
        next.orderedWindowIDs = update.orderedWindowIDs
        guard next != snapshot else { return }
        snapshot = next
    }
}
