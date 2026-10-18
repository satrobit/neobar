import XCTest

final class StripDisplayFilterTests: XCTestCase {
    private let onA = StripDisplayFilter(scope: "A", connectedUUIDs: ["A", "B"], primaryUUID: "A")
    private let onB = StripDisplayFilter(scope: "B", connectedUUIDs: ["A", "B"], primaryUUID: "A")

    func testLaunchersShowEverywhere() {
        XCTAssertTrue(onA.shows(.launcher))
        XCTAssertTrue(onB.shows(.launcher))
        XCTAssertTrue(StripDisplayFilter.unfiltered.shows(.launcher))
    }

    func testNilScopeShowsEverything() {
        let filter = StripDisplayFilter(scope: nil, connectedUUIDs: ["A", "B"], primaryUUID: "A")
        XCTAssertTrue(filter.shows(.window(displayUUID: "B")))
        XCTAssertTrue(filter.shows(.window(displayUUID: nil)))
        XCTAssertTrue(filter.shows(.runningWithoutWindow(displayUUID: nil)))
        XCTAssertTrue(StripDisplayFilter.unfiltered.shows(.window(displayUUID: "Z")))
    }

    func testWindowShowsOnlyOnItsOwnDisplay() {
        XCTAssertTrue(onA.shows(.window(displayUUID: "A")))
        XCTAssertFalse(onB.shows(.window(displayUUID: "A")))
        XCTAssertTrue(onB.shows(.window(displayUUID: "B")))
        XCTAssertFalse(onA.shows(.window(displayUUID: "B")))
    }

    /// Has a running dot but no window (app-level fallback card / running kept placeholder) -> on only one strip: the display where the window was last, falling back to the main display if unreadable.
    func testRunningWithoutWindowShowsOnItsHomeElsePrimary() {
        XCTAssertTrue(onA.shows(.runningWithoutWindow(displayUUID: nil)))
        XCTAssertFalse(onB.shows(.runningWithoutWindow(displayUUID: nil)))
        XCTAssertFalse(onA.shows(.runningWithoutWindow(displayUUID: "B")))
        XCTAssertTrue(onB.shows(.runningWithoutWindow(displayUUID: "B")))
        XCTAssertTrue(onA.shows(.runningWithoutWindow(displayUUID: "GONE")))
    }

    /// Position unreadable -> falls on the main display (the menu-bar display); other displays don't draw it.
    func testUnknownDisplayFallsToPrimary() {
        XCTAssertTrue(onA.shows(.window(displayUUID: nil)))
        XCTAssertFalse(onB.shows(.window(displayUUID: nil)))
    }

    /// The ownership key points to an unplugged display -> likewise falls on the main display.
    func testDisconnectedDisplayFallsToPrimary() {
        XCTAssertTrue(onA.shows(.window(displayUUID: "GONE")))
        XCTAssertFalse(onB.shows(.window(displayUUID: "GONE")))
    }

    /// With no main display (empty display table), unknown-ownership / windowless icons are drawn nowhere -- accepted: this only happens when there are no displays at all.
    func testNoPrimaryHidesUnknownEverywhere() {
        let filter = StripDisplayFilter(scope: "A", connectedUUIDs: [], primaryUUID: nil)
        XCTAssertFalse(filter.shows(.window(displayUUID: nil)))
        XCTAssertFalse(filter.shows(.window(displayUUID: "A")))
        XCTAssertFalse(filter.shows(.runningWithoutWindow(displayUUID: nil)))
        XCTAssertTrue(filter.shows(.launcher))
    }
}
