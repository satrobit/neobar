import Foundation

/// Finder's membership and residency policy on the strip side (decided by the owner 2026-08-20, reversing "Finder is always resident and offers no keep state").
///
/// Finder now goes through the same "Keep in Dock" as ordinary apps: when checked (the default) there is always an app-level entry,
/// and when unchecked, that entry card disappears once all Finder windows are closed, and the window cards come back when a window is opened again. The drawer is also opened up,
/// **while the messaging area stays closed** -- an icon in the messaging area stands for "this app's main window", and Finder has no such main-window semantics.
///
/// The tracking layer (`AppTracker` / `FinderWindowRules`) is unaffected here: Finder is always absorbed and its entry survives a process restart,
/// "disappearing" happens only in the projection layer (`DockStripView.makeProjection`), so a window card can come back instantly once a window opens.
enum FinderTaskbarPolicy {
    /// Finder constants on the Core/App side. The Platform side has a separate `FinderWindowRules.bundleIdentifier` --
    /// that one governs window trackability, which is a different matter from membership; do not merge them.
    static let bundleID = "com.apple.finder"

    static func isFinder(_ bundleID: String?) -> Bool {
        bundleID == Self.bundleID
    }

    /// Whether Finder's app-level entry (the card shown when there are no windows) is displayed -- decided solely by "Keep in Dock".
    ///
    /// An ordinary running app with no windows still gets a fallback card, but Finder runs from boot onward,
    /// so without a gate here the checkbox would have no effect on Finder.
    static func showsAppLevelEntry(isKept: Bool) -> Bool {
        isKept
    }

    /// Whether it can be pinned on the left side of the Dock bar. Never for Finder.
    static func canMarkMessaging(_ bundleID: String) -> Bool {
        !bundleID.isEmpty && !isFinder(bundleID)
    }
}
