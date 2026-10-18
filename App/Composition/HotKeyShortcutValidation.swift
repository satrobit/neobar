import Carbon.HIToolbox
import Foundation

/// Why a recorded key combination was rejected. Used by the settings window to pick a plain-language sentence; a pure value, easy to unit test.
enum HotKeyShortcutRejection: Equatable {
    /// None of ⌘ / ⌃ / ⌥ is present (including only ⇧ pressed, or no modifier at all).
    case missingPrimaryModifier
    /// ⌥ alone or ⌥⇧: known to be unreliable on macOS 15 (FB15168205); the default shortcut was chosen back then precisely to avoid it.
    case unreliableModifiers
    /// Already taken by the system: ⌃⌥ (VoiceOver's modifier combination; rejected when ⌘ is absent), and exactly ⌥⌘D (macOS's
    /// own system Dock show/hide key -- it is owned by the system, and registering it is stealing, same rule as `GlobalHotKeyShortcut`).
    case reservedBySystem
    /// Esc / Delete / Forward Delete can't be the main key: they have other semantics in the recorder field (cancel),
    /// and using them as a global key would only clash with countless in-app meanings.
    case forbiddenKey
}

/// Pure decision for "can this combination be registered as NeoBar's global shortcut".
/// Compiled by both the App and test targets; the side effects of registration are in `GlobalHotKeyMonitor`.
enum HotKeyShortcutValidation {
    static func validate(keyCode: UInt32, carbonModifiers: UInt32) -> HotKeyShortcutRejection? {
        let cmd = UInt32(cmdKey)
        let opt = UInt32(optionKey)
        let ctl = UInt32(controlKey)
        let shf = UInt32(shiftKey)

        let forbiddenKeys: Set<UInt32> = [
            UInt32(kVK_Escape),
            UInt32(kVK_Delete),
            UInt32(kVK_ForwardDelete),
        ]
        if forbiddenKeys.contains(keyCode) { return .forbiddenKey }

        if carbonModifiers & (cmd | ctl | opt) == 0 { return .missingPrimaryModifier }
        if carbonModifiers == opt || carbonModifiers == (opt | shf) { return .unreliableModifiers }
        // ⌃⌥ without ⌘ = VoiceOver's modifier domain; ⌃⌥⌘X with ⌘ added is a common safe combination, allowed through.
        if carbonModifiers & ctl != 0, carbonModifiers & opt != 0, carbonModifiers & cmd == 0 {
            return .reservedBySystem
        }
        if carbonModifiers == (opt | cmd), keyCode == UInt32(kVK_ANSI_D) { return .reservedBySystem }
        return nil
    }
}
