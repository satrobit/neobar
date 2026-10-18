import Carbon.HIToolbox
import XCTest

final class HotKeyShortcutValidationTests: XCTestCase {
    private func validate(_ keyCode: Int, _ modifiers: UInt32) -> HotKeyShortcutRejection? {
        HotKeyShortcutValidation.validate(keyCode: UInt32(keyCode), carbonModifiers: modifiers)
    }

    func testAcceptsCommonCombinations() {
        XCTAssertNil(validate(kVK_ANSI_D, UInt32(optionKey | shiftKey | cmdKey)), "默认 ⌥⇧⌘D 必须可用")
        XCTAssertNil(validate(kVK_ANSI_K, UInt32(controlKey | cmdKey)))
        XCTAssertNil(validate(kVK_F5, UInt32(cmdKey)))
        XCTAssertNil(validate(kVK_ANSI_F, UInt32(controlKey | optionKey | cmdKey)), "⌃⌥ 带上 ⌘ 是安全组合，只拒不带 ⌘ 的")
    }

    func testRejectsMissingPrimaryModifier() {
        XCTAssertEqual(validate(kVK_ANSI_A, 0), .missingPrimaryModifier)
        XCTAssertEqual(validate(kVK_ANSI_A, UInt32(shiftKey)), .missingPrimaryModifier, "只有 ⇧ 不算主修饰键")
    }

    func testRejectsUnreliableOptionOnlyModifiers() {
        XCTAssertEqual(validate(kVK_ANSI_A, UInt32(optionKey)), .unreliableModifiers)
        XCTAssertEqual(validate(kVK_ANSI_A, UInt32(optionKey | shiftKey)), .unreliableModifiers)
    }

    func testRejectsSystemReservedCombinations() {
        XCTAssertEqual(validate(kVK_ANSI_F, UInt32(controlKey | optionKey)), .reservedBySystem, "⌃⌥ 不带 ⌘ 是旁白的修饰键域")
        XCTAssertEqual(validate(kVK_ANSI_D, UInt32(optionKey | cmdKey)), .reservedBySystem, "⌥⌘D 归 macOS（系统 Dock 显隐）")
        XCTAssertNil(validate(kVK_ANSI_E, UInt32(optionKey | cmdKey)), "⌥⌘ 只有配 D 键才被拒")
    }

    func testRejectsForbiddenKeysRegardlessOfModifiers() {
        XCTAssertEqual(validate(kVK_Escape, UInt32(cmdKey)), .forbiddenKey)
        XCTAssertEqual(validate(kVK_Delete, UInt32(optionKey | cmdKey)), .forbiddenKey)
        XCTAssertEqual(validate(kVK_ForwardDelete, UInt32(controlKey)), .forbiddenKey)
    }
}
