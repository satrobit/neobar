import Carbon.HIToolbox
import Foundation

/// Key combination → display glyphs (such as "⌃⌘K"). A pure function, compiled by both the App and the test targets.
///
/// The main key's glyph is **frozen and stored into `StoredHotKeyShortcut.glyphs` at recording time**, and the display side only reads the stored
/// string: reverse-looking up a character from a keyCode goes through UCKeyTranslate + the current keyboard layout, which is both heavy to compute at display time and
/// drifts with the layout; at the moment of recording NSEvent already holds `charactersIgnoringModifiers`, for free.
enum HotKeyGlyphs {
    /// Modifier keys in a fixed order ⌃⌥⇧⌘ (the standard display order of the macOS menu bar).
    static func modifierString(carbonModifiers: UInt32) -> String {
        var out = ""
        if carbonModifiers & UInt32(controlKey) != 0 { out += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { out += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { out += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { out += "⌘" }
        return out
    }

    /// The main key's glyph. Returns nil when it isn't in the table and the event character isn't printable (callers treat it as "this key can't be used").
    static func keyString(keyCode: UInt32, charactersIgnoringModifiers: String?) -> String? {
        if let known = specialKeyNames[keyCode] { return known }
        guard let raw = charactersIgnoringModifiers, let scalar = raw.unicodeScalars.first else {
            return nil
        }
        // The characters of function keys like F keys fall in the Unicode private-use area (from U+F700); if not in the table, they aren't recognized;
        // control characters (Return and Tab are already in the table) are never recognized.
        guard scalar.value < 0xF700, !CharacterSet.controlCharacters.contains(scalar) else {
            return nil
        }
        let key = raw.uppercased()
        return key.isEmpty ? nil : key
    }

    /// The full display string; returns nil when the main key can't be displayed.
    static func display(keyCode: UInt32, carbonModifiers: UInt32, charactersIgnoringModifiers: String?) -> String? {
        guard let key = keyString(keyCode: keyCode, charactersIgnoringModifiers: charactersIgnoringModifiers) else {
            return nil
        }
        return modifierString(carbonModifiers: carbonModifiers) + key
    }

    private static let specialKeyNames: [UInt32: String] = [
        UInt32(kVK_LeftArrow): "←",
        UInt32(kVK_RightArrow): "→",
        UInt32(kVK_DownArrow): "↓",
        UInt32(kVK_UpArrow): "↑",
        UInt32(kVK_Space): "Space",
        UInt32(kVK_Return): "↩",
        UInt32(kVK_ANSI_KeypadEnter): "⌤",
        UInt32(kVK_Tab): "⇥",
        UInt32(kVK_Home): "↖",
        UInt32(kVK_End): "↘",
        UInt32(kVK_PageUp): "⇞",
        UInt32(kVK_PageDown): "⇟",
        UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3",
        UInt32(kVK_F4): "F4", UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6",
        UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8", UInt32(kVK_F9): "F9",
        UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
    ]
}
