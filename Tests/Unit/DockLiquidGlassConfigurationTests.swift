import XCTest
@testable import NeoBar

final class DockLiquidGlassConfigurationTests: XCTestCase {
    /// **The default is now on** (owner 2026-08-17 promoted the glass look to official).
    ///
    /// This test used to be called "default keeps the accepted frosted-glass path", locking the exploration-phase "default off + only `=1` turns it on".
    /// The point of that guard was "an unaccepted effect must not take effect by default" — once the look is accepted it should flip,
    /// otherwise a process auto-launched after a system restart (without the environment variable) would forever see the old look, which really happened.
    func testDefaultNowShipsTheAcceptedGlassLook() {
        let configuration = DockLiquidGlassConfiguration.resolve(environment: [:])

        XCTAssertTrue(configuration.isEnabled)
        XCTAssertEqual(configuration.clearTintOpacity, 0.4)
        XCTAssertEqual(configuration.whiteOverlayOpacity, 0)
        XCTAssertEqual(configuration.dimmingOpacity, 0)
        XCTAssertEqual(configuration.borderPeakOpacity, 0.75, "峰值档（↖↘ 两角）：实测调出来的，不是 78/171 算出来的")
        XCTAssertEqual(configuration.borderEdgeLevel, 0.5, "长边要的是 0.375，除以峰值 0.75")
        XCTAssertEqual(configuration.borderCornerCut, 0.92, "↗↙ 两角挖掉，原生那里亮线几乎没有")
        XCTAssertEqual(configuration.borderCornerSpread, 2.2, "角落调制半径 = 圆角半径的倍数")
        XCTAssertEqual(configuration.borderLineWidth, 0.5, "原生实测最外那道 1px @2x = 0.5pt")
        XCTAssertEqual(configuration.borderInnerOpacity, 0.21, "内圈半档：底板 84 打到原生的 120")
        XCTAssertEqual(configuration.backgroundMaterialOpacity, 0)
        XCTAssertEqual(configuration.windowBlurRadius, 0, "窗口级模糊不跟圆角走，会在四角糊出方块；通透度不靠它")
        XCTAssertEqual(configuration.contentInset, 4)
        XCTAssertEqual(configuration.backgroundPlateOpacity, 0.001)
        XCTAssertEqual(configuration.systemVariant, 3, "the accepted plate is the Dock's own glass material")
        XCTAssertEqual(
            configuration.renderPath(isGlassAPIAvailable: true, isCompositeAvailable: true),
            .layeredTaskbar
        )
        // The glass API does not exist on 12–25, so it still falls back to frosted glass — flipping the default does not affect older systems.
        XCTAssertEqual(
            configuration.renderPath(isGlassAPIAvailable: false, isCompositeAvailable: true),
            .visualEffectFallback
        )
    }

    /// The switch that turns glass off **only recognizes `0`**. Everything else (including unset and garbage) means on.
    func testOnlyZeroTurnsGlassOff() {
        XCTAssertFalse(resolve(["DOCK_LIQUID_GLASS": "0"]).isEnabled)
        XCTAssertFalse(resolve(["DOCK_LIQUID_GLASS": " 0 \n"]).isEnabled)

        for value in ["", "1", "true", "yes", "2"] {
            XCTAssertTrue(resolve(["DOCK_LIQUID_GLASS": value]).isEnabled)
        }
    }

    func testAcceptedDockRefractionIsEnabledWithoutLaunchOverrides() {
        let control = DebugSwitch.liquidGlassDockRefraction
        XCTAssertTrue(control.isEnabled(in: [:]))
        XCTAssertTrue(control.isEnabled(in: [control.rawValue: "1"]))
        XCTAssertFalse(control.isEnabled(in: [control.rawValue: "0"]))
    }

    func testAcceptedDiagonalHighlightIsEnabledWithoutLaunchOverrides() {
        let control = DebugSwitch.liquidGlassDiagonalHighlight
        XCTAssertTrue(control.isEnabled(in: [:]))
        XCTAssertTrue(control.isEnabled(in: [control.rawValue: "1"]))
        XCTAssertFalse(control.isEnabled(in: [control.rawValue: "0"]))
    }

    func testAcceptedHighlightStrengthIsEnabledWithoutLaunchOverrides() {
        let control = DebugSwitch.liquidGlassHighlightBoost
        XCTAssertTrue(control.isEnabled(in: [:]))
        XCTAssertTrue(control.isEnabled(in: [control.rawValue: "1"]))
        XCTAssertFalse(control.isEnabled(in: [control.rawValue: "0"]))
    }

    func testCompositeRequiresSystemAPIAndBackgroundPanel() {
        let configuration = resolve(["DOCK_LIQUID_GLASS": "1"])

        XCTAssertEqual(
            configuration.renderPath(isGlassAPIAvailable: true, isCompositeAvailable: true),
            .layeredTaskbar
        )
        XCTAssertEqual(
            configuration.renderPath(isGlassAPIAvailable: false, isCompositeAvailable: true),
            .visualEffectFallback
        )
        XCTAssertEqual(
            configuration.renderPath(isGlassAPIAvailable: true, isCompositeAvailable: false),
            .visualEffectFallback
        )
    }

    func testNumericOverridesAcceptBounds() {
        let configuration = resolve([
            "DOCK_LIQUID_GLASS_CLEAR_TINT": "0",
            "DOCK_LIQUID_GLASS_WHITE_OVERLAY": "1",
            "DOCK_LIQUID_GLASS_DIMMING": "1",
            "DOCK_LIQUID_GLASS_BORDER": "1",
            "DOCK_LIQUID_GLASS_BORDER_EDGE": "1",
            "DOCK_LIQUID_GLASS_BORDER_CUT": "0",
            "DOCK_LIQUID_GLASS_BORDER_SPREAD": "6",
            "DOCK_LIQUID_GLASS_BORDER_WIDTH": "4",
            "DOCK_LIQUID_GLASS_BORDER_INNER": "1",
            "DOCK_LIQUID_GLASS_BACKGROUND_OPACITY": "0",
            "DOCK_LIQUID_GLASS_WINDOW_BLUR": "64",
            "DOCK_LIQUID_GLASS_CONTENT_INSET": "12",
        ])

        XCTAssertEqual(configuration.clearTintOpacity, 0)
        XCTAssertEqual(configuration.whiteOverlayOpacity, 1)
        XCTAssertEqual(configuration.dimmingOpacity, 1)
        XCTAssertEqual(configuration.borderPeakOpacity, 1)
        XCTAssertEqual(configuration.borderEdgeLevel, 1)
        XCTAssertEqual(configuration.borderCornerCut, 0)
        XCTAssertEqual(configuration.borderCornerSpread, 6)
        XCTAssertEqual(configuration.borderLineWidth, 4)
        XCTAssertEqual(configuration.borderInnerOpacity, 1)
        XCTAssertEqual(configuration.backgroundMaterialOpacity, 0)
        XCTAssertEqual(configuration.windowBlurRadius, 64)
        XCTAssertEqual(configuration.contentInset, 12)
    }

    func testInvalidNumericOverridesUseCandidateDefaults() {
        let invalidValues = ["", "abc", "nan", "inf", "-1", "999"]
        for value in invalidValues {
            let configuration = resolve([
                "DOCK_LIQUID_GLASS_CLEAR_TINT": value,
                "DOCK_LIQUID_GLASS_WHITE_OVERLAY": value,
                "DOCK_LIQUID_GLASS_DIMMING": value,
                "DOCK_LIQUID_GLASS_BORDER": value,
                "DOCK_LIQUID_GLASS_BORDER_EDGE": value,
                "DOCK_LIQUID_GLASS_BORDER_CUT": value,
                "DOCK_LIQUID_GLASS_BORDER_SPREAD": value,
                "DOCK_LIQUID_GLASS_BORDER_WIDTH": value,
                "DOCK_LIQUID_GLASS_BORDER_INNER": value,
                "DOCK_LIQUID_GLASS_BACKGROUND_OPACITY": value,
                "DOCK_LIQUID_GLASS_WINDOW_BLUR": value,
                "DOCK_LIQUID_GLASS_CONTENT_INSET": value,
            ])
            XCTAssertEqual(configuration.clearTintOpacity, 0.4, "clear tint: \(value)")
            XCTAssertEqual(configuration.whiteOverlayOpacity, 0, "white overlay: \(value)")
            XCTAssertEqual(configuration.dimmingOpacity, 0, "dimming: \(value)")
            XCTAssertEqual(configuration.borderPeakOpacity, 0.75, "border peak: \(value)")
            XCTAssertEqual(configuration.borderEdgeLevel, 0.5, "border edge: \(value)")
            XCTAssertEqual(configuration.borderCornerCut, 0.92, "border cut: \(value)")
            XCTAssertEqual(configuration.borderCornerSpread, 2.2, "border spread: \(value)")
            XCTAssertEqual(configuration.borderLineWidth, 0.5, "border width: \(value)")
            XCTAssertEqual(configuration.borderInnerOpacity, 0.21, "border inner: \(value)")
            XCTAssertEqual(configuration.backgroundMaterialOpacity, 0, "background: \(value)")
            XCTAssertEqual(configuration.windowBlurRadius, 0, "window blur: \(value)")
            XCTAssertEqual(configuration.contentInset, 4, "content inset: \(value)")
        }
    }

    /// A 0 radius means no SkyLight call at all: the call is tuning, and its outcome must never
    /// decide whether the bar gets the glass composite.
    func testWindowBlurIsOnlyRequestedForAPositiveRadius() {
        XCTAssertNil(DockLiquidGlassConfiguration.resolve(environment: [:]).requestedWindowBlurRadius)
        XCTAssertNil(resolve(["DOCK_LIQUID_GLASS_WINDOW_BLUR": "0"]).requestedWindowBlurRadius)
        XCTAssertEqual(resolve(["DOCK_LIQUID_GLASS_WINDOW_BLUR": "6"]).requestedWindowBlurRadius, 6)
        XCTAssertEqual(resolve(["DOCK_LIQUID_GLASS_WINDOW_BLUR": "5.6"]).requestedWindowBlurRadius, 6)
        XCTAssertEqual(resolve(["DOCK_LIQUID_GLASS_WINDOW_BLUR": "64"]).requestedWindowBlurRadius, 64)
    }

    /// Background window = the visible backing plate of the content window minus the 20pt transparent shadow margin; the height is decided by `DockPanelHeight.metrics`
    /// (92 − 2×20 = 52 is the old mid-tier panel height, used here only as a geometry sample); **glass no longer has its own second height system**.
    func testBackgroundFrameIsTheVisiblePlateInsideTheShadowPadding() {
        XCTAssertEqual(
            DockLiquidGlassPanelGeometry.backgroundFrame(
                for: CGRect(x: 80, y: 10, width: 440, height: 92),
                shadowPadding: 20
            ),
            CGRect(x: 100, y: 30, width: 400, height: 52)
        )
    }

    func testBackgroundFrameIsIdentityWithoutShadowPadding() {
        let frame = CGRect(x: 10, y: 20, width: 100, height: 40)
        XCTAssertEqual(
            DockLiquidGlassPanelGeometry.backgroundFrame(for: frame, shadowPadding: 0),
            frame
        )
        XCTAssertEqual(
            DockLiquidGlassPanelGeometry.backgroundFrame(for: frame, shadowPadding: -2),
            frame,
            "负值不该把窗口撑大"
        )
    }

    func testCompositePanelLifecycleOrderingIsAtomic() {
        XCTAssertEqual(
            DockLiquidGlassPanelLifecyclePlan.ordering(
                isCompositeActive: true,
                shouldShow: true
            ),
            [.background, .content]
        )
        XCTAssertEqual(
            DockLiquidGlassPanelLifecyclePlan.ordering(
                isCompositeActive: true,
                shouldShow: false
            ),
            [.content, .background]
        )
        XCTAssertEqual(
            DockLiquidGlassPanelLifecyclePlan.ordering(
                isCompositeActive: false,
                shouldShow: true
            ),
            [.content]
        )
        XCTAssertEqual(
            DockLiquidGlassPanelLifecyclePlan.ordering(
                isCompositeActive: false,
                shouldShow: false
            ),
            [.content]
        )
    }

    private func resolve(_ environment: [String: String]) -> DockLiquidGlassConfiguration {
        DockLiquidGlassConfiguration.resolve(environment: environment)
    }

    func testSystemVariantParsesOffAndFallsBackToTheDockMaterial() {
        XCTAssertNil(resolve(["DOCK_LIQUID_GLASS_SYSTEM_VARIANT": " off "]).systemVariant)
        XCTAssertEqual(resolve(["DOCK_LIQUID_GLASS_SYSTEM_VARIANT": "0"]).systemVariant, 0)
        XCTAssertEqual(resolve(["DOCK_LIQUID_GLASS_SYSTEM_VARIANT": "40"]).systemVariant, 40)
        for bad in ["", "abc", "-1", "41", "3.5"] {
            XCTAssertEqual(resolve(["DOCK_LIQUID_GLASS_SYSTEM_VARIANT": bad]).systemVariant, 3, bad)
        }
    }

    /// The variant plate draws its own rim and casts no shadow, so the 2pt outset (which clips
    /// that rim) and the strip shadow go — but only when glass and the variant are both live.
    func testOutsetAndStripShadowFollowTheSystemVariant() {
        typealias C = DockLiquidGlassConfiguration
        XCTAssertEqual(C.backdropOutset(usesLiquidGlass: true, usesSystemVariant: true), 0)
        XCTAssertFalse(C.stripShadowVisible(usesLiquidGlass: true, usesSystemVariant: true))
        for (glass, variant) in [(true, false), (false, true), (false, false)] {
            XCTAssertEqual(C.backdropOutset(usesLiquidGlass: glass, usesSystemVariant: variant), 2)
            XCTAssertTrue(C.stripShadowVisible(usesLiquidGlass: glass, usesSystemVariant: variant))
        }
    }
}
