import XCTest

/// The only reason this set of cases exists: the owner reported on 2026-08-20 "dragging an icon from the drawer onto the taskbar gives the whole taskbar a black border".
/// The cause was the drop highlight **replacing the glass specular rim wholesale**. The first case below locks exactly that.
final class DockPanelRimPlanTests: XCTestCase {

    /// The highlight **must not** remove the glass rim again -- the highlight is layered on top.
    func testGlassRimSurvivesHighlight() {
        XCTAssertTrue(DockPanelRimPlan.glassRimVisible(usesLiquidGlass: true, usesSystemVariant: false))
        XCTAssertFalse(DockPanelRimPlan.glassRimVisible(usesLiquidGlass: false, usesSystemVariant: false))
        XCTAssertFalse(DockPanelRimPlan.glassRimVisible(usesLiquidGlass: true, usesSystemVariant: true),
                       "the Dock material draws its own rim")
        XCTAssertFalse(DockPanelRimPlan.glassRimVisible(usesLiquidGlass: false, usesSystemVariant: true))
    }

    /// Glass path: the usual rim belongs to `DockGlassRim`, and the theme stroke width must be 0
    ///(not drawing an invisible line -- 0 width is equivalent to staying out of the view tree, same rule as `.blur(radius: 0)`).
    func testGlassPathDrawsThemeStrokeOnlyWhenHighlighted() {
        XCTAssertEqual(
            DockPanelRimPlan.themeStrokeWidth(usesLiquidGlass: true, highlighted: false, lineWidth: 0.5),
            0
        )
        XCTAssertEqual(
            DockPanelRimPlan.themeStrokeWidth(usesLiquidGlass: true, highlighted: true, lineWidth: 1),
            1
        )
    }

    /// Frosted-glass path (macOS 12-25): the theme stroke **is** that rim, and both the usual state and the highlight must draw it.
    func testFrostedPathAlwaysDrawsTheThemeStroke() {
        XCTAssertEqual(
            DockPanelRimPlan.themeStrokeWidth(usesLiquidGlass: false, highlighted: false, lineWidth: 0.5),
            0.5
        )
        XCTAssertEqual(
            DockPanelRimPlan.themeStrokeWidth(usesLiquidGlass: false, highlighted: true, lineWidth: 1),
            1
        )
    }
}
