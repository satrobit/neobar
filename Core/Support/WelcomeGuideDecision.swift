import Foundation

/// Whether to show the "suggest hiding the system Dock" screen on first run.
///
/// Pure decision, no I/O, unit-testable. The caller (`AppDelegate`) reads the system Dock state, shows the dialog, and writes the marker.
///
/// ## Why a single boolean is not enough
///
/// Looking only at "has it been seen" would wrongly hit two groups of people:
///
/// - **Existing users who upgraded.** Most of them already hid the system Dock long ago (the README's "Recommended setup" section
///   has always suggested this), so showing it again is pure noise.
/// - **Sandboxed environments.** Writing system Dock preferences requires non-sandboxed (`NativeDockPreferencesService.isAvailable`),
///   so the dialog could not act anyway and would only offer a button that is bound to fail.
///
/// So read the real system Dock state once more and handle four cases separately. This follows the "four-quadrant" discipline of
/// `AutoHideToggleMenuModel.resolvedStoreDelay`: **unreadable** is a distinct state
/// and must not be conflated with "read as false".
enum WelcomeGuideDecision {
    enum Outcome: Equatable {
        /// Show the guide.
        case present
        /// Do not show, and **record as seen** — this machine never needs to be asked again.
        case skipAndMarkSeen
        /// Do not show, but **do not record**. The system state just could not be read this time; decide again on next launch.
        case skipWithoutMarking
    }

    /// - Parameters:
    ///   - hasSeenWelcome: `AppSettingsStore.hasSeenWelcome`
    ///   - canWriteDockPreferences: `NativeDockPreferencesService.isAvailable` (non-sandboxed)
    ///   - dockAutohideEnabled: whether the system Dock currently auto-hides; `nil` = **unreadable**
    ///     (`currentAutohideState()` returned nil), not "off"
    static func evaluate(
        hasSeenWelcome: Bool,
        canWriteDockPreferences: Bool,
        dockAutohideEnabled: Bool?
    ) -> Outcome {
        // Seen is seen. This check must come first: it is something the user already expressed
        // (whether they clicked "Hide it for me" or "Maybe later" at the time), and none of the later checks should overturn it.
        if hasSeenWelcome { return .skipAndMarkSeen }

        // A button that cannot act is better not shown. Sandboxing is a permanent property, so retire the guide on this machine outright.
        guard canWriteDockPreferences else { return .skipAndMarkSeen }

        guard let dockAutohideEnabled else {
            // CFPreferences occasionally cannot be read. **Do not mark as seen here** — a transient failure would
            // permanently swallow the guide; just read again on next launch, at the cost of one silent async read per launch.
            return .skipWithoutMarking
        }

        // Already auto-hidden, so the guide is pointless. Mark it while here, so that if the user later sets the Dock back to always-visible
        // they are not suddenly stopped by a "first-run guide" — at that point they clearly want the Dock back on purpose.
        if dockAutohideEnabled { return .skipAndMarkSeen }

        return .present
    }
}
