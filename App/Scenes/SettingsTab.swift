import Combine
import Foundation

/// The five tabs of the settings window (paged on 2026-08-24, with feedback pulled out as its own tab the same day; the "Dock bar" page was moved
/// wholesale into the status-bar menu on 2026-09-01, see `Docs/27`). Titles reuse the original section titles'
/// localization keys; all icons are available from macOS 11 (checked against CoreGlyphs name_availability).
/// Pure Foundation/Combine: the test target compiles it too, so do not pull in AppKit.
enum SettingsTab: String, CaseIterable {
    case general
    case advanced
    case about

    var title: String {
        switch self {
        case .general: return String(localized: "General")
        case .advanced: return String(localized: "Advanced")
        case .about: return String(localized: "About")
        }
    }

    var symbolName: String {
        switch self {
        case .general: return "gearshape"
        case .advanced: return "wrench.and.screwdriver"
        case .about: return "info.circle"
        }
    }
}

/// controller -> SwiftUI selected-tab bridge. The controller holds the single instance = the selected tab is remembered within the session;
/// **not persisted to UserDefaults** (the same rule as "the settings window does not remember its position across restarts").
/// The height-measuring probe must share this same instance, otherwise it measures a different page.
@MainActor
final class SettingsTabState: ObservableObject {
    @Published var selected: SettingsTab = .general
}
