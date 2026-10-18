import XCTest

final class AccessoryWindowPresentationTests: XCTestCase {
    private let primary = CGRect(x: 0, y: 0, width: 1440, height: 860)

    func testFirstPresentationCentersOnPreferredScreen() {
        let secondary = CGRect(x: -1200, y: 0, width: 1200, height: 800)
        let result = AccessoryWindowPresentation.repairedFrame(
            windowFrame: CGRect(x: 0, y: 0, width: 520, height: 480),
            titlebarHeight: 28,
            visibleFrames: [primary, secondary],
            preferredVisibleFrame: secondary,
            isFirstPresentation: true
        )

        XCTAssertEqual(result, CGRect(x: -860, y: 160, width: 520, height: 480))
    }

    func testValidFrameIsUnchanged() {
        XCTAssertNil(AccessoryWindowPresentation.repairedFrame(
            windowFrame: CGRect(x: 200, y: 120, width: 520, height: 480),
            titlebarHeight: 28,
            visibleFrames: [primary],
            preferredVisibleFrame: primary,
            isFirstPresentation: false
        ))
    }

    func testUnreachableTitlebarIsClampedBackOnScreen() {
        let result = AccessoryWindowPresentation.repairedFrame(
            windowFrame: CGRect(x: 200, y: 850, width: 520, height: 480),
            titlebarHeight: 28,
            visibleFrames: [primary],
            preferredVisibleFrame: primary,
            isFirstPresentation: false
        )

        XCTAssertEqual(result, CGRect(x: 200, y: 380, width: 520, height: 480))
    }

    func testCompletelyOffscreenFrameUsesPreferredScreen() {
        let result = AccessoryWindowPresentation.repairedFrame(
            windowFrame: CGRect(x: 4000, y: -2000, width: 520, height: 480),
            titlebarHeight: 28,
            visibleFrames: [primary],
            preferredVisibleFrame: primary,
            isFirstPresentation: false
        )

        XCTAssertEqual(result, CGRect(x: 920, y: 0, width: 520, height: 480))
    }

    func testOversizedFrameShrinksToVisibleFrame() {
        let result = AccessoryWindowPresentation.repairedFrame(
            windowFrame: CGRect(x: -100, y: -100, width: 1800, height: 1000),
            titlebarHeight: 28,
            visibleFrames: [primary],
            preferredVisibleFrame: primary,
            isFirstPresentation: false
        )

        XCTAssertEqual(result, primary)
    }

    func testExistingNegativeCoordinateScreenWinsByIntersection() {
        let secondary = CGRect(x: -1200, y: 0, width: 1200, height: 800)
        XCTAssertNil(AccessoryWindowPresentation.repairedFrame(
            windowFrame: CGRect(x: -900, y: 120, width: 520, height: 480),
            titlebarHeight: 28,
            visibleFrames: [primary, secondary],
            preferredVisibleFrame: primary,
            isFirstPresentation: false
        ))
    }
}
