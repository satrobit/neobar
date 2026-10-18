import Foundation

/// Taskbar screen placement modes (four-tier multi-screen route: tier 2 shipped 2026-08-26, tiers 3 and 4 kicked off 2026-09-02).
/// The rawValue is the value persisted in UserDefaults. Older versions that read an unrecognized rawValue run as followMouse
/// and **do not rewrite the key** (`AppSettingsStore`), so new tiers may only be added, never renamed.
/// **Unrelated to the removed legacy `app.neobar.displayMode` key** -- that key is an orphan and is never read again.
enum TaskbarScreenMode: String {
    case followMouse
    case pinned
    /// ③ Shown on all screens, with identical content.
    case allScreens
    /// ④ Shown on all screens, each screen showing only its own windows.
    case allScreensPerDisplay
}

/// Persisted identity of the pinned screen. `uuid` comes from `CGDisplayCreateUUIDFromDisplayID` (EDID-based,
/// stable across plug/unplug / port changes / sleep-wake); `name` is a snapshot of `localizedName` at the moment of selection,
/// **for display in the settings page only** (after the screen is unplugged the Picker can still show "XX (not connected)"), and never takes part in matching.
struct PinnedScreenSelection: Equatable {
    let uuid: String
    let name: String
}

/// Taskbar display position. Default `.followMouse` = current behavior (switch screens on bottom-edge dwell).
enum TaskbarScreenPlacement: Equatable {
    case followMouse
    case pinned(PinnedScreenSelection)
    case allScreens
    case allScreensPerDisplay

    /// Hover screen switching (dwelling at the bottom edge to move the dock) only takes effect in follow-mouse mode -- when every screen has a bar there is nothing to move.
    var allowsHoverScreenSwitching: Bool {
        self == .followMouse
    }

    /// ③④: one taskbar unit per connected screen.
    var showsOnEveryDisplay: Bool {
        switch self {
        case .allScreens, .allScreensPerDisplay: return true
        case .followMouse, .pinned: return false
        }
    }

    var mode: TaskbarScreenMode {
        switch self {
        case .followMouse: return .followMouse
        case .pinned: return .pinned
        case .allScreens: return .allScreens
        case .allScreensPerDisplay: return .allScreensPerDisplay
        }
    }

    var pinnedSelection: PinnedScreenSelection? {
        switch self {
        case .pinned(let selection): return selection
        case .followMouse, .allScreens, .allScreensPerDisplay: return nil
        }
    }
}

/// Placement of a single taskbar unit (one `PanelCoordinator`). Under ①② the only unit is `.followSettings`,
/// which reads Settings to decide for itself; under ③④ the orchestration layer builds one `.fixed` unit per screen -- its behavior **is** the pinned tier
/// (no screen switching, wakes only from this screen's bottom edge, falls back to the main screen temporarily when this screen is absent), except that the screen is assigned by the orchestration layer rather than by Settings.
enum TaskbarUnitPlacement: Equatable {
    case followSettings
    case fixed(displayUUID: String)
}

/// Pure resolution of a pinned screen against the current screen set. No extra state is kept at runtime: it is idempotently re-resolved every time screen parameters /
/// settings change, so the bar naturally moves back as soon as the screen returns.
enum TaskbarScreenResolution {
    enum Outcome: Equatable {
        /// The pinned screen is present, landing at that index.
        case matched(index: Int)
        /// The pinned screen is absent; fall back to the main screen (0 if there is no main screen).
        case fallback(index: Int)
    }

    /// - Parameters:
    ///   - pinnedUUID: The stored pinned-screen UUID.
    ///   - screenUUIDs: UUIDs read one by one from the current `NSScreen.screens`; nil for any that can't be read (to avoid false matches).
    ///   - mainIndex: Index of `NSScreen.main` in screens (may be nil).
    /// - Returns: nil when the screen set is empty (nowhere to place it; the caller handles the fallback).
    static func resolve(pinnedUUID: String, screenUUIDs: [String?], mainIndex: Int?) -> Outcome? {
        guard !screenUUIDs.isEmpty else { return nil }
        if let index = screenUUIDs.firstIndex(where: { $0 == pinnedUUID }) {
            return .matched(index: index)
        }
        if let mainIndex, screenUUIDs.indices.contains(mainIndex) {
            return .fallback(index: mainIndex)
        }
        return .fallback(index: 0)
    }

    /// De-duplicates display names for the Settings Picker: when two monitors of the same model share a name, the second onward gets a number appended
    /// ("LG HDR 4K", "LG HDR 4K (2)"). The order matches the input.
    static func displayTitles(names: [String]) -> [String] {
        var counts: [String: Int] = [:]
        for name in names {
            counts[name, default: 0] += 1
        }
        var seen: [String: Int] = [:]
        return names.map { name in
            guard counts[name, default: 0] > 1 else { return name }
            let ordinal = seen[name, default: 0] + 1
            seen[name] = ordinal
            return ordinal == 1 ? name : "\(name) (\(ordinal))"
        }
    }
}

/// Pure presentation model for the status menu's "Single / Multi-screen mode >" submenu (on 2026-08-26 the entry point moved from the Settings window to the menu).
/// Same house rule as `LaunchAtLoginMenuPresentation`: decisions live here and are unit-testable; the controller only renders.
struct TaskbarScreenMenuPresentation {
    /// The choice a row represents. `token` is a string round trip for `NSMenuItem.representedObject`
    /// (the controller is also compiled in the test target, so ClosureMenuItem can't be used).
    enum Selection: Equatable {
        case followMouse
        case screen(uuid: String)
        case allScreens
        case allScreensPerDisplay

        private static let screenPrefix = "screen:"

        var token: String {
            switch self {
            case .followMouse: return "followMouse"
            case .allScreens: return "allScreens"
            case .allScreensPerDisplay: return "allScreensPerDisplay"
            case .screen(let uuid): return Self.screenPrefix + uuid
            }
        }

        init?(token: String) {
            switch token {
            case "followMouse": self = .followMouse
            case "allScreens": self = .allScreens
            case "allScreensPerDisplay": self = .allScreensPerDisplay
            default:
                guard token.hasPrefix(Self.screenPrefix) else { return nil }
                let uuid = String(token.dropFirst(Self.screenPrefix.count))
                guard !uuid.isEmpty else { return nil }
                self = .screen(uuid: uuid)
            }
        }

        /// Convenient for old tests / callers to fetch by screen UUID; nil for non-screen behaviors.
        var screenUUID: String? {
            if case .screen(let uuid) = self { return uuid }
            return nil
        }
    }

    struct Item: Equatable {
        let selection: Selection
        let title: String
        /// Grey text after the title, on the same line. Only "Follows the pointer" has one: its short name hides the
        /// trigger (the bar moves only after the pointer dwells on a screen's bottom edge).
        let hint: String?
        let isChecked: Bool
    }

    /// One row of the submenu: gray group header (not clickable) / separator / selectable option. Two groups + group headers is the shape the owner decided on 2026-09-02
    /// (with five flat rows, the two rows "All screens" and "All screens, each showing only its own windows" were unclear in meaning).
    enum Row: Equatable {
        case header(String)
        case separator
        case option(Item)
    }

    /// Everything before the screen name on a "Pinned to" row. The "Follows the pointer" hint is aligned to start after it.
    static var pinnedTitlePrefix: String {
        String(format: String(localized: "Pinned to %@"), "")
    }

    /// The whole row (along with its submenu) is not shown.
    let isHidden: Bool
    let rows: [Row]
    /// Selectable options (in display order), for tests / old callers.
    var items: [Item] {
        rows.compactMap { row in
            if case let .option(item) = row { return item }
            return nil
        }
    }

    /// - Parameter connectedScreens: The screens currently present, with `title` already de-duplicated (`displayTitles`).
    init(placement: TaskbarScreenPlacement, connectedScreens: [(uuid: String, title: String)]) {
        let pinned = placement.pinnedSelection
        // Hide only when there is exactly one screen **and** the current tier is neither pinned nor all-screens. Without the second half there'd be a dead end:
        // after pinning to an external screen and unplugging it / unplugging down to one screen while "All screens" is on, the whole row disappears -> no way back to "Follows the pointer".
        isHidden = connectedScreens.count < 2 && pinned == nil && !placement.showsOnEveryDisplay

        // Group 1 — single-display mode: hover-to-switch, or pinned to one screen.
        var rows: [Row] = [
            .header(String(localized: "Single-display mode")),
            .option(Item(
                selection: .followMouse,
                title: String(localized: "Follows the pointer"),
                hint: String(localized: "Hover a screen's bottom edge to switch"),
                isChecked: placement == .followMouse
            ))
        ]
        rows += connectedScreens.map { screen in
            .option(Item(
                selection: .screen(uuid: screen.uuid),
                title: String(format: String(localized: "Pinned to %@"), screen.title),
                hint: nil,
                isChecked: pinned?.uuid == screen.uuid
            ))
        }
        // The pinned screen is not present right now: append an item "Pinned to XX (not connected)" at the end of the first group and keep it selected -- the choice isn't lost, and reconnecting takes effect automatically.
        if let pinned, !connectedScreens.contains(where: { $0.uuid == pinned.uuid }) {
            rows.append(.option(Item(
                selection: .screen(uuid: pinned.uuid),
                title: String(
                    format: String(localized: "Pinned to %@"),
                    String(format: String(localized: "%@ (disconnected)"), pinned.name)
                ),
                hint: nil,
                isChecked: true
            )))
        }
        // Group 2 — multi-display mode: ③ same content everywhere / ④ each bar lists only its own screen.
        rows.append(.separator)
        rows.append(.header(String(localized: "Multi-display mode")))
        rows.append(.option(Item(
            selection: .allScreens,
            title: String(localized: "Mirrored bars"),
            hint: nil,
            isChecked: placement == .allScreens
        )))
        rows.append(.option(Item(
            selection: .allScreensPerDisplay,
            title: String(localized: "Separate bar per display"),
            hint: nil,
            isChecked: placement == .allScreensPerDisplay
        )))
        self.rows = rows
    }
}
