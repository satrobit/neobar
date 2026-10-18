import Foundation

/// Whether a strip should draw a given entry under multi-screen mode 4. **Used only after the shared ordering layer** (`DockStripView.makeProjection`,
/// after `orderedLive`): the id set fed into `StripOrderStore.reconciled / sync / reorder` must be
/// identical on every screen, otherwise the screens mark each other's cards as "absent" and evict them from memory after 5s.
///
/// - `scope == nil`: no filtering (items 1, 2, 3, or non-pinned units under 4).
/// - `.launcher` (non-running kept placeholders, the messaging area, folders, the staging area) is always shown -- they are not windows and have no running dot.
/// - `.runningWithoutWindow` (app-level fallback cards, running kept apps left with only a placeholder) appears on only one strip: the screen where its window last was
///   (`AppEntry.lastWindowDisplayUUID`, which also changes when it is dragged to another strip); if unreadable -> the main screen (the menu bar screen).
///   **Having a running dot = only on one strip** (owner 2026-09-02, after seeing Chrome appear on both strips once all its windows were closed).
/// - `.window`: if the ownership key is nil (the inventory cannot read a position) or points to a screen no longer present -> lands on the main screen only; otherwise key == scope.
struct StripDisplayFilter: Equatable {
    enum Subject: Equatable {
        case launcher
        case runningWithoutWindow(displayUUID: String?)
        case window(displayUUID: String?)
    }

    let scope: String?
    let connectedUUIDs: Set<String>
    let primaryUUID: String?

    static let unfiltered = StripDisplayFilter(scope: nil, connectedUUIDs: [], primaryUUID: nil)

    func shows(_ subject: Subject) -> Bool {
        guard let scope else { return true }
        switch subject {
        case .launcher:
            return true
        case .runningWithoutWindow(let key), .window(let key):
            guard let key, connectedUUIDs.contains(key) else { return scope == primaryUUID }
            return key == scope
        }
    }
}
