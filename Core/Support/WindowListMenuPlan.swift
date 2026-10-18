import Foundation

/// The "window list" entry at the top of the right-click menu for app-level icons (like the native Dock: ✓ = frontmost window, ◇ = minimized).
/// Only appears on entries where "one icon represents the whole app" (kept / messaging area / drawer / pinned Finder card);
/// a specific window card is itself that window, so it is not listed (owner 2026-08-24).
struct WindowMenuEntry: Equatable {
    enum Marker: Equatable {
        case none
        /// The app's frontmost (active) window — the row the native Dock marks with ✓.
        case front
        /// The whole group is minimized — the row the native Dock marks with ◇. Clicking goes through activate, which restores it.
        case minimized
    }

    /// The action target handed to `runtime.activate(windowID:)` on click (the group's current representative member).
    let actionWindowID: String
    let title: String
    let marker: Marker
}

enum WindowListMenuPlan {
    /// Takes all windows of a bundle from the snapshot, in strip order, folded by `groupID` (a native tab group is one row,
    /// background tabs are not listed separately — same single-seat model as the taskbar). **Reads the snapshot only, no AX**:
    /// the menu is built synchronously at the instant of the right-click (menus.md), and any live inventory would stall that moment.
    static func entries(
        snapshot: DockSnapshot,
        bundleID: String,
        fallbackTitle: String
    ) -> [WindowMenuEntry] {
        var groups: [[WindowRecord]] = []
        var indexByGroup: [String: Int] = [:]
        for id in snapshot.orderedWindowIDs {
            guard let record = snapshot.windows[id],
                  record.bundleIdentifier == bundleID,
                  // app-* fallback seats are not real windows; windows that are closing or already gone are not listed either.
                  !record.groupID.hasPrefix("app-"),
                  record.status != .closedPending,
                  record.status != .disappeared
            else { continue }
            if let idx = indexByGroup[record.groupID] {
                groups[idx].append(record)
            } else {
                indexByGroup[record.groupID] = groups.count
                groups.append([record])
            }
        }
        return groups.map { members in
            // The representative window follows the same rule as `StripItem.init(members:)`: active ?? first visible member ?? first.
            let representative = members.first { $0.status == .active }
                ?? members.first { $0.status != .minimized && $0.status != .hidden }
                ?? members[0]
            let marker: WindowMenuEntry.Marker
            if representative.status == .active {
                marker = .front
            } else if members.allSatisfy({ $0.status == .minimized }) {
                marker = .minimized
            } else {
                marker = .none
            }
            return WindowMenuEntry(
                actionWindowID: representative.id.rawValue,
                title: WindowDisplayTitle.resolve(
                    rawTitle: representative.title,
                    fallbackName: fallbackTitle
                ),
                marker: marker
            )
        }
    }
}
