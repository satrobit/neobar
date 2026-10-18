import XCTest

final class TaskbarScreenPlacementTests: XCTestCase {
    // MARK: - resolve

    func testResolveMatchesPinnedScreen() {
        let outcome = TaskbarScreenResolution.resolve(
            pinnedUUID: "B",
            screenUUIDs: ["A", "B", "C"],
            mainIndex: 0
        )
        XCTAssertEqual(outcome, .matched(index: 1))
    }

    func testResolveFallsBackToMainWhenPinnedAbsent() {
        let outcome = TaskbarScreenResolution.resolve(
            pinnedUUID: "X",
            screenUUIDs: ["A", "B"],
            mainIndex: 1
        )
        XCTAssertEqual(outcome, .fallback(index: 1))
    }

    func testResolveFallsBackToZeroWhenMainMissing() {
        let outcome = TaskbarScreenResolution.resolve(
            pinnedUUID: "X",
            screenUUIDs: ["A", "B"],
            mainIndex: nil
        )
        XCTAssertEqual(outcome, .fallback(index: 0))
    }

    func testResolveFallsBackToZeroWhenMainIndexOutOfRange() {
        let outcome = TaskbarScreenResolution.resolve(
            pinnedUUID: "X",
            screenUUIDs: ["A"],
            mainIndex: 5
        )
        XCTAssertEqual(outcome, .fallback(index: 0))
    }

    func testResolveNilUUIDNeverMatches() {
        // A screen whose UUID cannot be read (nil) must not be matched by any pinned value.
        let outcome = TaskbarScreenResolution.resolve(
            pinnedUUID: "X",
            screenUUIDs: [nil, "A"],
            mainIndex: 0
        )
        XCTAssertEqual(outcome, .fallback(index: 0))
    }

    func testResolveEmptyScreensReturnsNil() {
        XCTAssertNil(TaskbarScreenResolution.resolve(pinnedUUID: "X", screenUUIDs: [], mainIndex: nil))
    }

    // MARK: - displayTitles

    func testDisplayTitlesUniqueNamesUntouched() {
        XCTAssertEqual(
            TaskbarScreenResolution.displayTitles(names: ["内建显示器", "LG HDR 4K"]),
            ["内建显示器", "LG HDR 4K"]
        )
    }

    func testDisplayTitlesNumbersDuplicatesFromSecondOccurrence() {
        XCTAssertEqual(
            TaskbarScreenResolution.displayTitles(names: ["LG HDR 4K", "LG HDR 4K", "内建显示器", "LG HDR 4K"]),
            ["LG HDR 4K", "LG HDR 4K (2)", "内建显示器", "LG HDR 4K (3)"]
        )
    }

    // MARK: - placement

    func testOnlyFollowMouseAllowsHoverScreenSwitching() {
        XCTAssertTrue(TaskbarScreenPlacement.followMouse.allowsHoverScreenSwitching)
        let pinned = TaskbarScreenPlacement.pinned(PinnedScreenSelection(uuid: "A", name: "LG"))
        XCTAssertFalse(pinned.allowsHoverScreenSwitching)
        XCTAssertFalse(TaskbarScreenPlacement.allScreens.allowsHoverScreenSwitching)
        XCTAssertFalse(TaskbarScreenPlacement.allScreensPerDisplay.allowsHoverScreenSwitching)
    }

    func testShowsOnEveryDisplayOnlyForAllScreensModes() {
        XCTAssertFalse(TaskbarScreenPlacement.followMouse.showsOnEveryDisplay)
        XCTAssertFalse(TaskbarScreenPlacement.pinned(PinnedScreenSelection(uuid: "A", name: "LG")).showsOnEveryDisplay)
        XCTAssertTrue(TaskbarScreenPlacement.allScreens.showsOnEveryDisplay)
        XCTAssertTrue(TaskbarScreenPlacement.allScreensPerDisplay.showsOnEveryDisplay)
        XCTAssertEqual(TaskbarScreenPlacement.allScreens.mode, .allScreens)
        XCTAssertEqual(TaskbarScreenPlacement.allScreensPerDisplay.mode, .allScreensPerDisplay)
        XCTAssertNil(TaskbarScreenPlacement.allScreens.pinnedSelection)
    }

    func testModeAndSelectionAccessors() {
        XCTAssertEqual(TaskbarScreenPlacement.followMouse.mode, .followMouse)
        XCTAssertNil(TaskbarScreenPlacement.followMouse.pinnedSelection)
        let selection = PinnedScreenSelection(uuid: "A", name: "LG")
        XCTAssertEqual(TaskbarScreenPlacement.pinned(selection).mode, .pinned)
        XCTAssertEqual(TaskbarScreenPlacement.pinned(selection).pinnedSelection, selection)
    }

    // MARK: - Status-menu submenu (2026-08-26: entry moved from the settings window to the menu)

    private let screens = [(uuid: "A", title: "内建显示器"), (uuid: "B", title: "LG HDR 4K")]

    func testMenuHiddenWithSingleScreenAndFollowMouse() {
        let presentation = TaskbarScreenMenuPresentation(
            placement: .followMouse,
            connectedScreens: [(uuid: "A", title: "内建显示器")]
        )
        XCTAssertTrue(presentation.isHidden)
    }

    /// After pinning to an external screen and unplugging it -> only one screen remains, but the whole row must still be there, otherwise there is no way to switch back to "Follow mouse".
    func testMenuVisibleWithSingleScreenWhilePinned() {
        let presentation = TaskbarScreenMenuPresentation(
            placement: .pinned(PinnedScreenSelection(uuid: "B", name: "LG HDR 4K")),
            connectedScreens: [(uuid: "A", title: "内建显示器")]
        )
        XCTAssertFalse(presentation.isHidden)
    }

    func testMenuVisibleWithTwoScreens() {
        let presentation = TaskbarScreenMenuPresentation(placement: .followMouse, connectedScreens: screens)
        XCTAssertFalse(presentation.isHidden)
    }

    func testFollowMouseIsFirstItemAndCheckedWhenNotPinned() {
        let presentation = TaskbarScreenMenuPresentation(placement: .followMouse, connectedScreens: screens)
        XCTAssertEqual(presentation.items.count, 5)
        XCTAssertEqual(presentation.items[0].selection, .followMouse)
        XCTAssertTrue(presentation.items[0].isChecked)
        XCTAssertEqual(
            presentation.items.map(\.selection),
            [.followMouse, .screen(uuid: "A"), .screen(uuid: "B"), .allScreens, .allScreensPerDisplay]
        )
        XCTAssertEqual(presentation.items.filter(\.isChecked).count, 1)
    }

    func testPinnedScreenIsTheOnlyCheckedItem() {
        let presentation = TaskbarScreenMenuPresentation(
            placement: .pinned(PinnedScreenSelection(uuid: "B", name: "LG HDR 4K")),
            connectedScreens: screens
        )
        XCTAssertEqual(presentation.items.count, 5)
        XCTAssertFalse(presentation.items[0].isChecked)
        XCTAssertEqual(presentation.items.filter(\.isChecked).map(\.selection), [.screen(uuid: "B")])
    }

    /// The pinned screen is not present right now: one item is appended at the end and stays selected, so the selection is not lost.
    func testAbsentPinnedScreenGetsTrailingCheckedItem() {
        let presentation = TaskbarScreenMenuPresentation(
            placement: .pinned(PinnedScreenSelection(uuid: "Z", name: "Dell U2720Q")),
            connectedScreens: screens
        )
        XCTAssertEqual(presentation.items.count, 6)
        // The disconnected pinned row follows the present screens, still inside the single-screen mode group.
        XCTAssertEqual(presentation.items[3].selection, .screen(uuid: "Z"))
        XCTAssertEqual(presentation.items.filter(\.isChecked).map(\.selection), [.screen(uuid: "Z")])
        // The copy changes with the language; only lock that the screen's name is carried into the title.
        XCTAssertTrue(presentation.items[3].title.contains("Dell U2720Q") == true)
    }

    /// Screen rows read "Pinned to <name>"; the disconnected row wraps the "(disconnected)" name the same way.
    func testScreenRowsCarryThePinnedPrefix() {
        let presentation = TaskbarScreenMenuPresentation(
            placement: .pinned(PinnedScreenSelection(uuid: "Z", name: "Dell U2720Q")),
            connectedScreens: screens
        )
        let pinnedFormat = String(localized: "Pinned to %@")
        XCTAssertEqual(presentation.items[1].title, String(format: pinnedFormat, "内建显示器"))
        XCTAssertEqual(presentation.items[2].title, String(format: pinnedFormat, "LG HDR 4K"))
        XCTAssertEqual(
            presentation.items[3].title,
            String(format: pinnedFormat, String(format: String(localized: "%@ (disconnected)"), "Dell U2720Q"))
        )
    }

    /// Only the follow-bar row carries the grey hint; its short name does not say the bar waits for a bottom-edge dwell.
    func testOnlyFollowMouseHasHint() {
        let presentation = TaskbarScreenMenuPresentation(placement: .followMouse, connectedScreens: screens)
        XCTAssertEqual(presentation.items[0].hint, String(localized: "Hover a screen's bottom edge to switch"))
        XCTAssertEqual(presentation.items.dropFirst().compactMap(\.hint), [])
    }

    /// The hint aligns after this prefix, so it must really be what the "Pinned to" rows start with.
    func testPinnedTitlePrefixIsTheStartOfEveryScreenRow() {
        let presentation = TaskbarScreenMenuPresentation(placement: .followMouse, connectedScreens: screens)
        let prefix = TaskbarScreenMenuPresentation.pinnedTitlePrefix
        XCTAssertFalse(prefix.isEmpty)
        XCTAssertEqual(presentation.items[1].title, prefix + "内建显示器")
        XCTAssertEqual(presentation.items[2].title, prefix + "LG HDR 4K")
    }

    // MARK: - Cases 3 and 4: all-screens tier (2026-09-02)

    func testAllScreensIsTheOnlyCheckedItemAndSitsAfterScreens() {
        let presentation = TaskbarScreenMenuPresentation(placement: .allScreens, connectedScreens: screens)
        XCTAssertEqual(presentation.items.filter(\.isChecked).map(\.selection), [.allScreens])
        // Order: follow mouse / each screen / all screens / all screens (each screen shows only its own windows).
        XCTAssertEqual(presentation.items.map(\.selection).suffix(2), [.allScreens, .allScreensPerDisplay])
    }

    /// With "all screens" on and then unplugging down to a single screen: the whole row must still be there, otherwise there is no way to switch back to "Follow mouse".
    func testMenuVisibleWithSingleScreenWhileAllScreens() {
        let presentation = TaskbarScreenMenuPresentation(
            placement: .allScreens,
            connectedScreens: [(uuid: "A", title: "内建显示器")]
        )
        XCTAssertFalse(presentation.isHidden)
    }

    /// The case-4 row is always present (shipped with milestone 2 on 2026-09-02) and is checked only when selected.
    func testPerDisplayRowAlwaysPresentCheckedOnlyWhenSelected() {
        let plain = TaskbarScreenMenuPresentation(placement: .followMouse, connectedScreens: screens)
        XCTAssertEqual(plain.items.last?.selection, .allScreensPerDisplay)
        XCTAssertEqual(plain.items.filter(\.isChecked).map(\.selection), [.followMouse])
        let selected = TaskbarScreenMenuPresentation(placement: .allScreensPerDisplay, connectedScreens: screens)
        XCTAssertEqual(selected.items.filter(\.isChecked).map(\.selection), [.allScreensPerDisplay])
    }

    /// Two groups with dimmed headers: single-screen mode (hover-to-switch / each screen / a disconnected pinned row), then multi-screen mode (cases 3 and 4).
    func testRowsSplitIntoTwoTitledGroups() {
        typealias Row = TaskbarScreenMenuPresentation.Row
        let presentation = TaskbarScreenMenuPresentation(
            placement: .pinned(PinnedScreenSelection(uuid: "Z", name: "Dell U2720Q")),
            connectedScreens: screens
        )
        let kinds: [String] = presentation.rows.map { row in
            switch row {
            case .header: return "header"
            case .separator: return "separator"
            case .option(let item): return item.selection.token
            }
        }
        XCTAssertEqual(kinds, [
            "header", "followMouse", "screen:A", "screen:B", "screen:Z",
            "separator",
            "header", "allScreens", "allScreensPerDisplay",
        ])
        let headers = presentation.rows.compactMap { row -> String? in
            if case let .header(title) = row { return title }
            return nil
        }
        XCTAssertEqual(headers.count, 2)
        XCTAssertNotEqual(headers[0], headers[1])
        XCTAssertFalse(headers.contains { $0.isEmpty })
    }

    func testSelectionTokenRoundTrips() {
        typealias Selection = TaskbarScreenMenuPresentation.Selection
        let all: [Selection] = [.followMouse, .allScreens, .allScreensPerDisplay, .screen(uuid: "37D8832A-2D66-02CA-B9F7-8F30A301B230")]
        for selection in all {
            XCTAssertEqual(Selection(token: selection.token), selection)
        }
        XCTAssertNil(Selection(token: "screen:"))
        XCTAssertNil(Selection(token: "garbage"))
        XCTAssertEqual(Selection.screen(uuid: "A").screenUUID, "A")
        XCTAssertNil(Selection.allScreens.screenUUID)
    }
}
