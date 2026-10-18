import XCTest
@testable import NeoBar

/// Pop-up criteria for the first-run welcome guide.
///
/// What really needs locking down here is the point that **"couldn't read" and "read false" must be handled separately**:
/// the former is a transient fault, ask again next time, while only the latter means "should pop up". Confusing them goes in different directions and costs differently --
/// mixing it into "pop up" harasses the user when the read fails, and mixing it into "mark as seen" lets one CFPreferences hiccup
/// swallow the guide permanently, which the user has no way to notice.
final class WelcomeGuideDecisionTests: XCTestCase {
    func testPresentsWhenDockIsVisibleAndNothingHasBeenSeen() {
        XCTAssertEqual(
            WelcomeGuideDecision.evaluate(
                hasSeenWelcome: false,
                canWriteDockPreferences: true,
                dockAutohideEnabled: false
            ),
            .present
        )
    }

    func testAlreadySeenNeverPresentsAgain() {
        // Seen is seen; none of the later conditions should overturn it -- including the user changing the Dock back to always-shown after seeing it.
        for dockAutohide in [true, false, nil] as [Bool?] {
            XCTAssertEqual(
                WelcomeGuideDecision.evaluate(
                    hasSeenWelcome: true,
                    canWriteDockPreferences: true,
                    dockAutohideEnabled: dockAutohide
                ),
                .skipAndMarkSeen,
                "dockAutohideEnabled = \(String(describing: dockAutohide))"
            )
        }
    }

    func testDockAlreadyHiddenSkipsAndMarksSeen() {
        // The guide no longer makes sense. Mark it, so that if the user deliberately sets the Dock back to always-shown some day,
        // they aren't suddenly blocked by a "first-run guide".
        XCTAssertEqual(
            WelcomeGuideDecision.evaluate(
                hasSeenWelcome: false,
                canWriteDockPreferences: true,
                dockAutohideEnabled: true
            ),
            .skipAndMarkSeen
        )
    }

    func testSandboxedSkipsAndMarksSeen() {
        // The sandbox can't write Dock preferences; a button that is bound to fail is worse than none.
        // The sandbox is a permanent property, so dispose of the guide on this machine directly.
        XCTAssertEqual(
            WelcomeGuideDecision.evaluate(
                hasSeenWelcome: false,
                canWriteDockPreferences: false,
                dockAutohideEnabled: false
            ),
            .skipAndMarkSeen
        )
    }

    /// **This case is the reason the whole type exists.**
    ///
    /// `currentAutohideState()` returning nil means "couldn't read this time", not "the Dock isn't auto-hiding".
    /// In that case we can neither pop up (no basis) nor, even less, mark as seen -- that would let one transient read failure swallow the guide permanently.
    func testUnreadableDockStateSkipsWithoutMarking() {
        XCTAssertEqual(
            WelcomeGuideDecision.evaluate(
                hasSeenWelcome: false,
                canWriteDockPreferences: true,
                dockAutohideEnabled: nil
            ),
            .skipWithoutMarking
        )
    }

    /// Unreadable + sandbox: the sandbox rule takes priority, because it is permanent and there's no point in a wasted read on every launch.
    func testSandboxWinsOverUnreadableState() {
        XCTAssertEqual(
            WelcomeGuideDecision.evaluate(
                hasSeenWelcome: false,
                canWriteDockPreferences: false,
                dockAutohideEnabled: nil
            ),
            .skipAndMarkSeen
        )
    }

    // MARK: - Checkboxes -> which keys to write

    /// This step most easily crosses the two minimize options, and tests that only construct `NativeDockRecommendations` can't catch it,
    /// so all four combinations are asserted field by field.
    func testFullSelectionMapsToAllThreeWrites() {
        let recommendations = WelcomeGuideSelection.recommended.recommendations(hideDelay: 999)
        XCTAssertEqual(recommendations.autoHideDelay, 999)
        XCTAssertTrue(recommendations.minimizeEffectScale)
        XCTAssertTrue(recommendations.minimizeIntoAppIcon)
        XCTAssertFalse(recommendations.isEmpty)
    }

    func testHideOnlySelectionLeavesMinimizeKeysUntouched() {
        let recommendations = WelcomeGuideSelection(
            hidesDock: true,
            usesScaleMinimizeEffect: false,
            minimizesIntoAppIcon: false
        ).recommendations(hideDelay: 999)
        XCTAssertEqual(recommendations.autoHideDelay, 999)
        XCTAssertFalse(recommendations.minimizeEffectScale)
        XCTAssertFalse(recommendations.minimizeIntoAppIcon)
    }

    /// Not ticking hide = **not touching** autohide at all (nil), not "write a default value".
    func testMinimizeOnlySelectionCarriesNoAutoHideDelay() {
        let recommendations = WelcomeGuideSelection(
            hidesDock: false,
            usesScaleMinimizeEffect: true,
            minimizesIntoAppIcon: true
        ).recommendations(hideDelay: 999)
        XCTAssertNil(recommendations.autoHideDelay)
        XCTAssertTrue(recommendations.minimizeEffectScale)
        XCTAssertTrue(recommendations.minimizeIntoAppIcon)
    }

    /// The two minimize options are independent of each other; don't cross them.
    func testEachMinimizeOptionMapsToItsOwnField() {
        let scaleOnly = WelcomeGuideSelection(
            hidesDock: false,
            usesScaleMinimizeEffect: true,
            minimizesIntoAppIcon: false
        ).recommendations(hideDelay: 999)
        XCTAssertTrue(scaleOnly.minimizeEffectScale)
        XCTAssertFalse(scaleOnly.minimizeIntoAppIcon)

        let iconOnly = WelcomeGuideSelection(
            hidesDock: false,
            usesScaleMinimizeEffect: false,
            minimizesIntoAppIcon: true
        ).recommendations(hideDelay: 999)
        XCTAssertFalse(iconOnly.minimizeEffectScale)
        XCTAssertTrue(iconOnly.minimizeIntoAppIcon)
    }

    func testEmptySelectionMapsToEmptyRecommendations() {
        let selection = WelcomeGuideSelection(
            hidesDock: false,
            usesScaleMinimizeEffect: false,
            minimizesIntoAppIcon: false
        )
        XCTAssertTrue(selection.isEmpty)
        XCTAssertTrue(selection.recommendations(hideDelay: 999).isEmpty)
    }
}
