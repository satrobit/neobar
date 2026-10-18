import Foundation

/// Drawer display-order layer (drag reordering inside the drawer, 2026-06-21). The drawer is **app-centric**: one icon per bundleID,
/// and the order is remembered permanently by bundleID. A bundleID is stable across restarts, unlike the task strip's cgWindowID with its boot-cycle concern, so
/// the drawer order can be persisted unconditionally and kept forever.
///
/// **The crux: record the order over the full set of placements, not trimmed to the currently visible icons.** A non-kept member is hidden when it quits,
/// but its placement and relative order are kept, and on the next launch it returns to its original position.
///
/// Same shape as `StripOrderStore` but simpler: no boot-cycle guard (a bundleID is not reused), no absence grace
/// (the member set is stable and, unlike windows, does not flicker).
@MainActor
final class DrawerOrderStore: ObservableObject {
    @Published private(set) var order: [String] = []
    private let key = "drawerDisplayOrder"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        order = defaults.stringArray(forKey: key) ?? []
    }

    /// Display order = remembered order ∩ the full current member set, with new members appended at the end. A pure function, safe to read in body.
    func reconciled(members: [String]) -> [String] {
        let memberSet = Set(members)
        var result = order.filter { memberSet.contains($0) }
        let known = Set(result)
        for m in members where !known.contains(m) { result.append(m) }
        return result
    }

    /// Converge the persisted order when the full member set changes. **Called as a side effect, never during body evaluation.**
    func sync(members: [String]) {
        let next = reconciled(members: members)
        if next != order { order = next; persist() }
    }

    /// Mirrors MessagingAppStore.reorder: operate on the full persisted order so
    /// hidden placements keep their relative order while visible peers move.
    func reorder(draggedID: String, relativeTo targetID: String, after: Bool) {
        guard draggedID != targetID,
              let from = order.firstIndex(of: draggedID) else { return }
        var next = order
        next.remove(at: from)
        guard let target = next.firstIndex(of: targetID) else { return }
        next.insert(draggedID, at: after ? target + 1 : target)
        if next != order { order = next; persist() }
    }

    /// Puts `ids` first, in that order (`DrawerAppDrop.frontOrder`). Ids not yet members are
    /// placed too, so call it before adding them to `DrawerStore`.
    func moveToFront(_ ids: [String]) {
        place(ids, at: .front)
    }

    /// Puts `ids` at `placement` as one block (`DrawerAppDrop.order`); same contract as
    /// `moveToFront`: call it before the ids join `DrawerStore`.
    func place(_ ids: [String], at placement: DrawerAppDrop.Placement) {
        let next = DrawerAppDrop.order(existing: order, dropped: ids, placement: placement)
        if next != order { order = next; persist() }
    }

    private func persist() {
        defaults.set(order, forKey: key)
    }
}
