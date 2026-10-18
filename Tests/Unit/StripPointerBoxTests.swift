import XCTest
@testable import NeoBar

/// Task strip enter / exit hysteresis box (`StripPointerBox`): test both sets of criteria; pass through here before changing any number.
final class StripPointerBoxTests: XCTestCase {
    private let strip = CGRect(x: 100, y: 0, width: 600, height: 54)
    private let reach: CGFloat = 62

    private func box(_ x: CGFloat, _ y: CGFloat, _ profile: StripPointerBox.Profile) -> StripPointerBox {
        StripPointerBox.classify(pointer: CGPoint(x: x, y: y), stripRect: strip, rightReach: reach, profile: profile)
    }

    func testInsideIsEnterAndNotOutInBothProfiles() {
        XCTAssertEqual(box(300, 20, .drawerConversion), StripPointerBox(enter: true, clearlyOut: false))
        XCTAssertEqual(box(300, 20, .stripPresence), StripPointerBox(enter: true, clearlyOut: false))
    }

    /// Drawer-promotion criteria: enter 16 / exit 40 above, with a hysteresis band in between.
    func testDrawerConversionTopBand() {
        XCTAssertTrue(box(300, 54 + 15, .drawerConversion).enter)
        XCTAssertEqual(box(300, 54 + 30, .drawerConversion), StripPointerBox(enter: false, clearlyOut: false))
        XCTAssertTrue(box(300, 54 + 41, .drawerConversion).clearlyOut)
    }

    /// Close-on-drag-out criteria: enter 0 / exit 6 above; the pointer counts as gone as soon as it leaves the strip top, aligned to a native Dock recording (owner 2026-09-03).
    func testStripPresenceTopBandMatchesTheNativeDock() {
        XCTAssertTrue(box(300, 54, .stripPresence).enter)
        XCTAssertEqual(box(300, 54 + 3, .stripPresence), StripPointerBox(enter: false, clearlyOut: false))
        XCTAssertTrue(box(300, 54 + 7, .stripPresence).clearlyOut)
        XCTAssertFalse(box(300, 54 + 7, .drawerConversion).clearlyOut, "抽屉那套在这个高度还没出")
    }

    /// Below and to the left/right, the two sets of criteria are the same.
    func testBottomAndSidesAreShared() {
        for profile in [StripPointerBox.Profile.drawerConversion, .stripPresence] {
            XCTAssertEqual(box(300, -16, profile), StripPointerBox(enter: false, clearlyOut: false))
            XCTAssertTrue(box(300, -25, profile).clearlyOut)
            XCTAssertEqual(box(100 - 16, 20, profile), StripPointerBox(enter: false, clearlyOut: false))
            XCTAssertTrue(box(100 - 25, 20, profile).clearlyOut)
        }
    }

    /// A capsule on the right counts as on the strip: a cursor pressed on the capsule is still enter, and only 16pt beyond the capsule to the right counts as exit.
    func testCapsuleCountsAsOnTheStrip() {
        for profile in [StripPointerBox.Profile.drawerConversion, .stripPresence] {
            XCTAssertTrue(box(700 + reach - 1, 20, profile).enter)
            XCTAssertEqual(box(700 + reach + 10, 20, profile), StripPointerBox(enter: false, clearlyOut: false))
            XCTAssertTrue(box(700 + reach + 17, 20, profile).clearlyOut)
        }
    }

    func testEnterAndOutAreNeverBothTrue() {
        for profile in [StripPointerBox.Profile.drawerConversion, .stripPresence] {
            for x in stride(from: 0, through: 900, by: 7) {
                for y in stride(from: -60, through: 120, by: 5) {
                    let b = box(CGFloat(x), CGFloat(y), profile)
                    XCTAssertFalse(b.enter && b.clearlyOut, "(\(x), \(y)) \(profile)")
                }
            }
        }
    }
}
