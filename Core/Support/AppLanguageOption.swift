import Foundation

/// The tiers of the UI language picker (2026-09-01 collapsed from three tiers to two and dropped "Follow System", the owner's call;
/// 2026-09-24 expanded to six tiers, adding Traditional Chinese / Japanese / German / French; for the three-tier version see `Docs/27`).
/// Sixteen tiers since Russian / Turkish / Hindi / Vietnamese joined: Spanish and Portuguese
/// each ship two regional files (`es` + `es-419`, `pt-BR` + `pt-PT`) so every region sees the
/// system words of its own Mac.
///
/// Mechanism: write `AppleLanguages` in the **app's own domain**. This is exactly the same key that macOS 13+ "System Settings -> General ->
/// Language & Region -> Applications" writes for per-app language; the two paths interoperate, and as a side effect per-app language
/// capability is brought to macOS 12. **Takes effect on next launch**: hot-switching with SwiftUI + hand-built AppKit menus + several resident
/// NSHostingViews would require rebuilding all panels, which isn't worth it; restarting is also the industry convention.
///
/// ⚠️ **What was deleted is the option, not the mechanism.** "Follow System" = the key doesn't exist, and that is still **the real state of someone
/// who has never picked a language**: their UI is still decided by macOS from the system language, not a word changed. The picker merely displays
/// "which tier is actually in effect right now", and the read path **never writes back**: the moment someone casually
/// `set`s during a read, the language gets pinned for every user who never chose, and people on an English system would be pinned to an inferred value.
/// Only an active user click writes the key.
///
/// Tier order is the picker order: the two Chinese tiers first, then English, then in the order `.lproj` files were added.
enum AppLanguageOption: String, CaseIterable, Equatable {
    case zhHans
    case zhHant
    case english
    case japanese
    case german
    case french
    case spanish
    case spanishLatinAmerica
    case portugueseBrazil
    case portuguesePortugal
    case italian
    case korean
    case russian
    case turkish
    case hindi
    case vietnamese

    /// Which tier should be shown currently.
    ///
    /// - `appDomainValue`: `AppleLanguages` read from **this app's domain**. ⚠️ The caller must not fetch it with
    ///   `UserDefaults.standard.array(forKey:)`: that inherits the global domain (the system language list is never empty),
    ///   and can't tell "never set" from "explicitly set". Use `CFPreferencesCopyAppValue` /
    ///   `persistentDomain(forName:)` to get this domain's value and pass it in.
    /// - `effectiveLocalization`: **the `.lproj` actually loaded** right now (`Bundle.main.preferredLocalizations.first`).
    ///   When never set, or the domain holds a language we don't have (e.g. the user picked Arabic for this app in System Settings), answer by it:
    ///   a language we do not ship really falls back to English, so the menu shows English too.
    ///
    /// **The fallback direction is English, not Chinese**: only language codes that are recognized hit the corresponding tier. Getting it backwards would make users on an English system
    /// see "Simplified Chinese" in the picker; the unit test pins exactly this.
    static func current(appDomainValue: [String]?, effectiveLocalization: String) -> AppLanguageOption {
        if let explicit = appDomainValue?.first, let option = option(matching: explicit) {
            return option
        }
        return option(matching: effectiveLocalization) ?? .english
    }

    /// Map a language code (`zh-Hans` / `zh-TW` / `zh_HK` / `ja-JP` / `de` / `fr-CA` / `en-US` ...)
    /// to a tier we have; return nil if unrecognized, leaving the fallback to the caller.
    ///
    /// The Traditional Chinese check must come before "starts with zh": `zh-Hant` / `zh-TW` / `zh-HK` / `zh-MO` all map to Traditional Chinese,
    /// and the other `zh`-prefixed codes (`zh` / `zh-Hans` / `zh-CN` / `zh-SG`) map to Simplified Chinese. A Hong Kong system's
    /// language code is `zh-Hant-HK` / `zh-HK`; both spellings must be recognized.
    static func option(matching code: String) -> AppLanguageOption? {
        let normalized = code.lowercased().replacingOccurrences(of: "_", with: "-")
        guard !normalized.isEmpty else { return nil }
        let parts = normalized.split(separator: "-").map(String.init)
        guard let language = parts.first else { return nil }
        switch language {
        case "zh":
            let tags = Set(parts.dropFirst())
            let isTraditional = !tags.isDisjoint(with: ["hant", "tw", "hk", "mo"])
            return isTraditional ? .zhHant : .zhHans
        case "en": return .english
        case "ja": return .japanese
        case "de": return .german
        case "fr": return .french
        case "it": return .italian
        case "ko": return .korean
        case "ru": return .russian
        case "tr": return .turkish
        // Hindi in Latin script (`hi-Latn`) is a language of its own to the system, which loads
        // English for it rather than our Devanagari `hi.lproj`.
        case "hi": return parts.contains("latn") ? nil : .hindi
        case "vi": return .vietnamese
        case "es": return regionalVariant(of: code, among: [.spanish, .spanishLatinAmerica])
        case "pt": return regionalVariant(of: code, among: [.portugueseBrazil, .portuguesePortugal])
        default: return nil
        }
    }

    /// Which of a language's regional files the system would load for `code` (`es-MX` → `es-419`,
    /// `pt-AO` → `pt-PT`). Asks Foundation's own matcher instead of keeping a list of region codes,
    /// so the menu names the same file the system actually loads. Only call it once the language
    /// subtag is known to match: for an unrelated code the matcher still returns its first candidate.
    private static func regionalVariant(of code: String, among variants: [AppLanguageOption]) -> AppLanguageOption? {
        let identifiers = variants.map(\.localizationIdentifier)
        guard let match = Bundle.preferredLocalizations(from: identifiers, forPreferences: [code]).first else {
            return variants.first
        }
        return variants.first { $0.localizationIdentifier == match } ?? variants.first
    }

    /// The value to write into `AppleLanguages`, which is also the `.lproj` directory name. Every tier is an explicit value;
    /// the "delete the key" path went away together with "Follow System".
    var appleLanguagesValue: [String] {
        [localizationIdentifier]
    }

    /// The corresponding `.lproj` name, consistent with `knownRegions` and the language blocks in `Localizable.xcstrings`.
    var localizationIdentifier: String {
        switch self {
        case .zhHans: return "zh-Hans"
        case .zhHant: return "zh-Hant"
        case .english: return "en"
        case .japanese: return "ja"
        case .german: return "de"
        case .french: return "fr"
        case .spanish: return "es"
        case .spanishLatinAmerica: return "es-419"
        case .portugueseBrazil: return "pt-BR"
        case .portuguesePortugal: return "pt-PT"
        case .italian: return "it"
        case .korean: return "ko"
        case .russian: return "ru"
        case .turkish: return "tr"
        case .hindi: return "hi"
        case .vietnamese: return "vi"
        }
    }

    /// Display name. **Every tier is hard-coded in its own language** (the common convention for language pickers), so there are no strings
    /// needing localization here: every UI language shows the same rows. The two Spanish and two
    /// Portuguese rows carry their region so the menu never shows two identical names.
    var displayName: String {
        switch self {
        case .zhHans: return "简体中文"
        case .zhHant: return "繁體中文"
        case .english: return "English"
        case .japanese: return "日本語"
        case .german: return "Deutsch"
        case .french: return "Français"
        case .spanish: return "Español (España)"
        case .spanishLatinAmerica: return "Español (Latinoamérica)"
        case .portugueseBrazil: return "Português (Brasil)"
        case .portuguesePortugal: return "Português (Portugal)"
        case .italian: return "Italiano"
        case .korean: return "한국어"
        case .russian: return "Русский"
        case .turkish: return "Türkçe"
        case .hindi: return "हिन्दी"
        case .vietnamese: return "Tiếng Việt"
        }
    }
}
