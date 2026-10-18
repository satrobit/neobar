import XCTest

final class AppLanguageOptionTests: XCTestCase {
    /// When no language has been set (the key does not exist), show the **interface language actually in effect**, not blank or some hard-coded tier.
    func testUnsetDomainFollowsTheEffectiveLocalization() {
        XCTAssertEqual(AppLanguageOption.current(appDomainValue: nil, effectiveLocalization: "zh-Hans"), .zhHans)
        XCTAssertEqual(AppLanguageOption.current(appDomainValue: nil, effectiveLocalization: "zh-Hant"), .zhHant)
        XCTAssertEqual(AppLanguageOption.current(appDomainValue: nil, effectiveLocalization: "ja"), .japanese)
        XCTAssertEqual(AppLanguageOption.current(appDomainValue: nil, effectiveLocalization: "de"), .german)
        XCTAssertEqual(AppLanguageOption.current(appDomainValue: nil, effectiveLocalization: "fr"), .french)
        XCTAssertEqual(AppLanguageOption.current(appDomainValue: [], effectiveLocalization: "en"), .english)
        XCTAssertEqual(AppLanguageOption.current(appDomainValue: [""], effectiveLocalization: "en-US"), .english)
    }

    /// ⚠️ The fallback direction must be English. If reversed, a user on an English system opening Settings would see Simplified Chinese selected.
    /// For languages we do not have (Arabic and the like) the interface actually falls back to English, and the picker should show English too.
    func testFallbackIsEnglishForEveryUnsupportedLocalization() {
        XCTAssertEqual(AppLanguageOption.current(appDomainValue: nil, effectiveLocalization: "ar"), .english)
        XCTAssertEqual(AppLanguageOption.current(appDomainValue: nil, effectiveLocalization: "nl"), .english)
        XCTAssertEqual(AppLanguageOption.current(appDomainValue: nil, effectiveLocalization: ""), .english)
    }

    func testRecognizesChineseAndEnglishVariants() {
        XCTAssertEqual(AppLanguageOption.current(appDomainValue: ["zh-Hans", "en"], effectiveLocalization: "en"), .zhHans)
        XCTAssertEqual(AppLanguageOption.current(appDomainValue: ["zh-CN"], effectiveLocalization: "en"), .zhHans)
        XCTAssertEqual(AppLanguageOption.current(appDomainValue: ["zh"], effectiveLocalization: "en"), .zhHans, "裸 zh 归简中")
        XCTAssertEqual(AppLanguageOption.current(appDomainValue: ["en"], effectiveLocalization: "zh-Hans"), .english)
        XCTAssertEqual(AppLanguageOption.current(appDomainValue: ["en-US"], effectiveLocalization: "zh-Hans"), .english)
        XCTAssertEqual(AppLanguageOption.current(appDomainValue: ["EN"], effectiveLocalization: "zh-Hans"), .english, "大小写不敏感")
    }

    /// The Traditional Chinese check must run ahead of "starts with zh"; the three variants Taiwan / Hong Kong / Macau and the underscore form must all be recognized.
    func testTraditionalChineseVariantsAllLandOnZhHant() {
        for code in ["zh-Hant", "zh-TW", "zh-HK", "zh-MO", "zh-Hant-HK", "zh_TW", "ZH-HANT"] {
            XCTAssertEqual(AppLanguageOption.option(matching: code), .zhHant, code)
        }
        for code in ["zh-Hans", "zh-CN", "zh-SG", "zh-Hans-CN", "zh"] {
            XCTAssertEqual(AppLanguageOption.option(matching: code), .zhHans, code)
        }
    }

    func testRecognizesRegionalVariantsOfTheNewLanguages() {
        XCTAssertEqual(AppLanguageOption.option(matching: "ja-JP"), .japanese)
        XCTAssertEqual(AppLanguageOption.option(matching: "de-CH"), .german)
        XCTAssertEqual(AppLanguageOption.option(matching: "fr-CA"), .french)
        XCTAssertEqual(AppLanguageOption.option(matching: "fr_FR"), .french)
        XCTAssertEqual(AppLanguageOption.option(matching: "it-CH"), .italian)
        XCTAssertEqual(AppLanguageOption.option(matching: "ko-KR"), .korean)
        XCTAssertEqual(AppLanguageOption.option(matching: "ru-RU"), .russian)
        XCTAssertEqual(AppLanguageOption.option(matching: "ru-UA"), .russian)
        XCTAssertEqual(AppLanguageOption.option(matching: "tr-TR"), .turkish)
        XCTAssertEqual(AppLanguageOption.option(matching: "hi-IN"), .hindi)
        XCTAssertNil(AppLanguageOption.option(matching: "hi-Latn-IN"), "the system loads English for Latin-script Hindi")
        XCTAssertEqual(AppLanguageOption.option(matching: "vi-VN"), .vietnamese)
    }

    /// Spanish and Portuguese ship two regional files each. A region code must land on the file
    /// the system itself would load, or the menu ticks one variant while the UI shows the other.
    func testSpanishAndPortugueseRegionsLandOnTheFileTheSystemLoads() {
        for code in ["es-MX", "es-419", "es-US", "es-AR", "es-CO", "es_MX", "ES-MX"] {
            XCTAssertEqual(AppLanguageOption.option(matching: code), .spanishLatinAmerica, code)
        }
        for code in ["es", "es-ES", "es_ES", "es-GQ"] {
            XCTAssertEqual(AppLanguageOption.option(matching: code), .spanish, code)
        }
        for code in ["pt", "pt-BR", "pt_BR"] {
            XCTAssertEqual(AppLanguageOption.option(matching: code), .portugueseBrazil, code)
        }
        for code in ["pt-PT", "pt-AO", "pt-MZ", "pt_PT"] {
            XCTAssertEqual(AppLanguageOption.option(matching: code), .portuguesePortugal, code)
        }
        XCTAssertEqual(AppLanguageOption.current(appDomainValue: nil, effectiveLocalization: "es-419"), .spanishLatinAmerica)
        XCTAssertEqual(AppLanguageOption.current(appDomainValue: nil, effectiveLocalization: "pt-PT"), .portuguesePortugal)
    }

    /// The user chose in System Settings a language for this app that we do not have: the domain holds `ar`, the interface actually falls back to English,
    /// and the picker shows English per the `.lproj` actually in effect -- it does not falsely claim the user chose Chinese.
    func testUnsupportedLanguageInDomainFallsBackToTheEffectiveLocalization() {
        XCTAssertEqual(AppLanguageOption.current(appDomainValue: ["ar"], effectiveLocalization: "en"), .english)
        XCTAssertEqual(AppLanguageOption.current(appDomainValue: ["ar"], effectiveLocalization: "ja"), .japanese)
    }

    func testAppleLanguagesValueRoundTripsThroughCurrent() {
        for option in AppLanguageOption.allCases {
            XCTAssertEqual(
                AppLanguageOption.current(
                    appDomainValue: option.appleLanguagesValue,
                    // Deliberately pass a different interface language: the explicit value must override the inferred one.
                    effectiveLocalization: option == .zhHans ? "en" : "zh-Hans"
                ),
                option,
                "写下去再读回来必须是同一档：\(option)"
            )
        }
    }

    /// The values written into `AppleLanguages` are also `.lproj` directory names, and each must really exist in the build products.
    func testLocalizationIdentifiersAreDistinctAndMatchTheLprojNames() {
        let identifiers = AppLanguageOption.allCases.map(\.localizationIdentifier)
        XCTAssertEqual(Set(identifiers).count, identifiers.count)
        XCTAssertEqual(
            Set(identifiers),
            ["zh-Hans", "zh-Hant", "en", "ja", "de", "fr", "es", "es-419", "pt-BR", "pt-PT", "it", "ko", "ru", "tr", "hi", "vi"]
        )
    }

    func testDisplayNamesAreLanguageStable() {
        XCTAssertEqual(AppLanguageOption.zhHans.displayName, "简体中文", "语言名用它自己的语言写死")
        XCTAssertEqual(AppLanguageOption.zhHant.displayName, "繁體中文")
        XCTAssertEqual(AppLanguageOption.english.displayName, "English")
        XCTAssertEqual(AppLanguageOption.japanese.displayName, "日本語")
        XCTAssertEqual(AppLanguageOption.german.displayName, "Deutsch")
        XCTAssertEqual(AppLanguageOption.french.displayName, "Français")
        XCTAssertEqual(AppLanguageOption.spanish.displayName, "Español (España)")
        XCTAssertEqual(AppLanguageOption.spanishLatinAmerica.displayName, "Español (Latinoamérica)")
        XCTAssertEqual(AppLanguageOption.portugueseBrazil.displayName, "Português (Brasil)")
        XCTAssertEqual(AppLanguageOption.portuguesePortugal.displayName, "Português (Portugal)")
        XCTAssertEqual(AppLanguageOption.italian.displayName, "Italiano")
        XCTAssertEqual(AppLanguageOption.korean.displayName, "한국어")
        XCTAssertEqual(AppLanguageOption.russian.displayName, "Русский")
        XCTAssertEqual(AppLanguageOption.turkish.displayName, "Türkçe")
        XCTAssertEqual(AppLanguageOption.hindi.displayName, "हिन्दी")
        XCTAssertEqual(AppLanguageOption.vietnamese.displayName, "Tiếng Việt")
    }
}
