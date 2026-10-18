import Foundation

/// Pure presentation / de-duplication decisions for the two auto-hide settings (system Dock + NeoBar) (covered by unit tests).
///
/// Lives in `App/Composition` rather than `Core/Support`: it is about how the **menu** is presented (the wording of the group headings,
/// when the confirmation row pops up), which is an application-layer presentation convention, not the UI-independent kind of decision that belongs in Core.
/// After `keyEquivalentPresentation` was removed on 2026-08-03 it no longer carries AppKit types,
/// but the reason for its placement is unchanged — do not move it again just to look "purer".
@MainActor
enum AutoHideToggleMenuModel {
    /// Group heading for the system Dock group (not clickable). The two sliders look identical, and without headings you cannot tell which controls what.
    ///
    /// ⌥⌘D is written into the title as **plain text** with no `keyEquivalent`: this row is not clickable to begin with, and setting one would let the menu capture it
    /// and make the disabled row look clickable. This key is owned by macOS and always in effect; we are merely telling the user it exists —
    /// now that the show/hide command is gone, it is the one-key entry for "temporarily bring the Dock back".
    static let nativeDockSectionTitle = String(localized: "The Dock (⌥⌘D to show/hide)")

    /// Group heading for the NeoBar group (not clickable), **symmetric** with the one above.
    ///
    /// The two groups used to be asymmetric — the system Dock had a heading and NeoBar did not, so with only one heading in the whole menu,
    /// "Open System Dock Settings…" and the NeoBar commands below it looked like they belonged together (owner feedback 2026-08-03).
    /// The clickable show/hide command was removed at the same time as this heading was added: to toggle always-visible, drag the slider or press ⌥⇧⌘D.
    ///
    /// The shortcut is likewise written into the title as **plain text** with no `keyEquivalent` (same reason as above);
    /// and it is mentioned only when the Carbon registration succeeded — if registration failed the keys do nothing, and writing it would be misleading.
    /// `glyphs` = the glyphs of the currently effective combination (since 2026-08-24 users can rebind the key, so ⌥⇧⌘D is no longer hard-coded).
    static func edgeSectionTitle(isHotKeyRegistered: Bool, glyphs: String) -> String {
        isHotKeyRegistered
            ? String(format: String(localized: "NeoBar (%@ to show/hide)"), glyphs)
            : String(localized: "NeoBar")
    }

    /// Display name of a slider stop. The slider itself and the confirmation row must share this one definition,
    /// otherwise the stop named in the confirmation row would not be the one shown on the slider.
    static func delayDisplayName(sliderIndex index: Int) -> String {
        switch index {
        case 0:
            return String(localized: "Always Visible")
        case AppSettingsStore.sliderIndexMax:
            return String(localized: "Never Wake")
        default:
            return String(format: "%.1fs", AppSettingsStore.delayFromSliderIndex(index))
        }
    }

    /// Every write to the system Dock ends with `killall Dock`, so the screen necessarily flashes once — this cannot be eliminated
    /// (changing `autohide-delay` has only this effective path on macOS); all we can do is make it happen **after** the user's explicit confirmation,
    /// so an expected flash does not feel strange. Hence the slider does not auto-commit; the confirmation appears only when the draft differs from the effective value.
    ///
    /// Compare **integer stops** rather than floating-point values: the slider can only rest on stops anyway, and comparing floats would be bitten by representation error.
    static func shouldShowNativeApply(draft: Double, applied: Double) -> Bool {
        AppSettingsStore.sliderIndexFromDelay(draft) != AppSettingsStore.sliderIndexFromDelay(applied)
    }

    /// Including the target stop in the title is intentional: it also reminds the user that "the stop you dragged to is not in effect yet".
    static func nativeApplyTitle(draft: Double) -> String {
        let name = delayDisplayName(sliderIndex: AppSettingsStore.sliderIndexFromDelay(draft))
        // Explicit %@ + String(format:) rather than the interpolation syntax of String(localized:): the latter's key is derived by the compiler
        // from the interpolation types (String → %@), so what the key looks like is not in front of you, and a mistake is only found at runtime.
        // With a hand-written placeholder the key is this literal itself, which scripts can check one by one.
        return String(format: String(localized: "Apply “%@” (the Dock will restart)"), name)
    }

    /// The system Dock's actual default delay when the autohide-delay key does not exist.
    static let systemDefaultAutohideDelay = 0.5

    /// System true value → the stop value the local mirror should have.
    static func storeDelay(systemEnabled: Bool, systemDelay: Double?) -> Double {
        guard systemEnabled else { return AppSettingsStore.neverHideDelay }
        let rawDelay = systemDelay ?? systemDefaultAutohideDelay
        // The system switch is already explicitly on; a negative delay can only be treated as an externally customized very short delay,
        // and must not leak through snapDelay and be misread as this app's "always-visible" sentinel -1.
        let enabledDelay = rawDelay.isFinite
            ? max(rawDelay, AppSettingsStore.finiteDelayMin)
            : AppSettingsStore.defaultNativeDockAutoHideDelay
        return AppSettingsStore.snapDelay(
            enabledDelay,
            fallbackForNonFinite: AppSettingsStore.defaultNativeDockAutoHideDelay
        )
    }

    /// Feed the system's actual state back into the local mirror, so the slider, title, and click direction all start from the same true value.
    /// Returns nil = already consistent, no change needed (`setNativeDockAutoHideDelay` also de-duplicates itself,
    /// but checking once here saves one pointless `@Published` notification).
    static func reconciledStoreDelay(
        systemEnabled: Bool,
        systemDelay: Double?,
        currentStoreDelay: Double
    ) -> Double? {
        let target = storeDelay(systemEnabled: systemEnabled, systemDelay: systemDelay)
        return currentStoreDelay == target ? nil : target
    }

    /// What value the local mirror should take after writing to the system. Four quadrants; **it cannot be a blanket "on failure, revert to previous"**:
    /// rolling back when the write succeeded but cannot be read back would make the UI show the opposite of the system setting that has already taken effect.
    ///
    /// |            | System readable | System unreadable |
    /// |------------|--------------|--------------|
    /// | **Write succeeded** | per the value read | keep target  |
    /// | **Write failed** | per the value read (may be a partial write) | keep previous |
    static func resolvedStoreDelay(
        writeSucceeded: Bool,
        systemState: NativeDockAutohideState?,
        target: Double,
        previous: Double
    ) -> Double {
        if let systemState {
            return storeDelay(systemEnabled: systemState.enabled, systemDelay: systemState.delay)
        }
        return writeSucceeded ? target : previous
    }

}
