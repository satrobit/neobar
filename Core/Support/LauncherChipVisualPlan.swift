import Foundation

/// The **pure visual decision layer** of LauncherChip: given the running state, it produces whether the running dot below the icon should be drawn.
/// It is pulled out as pure logic so it can be unit-tested; rendering side effects stay in LauncherChip.
///
/// This type has only one judgment left, but **the signal it carries is now the only one**: the owner removed state-based icon dimming
/// on 2026-08-02 (light and dark together; rationale in `Docs/27-product-decisions.md`), so "is this app still alive"
/// is expressed entirely by whether this dot is present -- running = dot, quit = no dot, regardless of the zone (messaging zone / drawer / kept icons).
/// "Running but hidden / minimized" no longer has any icon-level representation, a cost that was explicitly accepted.
enum LauncherChipVisualPlan {
    struct Visual: Equatable {
        let showsRunningDot: Bool
    }

    static func visual(isRunning: Bool) -> Visual {
        Visual(showsRunningDot: isRunning)
    }
}
