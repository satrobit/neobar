import Foundation

/// The **pure decision layer** for the launcher icon (LauncherChip) right-click menu: given "the display zone's running state + whether there are membership items",
/// it produces the kinds of menu items that should appear (order = render order). It is pulled out as pure logic so it can be unit-tested; the side effects of building the NSMenu stay in LauncherChip.
///
/// Key point: `isRunning` is passed the **display state of the zone the icon is in** (`LauncherChip.isRunning`, assigned per zone),
/// **not** the `NSWorkspace` process-alive state. In the not-running zone the process may still be alive (closing windows doesn't quit / resident),
/// but it is displayed as "not running", and the menu must also treat it as not running -- otherwise a "Hide / Quit" that contradicts the appearance would show up.

enum LauncherMenuItemKind: Equatable {
    /// "Open" -- appears only when not running, strictly ahead of recent files and membership items. In the running state Show / Hide / Quit replace it.
    case open
    /// Dock-style window list (✓ frontmost / ◇ minimized) -- placed first when running and real windows actually exist (2026-08-24).
    /// Belongs only to app-level icons; individual window cards don't go through this plan.
    case windowList
    case recentDocuments
    case show
    case hide
    /// Quit (including the Option alternate, Force Quit) -- the **constant last item**; membership items always come before it.
    case quit
    /// Membership / management items zone (checkable keep in Dock / pin to the left side of the Dock bar; 1 or more items decided by the caller).
    case membership
}

enum LauncherMenuPlan {
    /// - Parameters:
    ///   - isRunning: the **display state** of the zone the icon is in (not the process-alive state).
    ///   - isHidden: whether the app is hidden in the display state (decides "Show" vs "Hide").
    ///   - hasWindows: whether the app has real windows in the snapshot (decides whether to show the window list).
    ///   - hasMembership: whether there are membership / management items.
    static func itemKinds(isRunning: Bool,
                          isHidden: Bool,
                          hasWindows: Bool,
                          hasMembership: Bool) -> [LauncherMenuItemKind] {
        // Order (Docs/27 2026-08-24): window list -> recent files -> action items -> membership items -> Quit.
        // Quit must always be the last item -- if membership items sat after Quit, "Quit" would land third from last, contrary to user expectation.
        var kinds: [LauncherMenuItemKind] = []
        if !isRunning { kinds.append(.open) }
        if isRunning && hasWindows { kinds.append(.windowList) }
        if isRunning || hasMembership { kinds.append(.recentDocuments) }
        if isRunning { kinds.append(isHidden ? .show : .hide) }
        if hasMembership { kinds.append(.membership) }
        if isRunning { kinds.append(.quit) }
        return kinds
    }
}
