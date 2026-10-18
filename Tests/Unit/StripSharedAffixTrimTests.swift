import XCTest

final class StripSharedAffixTrimTests: XCTestCase {
    func testSharedProfilePrefixIsRemoved() {
        XCTAssertEqual(
            StripSharedAffixTrim.trimmingSharedAffixes(["个人 — 起始页", "个人 — 哔哩哔哩"]),
            ["起始页", "哔哩哔哩"]
        )
    }

    /// Key case: the raw common prefix is "mio: N" (both words start with N), and it must fall back to the colon boundary,
    /// otherwise it would cut out "otifications" / "ew Tab".
    func testPrefixIsCutBackToASeparatorBoundary() {
        XCTAssertEqual(
            StripSharedAffixTrim.trimmingSharedAffixes(["mio: Notifications", "mio: New Tab"]),
            ["Notifications", "New Tab"]
        )
    }

    func testSharedSuffixIsRemoved() {
        XCTAssertEqual(
            StripSharedAffixTrim.trimmingSharedAffixes(["文档 - Pages", "简历 - Pages"]),
            ["文档", "简历"]
        )
    }

    /// Once there is a second profile, that segment starts to distinguish windows -- the whole group stays as is (dynamic behavior settled by the owner 2026-09-04).
    func testAPrefixThatNoLongerMatchesEveryCardIsKept() {
        let titles = ["个人 — 起始页", "个人 — 哔哩哔哩", "工作 — 文档"]
        XCTAssertEqual(StripSharedAffixTrim.trimmingSharedAffixes(titles), titles)
    }

    func testIdenticalTitlesAreKept() {
        let titles = ["New Tab", "New Tab"]
        XCTAssertEqual(StripSharedAffixTrim.trimmingSharedAffixes(titles), titles)
    }

    /// If trimming would make some entry empty -> the whole group is untouched; trimming only part of it must never happen.
    func testGroupIsKeptWhenAnyTitleWouldBecomeEmpty() {
        let titles = ["个人 — 起始页", "个人 — "]
        XCTAssertEqual(StripSharedAffixTrim.trimmingSharedAffixes(titles), titles)
    }

    func testSingleTitleIsUntouched() {
        XCTAssertEqual(StripSharedAffixTrim.trimmingSharedAffixes(["个人 — 起始页"]), ["个人 — 起始页"])
    }

    /// The common beginning does not fall on a separator boundary (unstructured repetition) -> untouched.
    func testUnstructuredSharedPrefixIsKept() {
        let titles = ["Report 2026 A", "Report 2026 B"]
        XCTAssertEqual(StripSharedAffixTrim.trimmingSharedAffixes(titles), titles)
    }

    func testTitlesWithNothingInCommonAreUntouched() {
        let titles = ["起始页", "哔哩哔哩"]
        XCTAssertEqual(StripSharedAffixTrim.trimmingSharedAffixes(titles), titles)
    }

    func testEmptyInputIsUntouched() {
        XCTAssertEqual(StripSharedAffixTrim.trimmingSharedAffixes([]), [])
    }

    func testPrefixAndSuffixCanBothGo() {
        XCTAssertEqual(
            StripSharedAffixTrim.trimmingSharedAffixes(["个人 — 起始页 - Safari", "个人 — 哔哩哔哩 - Safari"]),
            ["起始页", "哔哩哔哩"]
        )
    }
}
