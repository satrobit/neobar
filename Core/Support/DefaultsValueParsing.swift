import Foundation

/// Type narrowing for `Any?` read back from UserDefaults. Both rules were stepped on in two places (`AppSettingsStore` /
/// `NativeDockPreferencesService`), so they are consolidated into one:
/// - `Bool` / `CFBoolean` can bridge to `NSNumber`; without excluding by CF type first, `true` would be read as 1.0;
/// - NaN / +-inf reaching downstream `Int(...)` crashes outright (all NaN comparisons are false, so clamp doesn't work); every non-finite value is treated as missing.
enum DefaultsValueParsing {
    /// A genuine numeric object and finite; boolean, string, missing, NaN / inf -> nil.
    nonisolated static func finiteNumericValue(_ value: Any?) -> Double? {
        guard let value,
              CFGetTypeID(value as CFTypeRef) != CFBooleanGetTypeID(),
              let number = value as? NSNumber else {
            return nil
        }
        let result = number.doubleValue
        return result.isFinite ? result : nil
    }

    /// Recognizes only a genuine boolean object (`CFBoolean`); the numbers 0 / 1 don't count as booleans.
    nonisolated static func strictBooleanValue(_ value: Any?) -> Bool? {
        guard let value,
              CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID(),
              let number = value as? NSNumber else {
            return nil
        }
        return number.boolValue
    }
}
