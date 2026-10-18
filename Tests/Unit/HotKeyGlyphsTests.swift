import Carbon.HIToolbox
import XCTest

final class HotKeyGlyphsTests: XCTestCase {
    func testModifierOrderIsControlOptionShiftCommand() {
        XCTAssertEqual(
            HotKeyGlyphs.modifierString(carbonModifiers: UInt32(cmdKey | shiftKey | optionKey | controlKey)),
            "⌃⌥⇧⌘"
        )
        XCTAssertEqual(HotKeyGlyphs.modifierString(carbonModifiers: UInt32(cmdKey | optionKey)), "⌥⌘")
        XCTAssertEqual(HotKeyGlyphs.modifierString(carbonModifiers: 0), "")
    }

    func testSpecialKeysUseTheTable() {
        XCTAssertEqual(HotKeyGlyphs.keyString(keyCode: UInt32(kVK_LeftArrow), charactersIgnoringModifiers: nil), "←")
        XCTAssertEqual(HotKeyGlyphs.keyString(keyCode: UInt32(kVK_Space), charactersIgnoringModifiers: " "), "Space")
        XCTAssertEqual(HotKeyGlyphs.keyString(keyCode: UInt32(kVK_F5), charactersIgnoringModifiers: "\u{F708}"), "F5")
        // A table hit takes priority over "control characters are not recognized": Return's character is \r, but the table has it.
        XCTAssertEqual(HotKeyGlyphs.keyString(keyCode: UInt32(kVK_Return), charactersIgnoringModifiers: "\r"), "↩")
    }

    func testPrintableCharactersUppercase() {
        XCTAssertEqual(HotKeyGlyphs.keyString(keyCode: UInt32(kVK_ANSI_D), charactersIgnoringModifiers: "d"), "D")
        XCTAssertEqual(HotKeyGlyphs.keyString(keyCode: UInt32(kVK_ANSI_7), charactersIgnoringModifiers: "7"), "7")
    }

    func testUnrepresentableKeysReturnNil() {
        XCTAssertNil(HotKeyGlyphs.keyString(keyCode: 9999, charactersIgnoringModifiers: nil))
        XCTAssertNil(HotKeyGlyphs.keyString(keyCode: 9999, charactersIgnoringModifiers: ""))
        XCTAssertNil(
            HotKeyGlyphs.keyString(keyCode: UInt32(kVK_F13), charactersIgnoringModifiers: "\u{F710}"),
            "私有区功能键字符、表里又没有 → 不认"
        )
    }

    func testDisplayComposesDefaultShortcut() {
        XCTAssertEqual(
            HotKeyGlyphs.display(
                keyCode: UInt32(kVK_ANSI_D),
                carbonModifiers: UInt32(optionKey | shiftKey | cmdKey),
                charactersIgnoringModifiers: "d"
            ),
            "⌥⇧⌘D"
        )
        XCTAssertNil(HotKeyGlyphs.display(keyCode: 9999, carbonModifiers: UInt32(cmdKey), charactersIgnoringModifiers: nil))
    }
}
