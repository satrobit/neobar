import Foundation

/// State of the three checkboxes on the first-run guide screen.
///
/// All ticked by default (`recommended`). The three belong to the one thing "hand the system Dock over to NeoBar", but **may be ticked separately**:
/// this writes someone else's system preferences, so the user should have room to decline any one of them (decided by the owner on 2026-08-28).
struct WelcomeGuideSelection: Equatable {
    var hidesDock: Bool
    var usesScaleMinimizeEffect: Bool
    var minimizesIntoAppIcon: Bool

    static let recommended = WelcomeGuideSelection(
        hidesDock: true,
        usesScaleMinimizeEffect: true,
        minimizesIntoAppIcon: true
    )

    var isEmpty: Bool { !hidesDock && !usesScaleMinimizeEffect && !minimizesIntoAppIcon }
}

/// Which items a recommended-settings write will touch. `autoHideDelay == nil` means **not touching** `autohide` /
/// `autohide-delay` at all: not "write a default value"; the two mean completely different things to the four-quadrant read-back.
struct NativeDockRecommendations: Equatable {
    var autoHideDelay: Double?
    var minimizeEffectScale: Bool
    var minimizeIntoAppIcon: Bool

    var isEmpty: Bool { autoHideDelay == nil && !minimizeEffectScale && !minimizeIntoAppIcon }
}

extension WelcomeGuideSelection {
    /// Ticks → which keys to write. **This step is where the two minimize options are most likely to be wired the wrong way round in the whole chain**, so it is split out as a
    /// pure function with unit tests (`WelcomeGuideDecisionTests`); testing only `NativeDockRecommendations` can't catch a swap.
    ///
    /// - Parameter hideDelay: which tier to land on when "Hide the system Dock" is ticked, passed by the caller as
    ///   `AppSettingsStore.neverWakeDelay`: Core shouldn't know the App layer's constants.
    func recommendations(hideDelay: Double) -> NativeDockRecommendations {
        NativeDockRecommendations(
            autoHideDelay: hidesDock ? hideDelay : nil,
            minimizeEffectScale: usesScaleMinimizeEffect,
            minimizeIntoAppIcon: minimizesIntoAppIcon
        )
    }
}
