import XCTest

final class FullscreenClassificationTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)

    // LaunchOS's full-screen launcher (probed 2026-10-16): role AXWindow / subrole AXSystemDialog, frame equal
    // to the whole screen, CG layer 1000, no AXFullScreen flag. The frame fallback hides the bar for it, and
    // closing it fires no activation change — `OverlayWindowWatch` below is what ends that hide.
    func testScreenSizedOverlayWithoutAXFlagIsFullscreen() {
        XCTAssertEqual(FullscreenWindowClassifier.classify(
            role: "AXWindow", isAXFullscreen: false, windowFrame: screen, windowLayer: 1000, screenCGFrame: screen),
            .fullscreen)
    }

    func testOverlayWatchKeepsWaitingWhileTheWindowStillCoversTheScreen() {
        XCTAssertFalse(OverlayWindowWatch.shouldRecheck(isOnscreen: true, bounds: screen, screenCGFrame: screen))
        let nudged = screen.insetBy(dx: 2, dy: 2)
        XCTAssertFalse(OverlayWindowWatch.shouldRecheck(isOnscreen: true, bounds: nudged, screenCGFrame: screen))
    }

    func testOverlayWatchRechecksWhenTheWindowIsGoneOrOrderedOut() {
        XCTAssertTrue(OverlayWindowWatch.shouldRecheck(isOnscreen: nil, bounds: nil, screenCGFrame: screen))
        XCTAssertTrue(OverlayWindowWatch.shouldRecheck(isOnscreen: false, bounds: screen, screenCGFrame: screen))
        XCTAssertTrue(OverlayWindowWatch.shouldRecheck(isOnscreen: true, bounds: nil, screenCGFrame: screen))
    }

    func testOverlayWatchRechecksWhenTheWindowStopsCoveringTheScreen() {
        let shrunk = CGRect(x: 100, y: 80, width: 1200, height: 800)
        XCTAssertTrue(OverlayWindowWatch.shouldRecheck(isOnscreen: true, bounds: shrunk, screenCGFrame: screen))
        let moved = screen.offsetBy(dx: 1512, dy: 0)
        XCTAssertTrue(OverlayWindowWatch.shouldRecheck(isOnscreen: true, bounds: moved, screenCGFrame: screen))
    }

    // Regression: the Finder desktop pseudo-window (role=AXScrollArea, frame exactly equal to the full screen) must not be judged fullscreen
    func testDesktopPseudoWindowWithExactScreenFrameIsNotFullscreen() {
        XCTAssertFalse(FullscreenWindowClassifier.isFullscreen(
            role: "AXScrollArea", isAXFullscreen: false, windowFrame: screen, windowLayer: 0, screenCGFrame: screen))
    }

    func testUnreadableRoleIsNotFullscreenEvenWithExactScreenFrame() {
        XCTAssertFalse(FullscreenWindowClassifier.isFullscreen(
            role: nil, isAXFullscreen: false, windowFrame: screen, windowLayer: 0, screenCGFrame: screen))
    }

    func testUnreadableRoleIsNotFullscreenEvenWithAXFullscreenFlag() {
        XCTAssertFalse(FullscreenWindowClassifier.isFullscreen(
            role: nil, isAXFullscreen: true, windowFrame: nil, windowLayer: 0, screenCGFrame: screen))
    }

    func testNativeFullscreenWindowIsFullscreen() {
        XCTAssertTrue(FullscreenWindowClassifier.isFullscreen(
            role: "AXWindow", isAXFullscreen: true, windowFrame: screen, windowLayer: 0, screenCGFrame: screen))
    }

    func testNativeFullscreenWithUnreadableFrameIsFullscreen() {
        XCTAssertTrue(FullscreenWindowClassifier.isFullscreen(
            role: "AXWindow", isAXFullscreen: true, windowFrame: nil, windowLayer: 0, screenCGFrame: screen))
    }

    func testNativeFullscreenOnAnotherScreenIsNotFullscreenHere() {
        let otherScreen = CGRect(x: 1512, y: -200, width: 1920, height: 1080)
        XCTAssertFalse(FullscreenWindowClassifier.isFullscreen(
            role: "AXWindow", isAXFullscreen: true, windowFrame: otherScreen, windowLayer: 0, screenCGFrame: screen))
    }

    // Full-screen tiling (true split view): AXFullScreen=true but only half the screen wide (the shape measured on 2026-08-30, scaled proportionally to the test screen).
    // What is fixed is exactly the old width clause (width > screen×0.7) wrongly rejecting it, with the strip covering the split-view content.
    func testSplitViewTileOnThisScreenIsFullscreen() {
        let leftTile = CGRect(x: 0, y: 20, width: 754, height: 962)
        XCTAssertTrue(FullscreenWindowClassifier.isFullscreen(
            role: "AXWindow", isAXFullscreen: true, windowFrame: leftTile, windowLayer: 0, screenCGFrame: screen))
        let rightTile = CGRect(x: 756, y: 20, width: 756, height: 962)
        XCTAssertTrue(FullscreenWindowClassifier.isFullscreen(
            role: "AXWindow", isAXFullscreen: true, windowFrame: rightTile, windowLayer: 0, screenCGFrame: screen))
    }

    // The successor of the multi-screen guardrail: a window whose body is on the neighboring screen and only grazes a few dozen points into this one must not be judged fullscreen on this screen.
    // The old width clause incidentally blocked this kind of window; after switching to area-based ownership, this test case pins that behavior.
    func testFullscreenWindowMostlyOnNeighborScreenIsNotFullscreenHere() {
        let mostlyElsewhere = CGRect(x: 1480, y: -200, width: 1920, height: 1080)
        XCTAssertFalse(FullscreenWindowClassifier.isFullscreen(
            role: "AXWindow", isAXFullscreen: true, windowFrame: mostlyElsewhere, windowLayer: 0, screenCGFrame: screen))
    }

    // Desktop tiling (macOS 26's default "split screen"): half width but AXFullScreen=false, goes through the frame fallback, and must not be judged fullscreen:
    // it is an ordinary window on an ordinary desktop, and the strip shows as usual (the occlusion of that half belongs to the avoidance topic, not to hiding).
    func testDesktopTiledHalfWindowIsNotFullscreen() {
        let tiled = CGRect(x: 756, y: 20, width: 756, height: 962)
        XCTAssertFalse(FullscreenWindowClassifier.isFullscreen(
            role: "AXWindow", isAXFullscreen: false, windowFrame: tiled, windowLayer: 0, screenCGFrame: screen))
    }

    // Borderless fullscreen without an AXFullScreen flag (games/HTML5) still goes through the frame≈full-screen fallback
    func testBorderlessScreenSizedWindowIsFullscreen() {
        let nearScreen = screen.insetBy(dx: 2, dy: 2)
        XCTAssertTrue(FullscreenWindowClassifier.isFullscreen(
            role: "AXWindow", isAXFullscreen: false, windowFrame: nearScreen, windowLayer: 0, screenCGFrame: screen))
    }

    // Regression (feedback 652f4dc8): an accessory app's screen-sized window at desktop level takes
    // focus when the desktop is clicked; the frame fallback must not read it as fullscreen.
    func testScreenSizedWindowBelowNormalLayerIsNotFullscreen() {
        let desktopIconLayer = Int(CGWindowLevelForKey(.desktopIconWindow)) + 1
        XCTAssertFalse(FullscreenWindowClassifier.isFullscreen(
            role: "AXWindow", isAXFullscreen: false, windowFrame: screen,
            windowLayer: desktopIconLayer, screenCGFrame: screen))
        XCTAssertEqual(
            FullscreenWindowClassifier.classify(
                role: "AXWindow", isAXFullscreen: false, windowFrame: screen,
                windowLayer: -1, screenCGFrame: screen),
            .windowed)
    }

    // An unreadable layer keeps the old verdict, and games above the normal layer still hide the bar.
    func testScreenSizedWindowWithUnknownOrRaisedLayerIsFullscreen() {
        XCTAssertTrue(FullscreenWindowClassifier.isFullscreen(
            role: "AXWindow", isAXFullscreen: false, windowFrame: screen,
            windowLayer: nil, screenCGFrame: screen))
        XCTAssertTrue(FullscreenWindowClassifier.isFullscreen(
            role: "AXWindow", isAXFullscreen: false, windowFrame: screen,
            windowLayer: Int(CGWindowLevelForKey(.screenSaverWindow)), screenCGFrame: screen))
    }

    // The layer guard belongs to the frame fallback only: a native fullscreen flag is never overruled.
    func testNativeFullscreenFlagIgnoresLayer() {
        XCTAssertTrue(FullscreenWindowClassifier.isFullscreen(
            role: "AXWindow", isAXFullscreen: true, windowFrame: screen,
            windowLayer: -1, screenCGFrame: screen))
    }

    func testOrdinaryWindowIsNotFullscreen() {
        let partial = CGRect(x: 253, y: 125, width: 1127, height: 689)
        XCTAssertFalse(FullscreenWindowClassifier.isFullscreen(
            role: "AXWindow", isAXFullscreen: false, windowFrame: partial, windowLayer: 0, screenCGFrame: screen))
    }

    func testRealWindowWithUnreadableFrameIsNotFullscreen() {
        XCTAssertFalse(FullscreenWindowClassifier.isFullscreen(
            role: "AXWindow", isAXFullscreen: false, windowFrame: nil, windowLayer: 0, screenCGFrame: screen))
    }

    // MARK: - Membership of "show on all desktops" (issue #19)

    func testMembershipIsHealthyWhenWindowCoversEveryDesktop() {
        XCTAssertEqual(
            AllSpacesMembership.missingSpaceIDs(windowSpaceIDs: [1, 3, 1020], desktopSpaceIDs: [1, 3, 1020]),
            [])
    }

    // This is the symptom of issue #19: after exiting fullscreen, only the current desktop is left
    func testMembershipCollapsedToCurrentDesktopIsReported() {
        XCTAssertEqual(
            AllSpacesMembership.missingSpaceIDs(windowSpaceIDs: [1], desktopSpaceIDs: [1, 3, 1020]),
            [3, 1020])
    }

    // A window attached to one extra fullscreen space is not a problem (that is exactly how it looks at the instant of entering fullscreen)
    func testExtraFullscreenSpaceMembershipIsNotAProblem() {
        XCTAssertEqual(
            AllSpacesMembership.missingSpaceIDs(windowSpaceIDs: [1, 3, 1013], desktopSpaceIDs: [1, 3]),
            [])
    }

    // A single desktop can't have a "lost desktop"; never trigger repair
    func testSingleDesktopNeverReportsMissing() {
        XCTAssertEqual(
            AllSpacesMembership.missingSpaceIDs(windowSpaceIDs: [], desktopSpaceIDs: [1]),
            [])
    }

    func testEmptyDesktopListNeverReportsMissing() {
        XCTAssertEqual(
            AllSpacesMembership.missingSpaceIDs(windowSpaceIDs: [1], desktopSpaceIDs: []),
            [])
    }

    // A single repair isn't guaranteed to succeed, so retrying must be allowed, but not endlessly
    func testRepairRetriesAreBounded() {
        XCTAssertTrue(AllSpacesMembership.shouldRetry(attempt: 0))
        XCTAssertTrue(AllSpacesMembership.shouldRetry(attempt: 2))
        XCTAssertFalse(AllSpacesMembership.shouldRetry(attempt: 3))
        XCTAssertFalse(AllSpacesMembership.shouldRetry(attempt: 4))
    }
}
