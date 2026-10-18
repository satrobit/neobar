import Foundation

/// Which window the messaging-zone icon represents: a **pure decision** (2026-08-23). Three rules, strong to weak:
///
/// 1. Window title == app name -> main window. Feishu / QQ / WeChat after aliasing take this rule, unchanged from the status quo. **When several windows are all named after the app,**
///    prefer the non-minimized ones, then the one with the largest area (measured 2026-08-23: WeChat on cold start first pops up a 700x640 login window,
///    also titled "WeChat"; after login it is ordered out but still in CG, so the seat is kept; taking the first by creation order would
///    bind the icon to this invisible window, and the owner reported "the icon can summon but cannot collapse").
/// 2. After removing those the exclusion table marks as "explicitly not the main window", **exactly one window remains** -> that is the main window. Single-window apps such as Telegram and manually pinned
///    Slack take this rule: overseas messaging apps are almost all single-window, and their titles hold the conversation name /
///    unread count / system number, so rule 1 can never pass.
/// 3. Neither holds -> `nil`. The caller degrades to a **whole-app toggle** (the `.messagingApp` no-main-window
///    branch of `DockStripView`); the icon always responds, but standalone chat windows are collapsed together.
///
/// Rule 2 lifts the 2026-07-21 prohibition (back then, with WeChat's main window closed only "Notes" remained, and once it was absorbed as the main window the main window
/// could never be summoned back). **The precondition for lifting it is the exclusion table**: once Notes is excluded WeChat returns to "no main window", and clicking the icon still summons the
/// main window back. Discipline for the exclusion table:
/// - **Write exclusions only, never designations** ("X is not the main window", not "the main window is called X"): a wrong designation binds the icon to the wrong
///   window, which users cannot understand at all; a wrong exclusion at worst falls back to the generic rules.
/// - **Add an entry only when binding the wrong window is measured on this machine**; do not guess for apps never installed.
/// - The Chinese in the table is window-title data, not copy text, and is not localized (see the iron rule in `AGENTS.md`).
enum MessagingMainWindowDecision {
    struct WindowFact: Equatable {
        let id: String
        let title: String
        /// A minimized window is not preferred as the main window (only matters when several windows share the name).
        let isMinimized: Bool
        /// Window area (pt^2); the larger it is, the more it looks like the main window when several share the name. Write 0 if unknown.
        let area: CGFloat

        init(id: String, title: String, isMinimized: Bool = false, area: CGFloat = 0) {
            self.id = id
            self.title = title
            self.isMinimized = isMinimized
            self.area = area
        }
    }

    /// Titles explicitly not the main window (compared after normalization). WeChat "Notes" = the window that was bound wrongly in the 2026-07-21 measurement.
    static let excludedTitlesByBundleID: [String: Set<String>] = [
        "com.tencent.xinWeChat": ["笔记"],
    ]

    /// - Parameters:
    ///   - windows: the app's **real** windows (excluding the app-level fallback item), in any order.
    ///   - titleMatchesAppName: the criterion for rule 1, injected as a closure to keep `AppNameRegistry` on the caller side.
    /// - Returns: the id of the main window; `nil` = cannot recognize, the caller uses the app-level toggle.
    static func mainWindowID(
        bundleID: String,
        windows: [WindowFact],
        titleMatchesAppName: (String) -> Bool
    ) -> String? {
        let titled = windows.filter { titleMatchesAppName($0.title) }
        if let best = titled.max(by: { lhs, rhs in
            // "lhs < rhs" of max(by:): compare "not minimized" first, then area; when all are equal, keep the one that appeared first (stable).
            if lhs.isMinimized != rhs.isMinimized { return lhs.isMinimized }
            return lhs.area < rhs.area
        }) {
            return best.id
        }
        let excluded = excludedTitlesByBundleID[bundleID] ?? []
        let candidates = windows.filter { !excluded.contains(normalize($0.title)) }
        return candidates.count == 1 ? candidates[0].id : nil
    }

    static func normalize(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
