import XCTest

/// The table has two columns, `light` and `dark`. These tests lock invariants tied to function —
/// foreground direction, the pill pushing the plate away from the text, a contrast floor on each
/// column's worst backdrop, shadows inside their budget, effects off by default — not individual
/// numbers, which are look and stay free to tune.
final class DockThemeTests: XCTestCase {
    /// The light column; the tests below that say nothing else are about it.
    private let theme = DockThemeTokens.light
    private let dark = DockThemeTokens.dark
    private let shadowPadding: CGFloat = 20

    // MARK: - Foreground direction

    /// The foreground must be **darkened (black)**, not lightened (white): adding white on light glass makes it vanish, leaving only the stroke stranded,
    /// and every card turns into a hollow square — exactly what the user complained about: "there are very obvious squares around".
    func testForegroundsAreDarkTinted() {
        let mustBeBlack: [(String, DockTint)] = [
            ("labelActive", theme.labelActive),
            ("labelInactive", theme.labelInactive),
            ("labelSubtitle", theme.labelSubtitle),
            ("runningDot", theme.runningDot),
            ("zoneDivider", theme.zoneDivider),
            ("capsuleGlyph", theme.capsuleGlyph),
            ("folderDropRing", theme.folderDropRing),
            ("tooltipText", theme.tooltipText),
        ]
        for (name, tint) in mustBeBlack {
            XCTAssertEqual(tint.base, .black, "\(name) 必须加黑，加白在浅玻璃上会消失")
        }
    }

    /// The shelf cell is the only chip on the strip that is **not an app icon**. It must be an **opaque solid tile**:
    /// if it were translucent it would vanish when the glass beneath goes dark (reported by the owner 2026-08-16), so its colors go through `DockRGB`
    /// rather than `DockTint`, which has only black and white base colors — this assertion is what stops someone from changing it back to a translucent tint.
    func testShelfTileIsAnOpaqueColouredTile() {
        for style in DockShelfTileStyle.allCases {
            let c = style.colors
            XCTAssertNotEqual(c.top, c.bottom, "\(style) 要有渐变，纯平色不像一枚真图标")
            // Symbol and tile must sit at opposite ends of light/dark, otherwise the symbol vanishes against its own base.
            let tileLuma = (c.top.luminance + c.bottom.luminance) / 2
            XCTAssertGreaterThan(abs(c.glyph.luminance - tileLuma), 0.3,
                                 "\(style) 的符号和瓷砖对比不够")
        }
    }

    /// A drop hit **brightens the whole tile** ("deepening" has no meaning on a solid tile).
    func testShelfTileDropTargetLifts() {
        XCTAssertGreaterThan(DockShelfTileStyle.dropTargetLift, 0)
        let base = DockShelfTileStyle.blue.colors.top
        XCTAssertGreaterThan(base.lightened(by: DockShelfTileStyle.dropTargetLift).luminance,
                             base.luminance)
    }

    /// An unrecognized name falls back to the default tier; no crash and no black screen.
    func testShelfTileStyleFallsBackToDefault() {
        for bad in ["", " ", "purple", "1"] {
            XCTAssertEqual(DockShelfTileStyle.resolve(bad), .tray, "非法值 \(bad) 要回落")
        }
        XCTAssertEqual(DockShelfTileStyle.resolve(" GRAPHITE "), .graphite)
        XCTAssertEqual(theme.effectiveShelfTile, theme.shelfTile,
                       "测试进程没设环境变量，生效值必须是表里的值")
    }

    /// The panel stroke is "bright top edge (white highlight) + dark bottom edge (thin black line)" — the lighting direction of native Apple glass.
    /// A uniform white ring on a light backing is exactly the gray frame the user saw.
    func testPanelRimIsBrightTopDarkBottom() {
        XCTAssertEqual(theme.panelRimTop.base, .white)
        XCTAssertEqual(theme.panelRimBottom.base, .black)
        XCTAssertGreaterThan(theme.panelRimTop.opacity, theme.panelRimBottom.opacity)
    }

    /// The bubble backing locks the **composited reading**, not individual values — so changing how it is written will not cause drift.
    /// The two anchors come from measurements of the same native bubble on two backgrounds: 173 over pure black, 216 over a green wallpaper (145).
    func testTooltipPlateMatchesTheMeasuredNativeBubble() {
        func composite(over background: Double) -> Double {
            theme.tooltipPlateOpacity * theme.tooltipPlate.luminance * 255
                + (1 - theme.tooltipPlateOpacity) * background
        }
        XCTAssertEqual(composite(over: 0), 173, accuracy: 6, "黑底实测 173")
        XCTAssertEqual(composite(over: 145), 216, accuracy: 6, "绿壁纸底实测 216")
        XCTAssertEqual(composite(over: 235), 247, accuracy: 6, "浅色窗口底实测 247（2026-08-17 新增第三点）")
        // Conversely, pin down that "it is translucent": fully opaque would not follow the background and looks dirty over a light wallpaper.
        XCTAssertLessThan(theme.tooltipPlateOpacity, 0.85)
    }

    /// **The bubble stroke must be brighter than the fill.** The native profile (black background @2x) is 0 → 191 → 209 → 173:
    /// a mirror-like edge ring brighter than the fill, which is what cuts the bubble out of the background. We used to darken by 0.1,
    /// which amounts to no edge, and the look is what the owner called "not crisp".
    func testTooltipRimIsBrighterThanItsFill() {
        XCTAssertEqual(theme.tooltipRim.base, .white, "暗边等于没有边")
        // The stroke sits on the **composited fill**, not on the backing color — the two differ a lot over a near-white backing.
        func fill(over background: Double) -> Double {
            theme.tooltipPlateOpacity * theme.tooltipPlate.luminance * 255
                + (1 - theme.tooltipPlateOpacity) * background
        }
        func rim(over background: Double) -> Double {
            let f = fill(over: background)
            return f + theme.tooltipRim.opacity * (255 - f)
        }
        // Native measurement: 209 over black (fill 173), 235 over the green wallpaper (fill 216).
        XCTAssertEqual(rim(over: 0), 209, accuracy: 6)
        XCTAssertEqual(rim(over: 145), 235, accuracy: 6)
        // It must be genuinely visible over both backgrounds; that is where "crisp" comes from.
        XCTAssertGreaterThan(rim(over: 0) - fill(over: 0), 20)
        XCTAssertGreaterThan(rim(over: 145) - fill(over: 145), 12)
    }

    // MARK: - Pill and halo: must push the backing away from the text

    /// **The pill's direction must be opposite to the text.**
    ///
    /// The backing is translucent and its brightness follows the **wallpaper**, while the text color is a fixed black; a pill in the same direction as the text flattens the contrast.
    /// Before 2026-08-16 this was darken 0.05 — tuned back then to "make the card look like a card", not for legibility,
    /// and it happened to be in the same direction. **Do not change it back to darken on that instinct.** The card's "look like a card" is carried by the
    /// `chipPillRimTop` ring stroke, not by the fill.
    func testChipPillPushesAgainstTheTextColour() {
        XCTAssertEqual(theme.labelActive.base, .black, "前提：文字是黑的")
        XCTAssertEqual(theme.chipPillFill.normal.base, .white, "方向反了——药丸要把底板推离黑字")
        XCTAssertEqual(theme.chipPillFill.emphasized.base, .white)
        XCTAssertGreaterThan(theme.chipPillFill.emphasized.opacity, theme.chipPillFill.normal.opacity,
                             "悬停态要比常态更浓")
    }

    /// **The stroke must be brighter than the fill.** The card's "look like a card" comes from the `chipPillRimTop` ring, not from the fill;
    /// on 2026-08-28 the fill was raised from 0.13 to 0.24 for legibility over dark wallpapers, and raising it further would eat the edge,
    /// degrading the card into a white slab smeared on the strip. To raise the fill further, raise the stroke along with it first.
    func testChipPillRimStaysBrighterThanTheFill() {
        XCTAssertEqual(theme.chipPillRimTop.normal.base, .white)
        XCTAssertGreaterThan(theme.chipPillRimTop.normal.opacity, theme.chipPillFill.normal.opacity,
                             "常态：描边要亮于填充")
        XCTAssertGreaterThan(theme.chipPillRimTop.emphasized.opacity, theme.chipPillFill.emphasized.opacity,
                             "悬停态：描边要亮于填充")
    }

    /// **The pill backing and the "not on this desktop" tier of text are a pair; do not tune only one.**
    /// Semi-transparent black text drawn on the pill has brightness = pill brightness × (1−α), so when the pill is brightened the text brightens with it —
    /// so brightening the pill rescues `labelActive` (nearly opaque), but cannot rescue `labelInactive`.
    /// This locks "the gray text must not fade back": it must be clearly more solid than half, otherwise it melts away over a dark wallpaper
    /// (the 0.45 version is what the owner reported on 2026-08-28).
    func testInactiveLabelStaysReadableOnADarkBackdrop() {
        XCTAssertGreaterThanOrEqual(theme.labelInactive.opacity, 0.55,
                                    "灰字太淡，深色壁纸下会化掉——提亮药丸补不回来")
        XCTAssertLessThan(theme.labelInactive.opacity, theme.labelActive.opacity,
                          "还得比在桌面那档淡，「在不在当前桌面」全靠这个深浅差")
    }

    // MARK: - Value validity

    func testShadowsFitInsideShadowPaddingBudget() {
        for column in [theme, dark] {
            XCTAssertLessThanOrEqual(column.stripShadow.verticalExtent, shadowPadding)
            XCTAssertLessThanOrEqual(column.popupShadow.verticalExtent, shadowPadding)
        }
    }

    /// The stack popup follows the appearance (macOS 27's native stack grid is light glass with dark
    /// text in light mode, dark glass with white text in dark mode): each column's foregrounds are the
    /// opposite of its plate.
    func testStackPopupForegroundsContrastWithTheirPlate() {
        for (column, base) in [(theme, DockTintBase.black), (dark, DockTintBase.white)] {
            for tint in [column.stackPopupText, column.stackPopupNote, column.stackPopupGlyph,
                         column.stackPopupBackFill, column.stackPopupHairline, column.stackPopupSeparator] {
                XCTAssertEqual(tint.base, base)
            }
            XCTAssertGreaterThan(column.stackPopupText.opacity, column.stackPopupNote.opacity)
        }
    }

    /// The frosted fallback's shadow lives in the popup window's own transparent border.
    func testStackPopupShadowFitsInsideItsPanelMargin() {
        XCTAssertLessThanOrEqual(theme.stackPopupShadow.verticalExtent, StackPopupMetrics.panelMargin)
    }

    /// Easy to overshoot by accident when hand-tuning.
    func testAllOpacitiesAreInRange() {
        for column in [theme, dark] {
            for tint in column.allTints {
                XCTAssertTrue((0 ... 1).contains(tint.opacity), "不透明度越界：\(tint)")
            }
        }
    }

    /// Gate for the thickness layer: **draw if either of the two pairs (inner highlight / inner shadow) has "both nonzero color and nonzero line width"**.
    /// The criterion is applied "within the same pair" — a pair with color 0 or line width 0 does not count, otherwise an invisible layer of
    /// offscreen rendering would be drawn (`.blur(radius: 0)` triggers it just the same).
    func testThicknessGateNeedsBothColourAndWidthWithinAPair() {
        XCTAssertFalse(DockThemeTokens.drawsThickness(
            highlight: .white(0), highlightWidth: 3, shadow: .black(0), shadowWidth: 3),
            "两对的颜色都是 0 → 不画")
        XCTAssertFalse(DockThemeTokens.drawsThickness(
            highlight: .white(0.1), highlightWidth: 0, shadow: .black(0.1), shadowWidth: 0),
            "两对的线宽都是 0 → 不画")
        XCTAssertTrue(DockThemeTokens.drawsThickness(
            highlight: .white(0), highlightWidth: 3, shadow: .black(0.1), shadowWidth: 3),
            "内阴影这一对齐全 → 画")
        XCTAssertTrue(DockThemeTokens.drawsThickness(
            highlight: .white(0.1), highlightWidth: 3, shadow: .black(0), shadowWidth: 0),
            "内高光这一对齐全 → 画")
    }

    // MARK: - Effect switches

    /// **Unaccepted effects are always off by default.** Bitten once on 2026-07-30: the glass exploration was rightly made default-off,
    /// but the saturation boost and thickness layer that landed the same day were default-on, so the bar in the owner's eyes quietly drifted from the version he had signed off.
    func testAllEffectsAreOffByDefault() {
        let empty: [String: String] = [:]
        XCTAssertEqual(DockEffectSwitches.saturation(from: empty, candidate: 1.25), 1.0,
                       "没设环境变量 → 不提饱和")
        XCTAssertFalse(DockEffectSwitches.thicknessEnabled(from: empty), "没设环境变量 → 不画厚度层")
        XCTAssertEqual(DockPanelMaterial.resolved(from: empty, fallback: .popover), .popover,
                       "没设环境变量 → 用 token 里的材质")
    }

    func testSaturationSwitch() {
        XCTAssertEqual(DockEffectSwitches.saturation(
            from: ["DOCK_PANEL_SATURATION": "candidate"], candidate: 1.25), 1.25)
        XCTAssertEqual(DockEffectSwitches.saturation(
            from: ["DOCK_PANEL_SATURATION": " 1.8 "], candidate: 1.25), 1.8)
        for bad in ["", "abc", "0", "-1", "99"] {
            XCTAssertEqual(DockEffectSwitches.saturation(
                from: ["DOCK_PANEL_SATURATION": bad], candidate: 1.25), 1.0, "非法值 \(bad) 要回落")
        }
    }

    func testThicknessSwitch() {
        XCTAssertTrue(DockEffectSwitches.thicknessEnabled(from: ["DOCK_PANEL_THICKNESS": "1"]))
        XCTAssertTrue(DockEffectSwitches.thicknessEnabled(from: ["DOCK_PANEL_THICKNESS": " 1 "]))
        for bad in ["", "0", "true", "yes"] {
            XCTAssertFalse(DockEffectSwitches.thicknessEnabled(from: ["DOCK_PANEL_THICKNESS": bad]))
        }
    }

    func testMaterialOverrideParsesKnownNames() {
        XCTAssertEqual(DockPanelMaterial.resolved(
            from: ["DOCK_PANEL_MATERIAL": "hudWindow"], fallback: .popover), .hudWindow)
        XCTAssertEqual(DockPanelMaterial.resolved(
            from: ["DOCK_PANEL_MATERIAL": " MENU "], fallback: .popover), .menu)
    }

    func testMaterialOverrideFallsBackOnUnknownOrEmpty() {
        for bad in ["", "  ", "notAMaterial"] {
            XCTAssertEqual(DockPanelMaterial.resolved(
                from: ["DOCK_PANEL_MATERIAL": bad], fallback: .popover), .popover, "「\(bad)」要回落")
        }
    }

    func testMaterialAllCoversEveryCase() {
        XCTAssertEqual(DockPanelMaterial.all.count, 14, "系统材质候选共 14 种；新增 case 时同步这里")
    }

    // MARK: - Contrast tuning outlets
    //
    // These two are not the same thing as the "effect switches" above: the default value **is the signed-off look**, and the environment variables are just a tuning outlet
    // that can be flipped back and forth without recompiling (same as `DOCK_DRAG_FLIGHT_MS`). So what is asserted is "unset / garbage always falls back to the table values",
    // not "default off".

    func testContrastOverridesFallBackToTheTable() {
        let pair = DockTintPair(normal: .white(0.24), emphasized: .white(0.336))
        XCTAssertEqual(DockEffectSwitches.chipPillFill(from: [:], candidate: pair), pair)
        XCTAssertEqual(DockEffectSwitches.labelInactive(from: [:], candidate: .black(0.62)), .black(0.62))
        for bad in ["", "  ", "abc", "-0.1", "1.2", "0.2,", "0.2,abc", "0.2,0.3,0.4"] {
            XCTAssertEqual(DockEffectSwitches.chipPillFill(
                from: ["DOCK_CHIP_PILL_FILL": bad], candidate: pair), pair, "非法值「\(bad)」要回落")
            XCTAssertEqual(DockEffectSwitches.labelInactive(
                from: ["DOCK_LABEL_INACTIVE": bad], candidate: .black(0.62)), .black(0.62),
                "非法值「\(bad)」要回落")
        }
    }

    func testChipPillFillOverrideParses() {
        let pair = DockTintPair(normal: .white(0.24), emphasized: .white(0.336))
        // Given only one number → the hover state is derived with the table's existing ×1.4.
        XCTAssertEqual(DockEffectSwitches.chipPillFill(
            from: ["DOCK_CHIP_PILL_FILL": " 0.3 "], candidate: pair),
            DockTintPair(normal: .white(0.3), emphasized: .white(0.3 * 1.4)))
        XCTAssertEqual(DockEffectSwitches.chipPillFill(
            from: ["DOCK_CHIP_PILL_FILL": "0.18, 0.4"], candidate: pair),
            DockTintPair(normal: .white(0.18), emphasized: .white(0.4)))
        // Values derived with ×1.4 must not overflow 1.0.
        XCTAssertEqual(DockEffectSwitches.chipPillFill(
            from: ["DOCK_CHIP_PILL_FILL": "0.9"], candidate: pair).emphasized, .white(1))
    }

    func testLabelInactiveOverrideParses() {
        XCTAssertEqual(DockEffectSwitches.labelInactive(
            from: ["DOCK_LABEL_INACTIVE": " 0.55 "], candidate: .black(0.62)), .black(0.55))
    }

    /// The **base color of an override has no outlet**: the direction cannot be flipped via environment variables
    /// (flipping it would flatten the contrast; see the comment on `DockThemeTokens.chipPillFill`).
    /// The override changes the opacity only; each column keeps its own base.
    func testContrastOverridesCannotFlipTheDirection() {
        for column in [theme, dark] {
            let pair = DockEffectSwitches.chipPillFill(
                from: ["DOCK_CHIP_PILL_FILL": "0.3"], candidate: column.chipPillFill)
            XCTAssertEqual(pair.normal, DockTint(base: column.chipPillFill.normal.base, opacity: 0.3))
            XCTAssertEqual(pair.emphasized.base, column.chipPillFill.emphasized.base)
            XCTAssertEqual(
                DockEffectSwitches.labelInactive(from: ["DOCK_LABEL_INACTIVE": "0.5"], candidate: column.labelInactive),
                DockTint(base: column.labelInactive.base, opacity: 0.5))
        }
    }

    // MARK: - Dark column

    /// The mirror of `testForegroundsAreDarkTinted`: on the dark glass, black marks vanish.
    func testDarkForegroundsAreWhiteTinted() {
        let mustBeWhite: [(String, DockTint)] = [
            ("labelActive", dark.labelActive),
            ("labelInactive", dark.labelInactive),
            ("labelSubtitle", dark.labelSubtitle),
            ("runningDot", dark.runningDot),
            ("zoneDivider", dark.zoneDivider),
            ("capsuleGlyph", dark.capsuleGlyph),
            ("folderDropRing", dark.folderDropRing),
            ("tooltipText", dark.tooltipText),
        ]
        for (name, tint) in mustBeWhite {
            XCTAssertEqual(tint.base, .white, "\(name) must be white-based in the dark column")
        }
        XCTAssertLessThan(dark.labelInactive.opacity, dark.labelActive.opacity,
                          "the active / inactive difference is the only on-desktop cue")
    }

    /// The dark column is the drawer's (forced dark) and dark mode's: the values it had when the
    /// popup was dark in both appearances, unchanged.
    func testStackPopupDarkColumnKeepsItsValues() {
        XCTAssertEqual(dark.stackPopupText, .white(0.95))
        XCTAssertEqual(dark.stackPopupNote, .white(0.6))
        XCTAssertEqual(dark.stackPopupGlyph, .white(124.0 / 255.0))
        XCTAssertEqual(dark.stackPopupBackFill, .white(60.0 / 255.0))
        XCTAssertEqual(dark.stackPopupHairline, .white(0.18))
        XCTAssertEqual(dark.stackPopupSeparator, .white(0.1))
        XCTAssertEqual(dark.stackPopupShadow, theme.stackPopupShadow)
        XCTAssertEqual(dark.shelfTile, theme.shelfTile, "the shelf tile is opaque art, not a tint")
    }

    /// Same rule as the light column, mirrored: white text, so the pill darkens the plate.
    func testDarkChipPillPushesAgainstTheTextColour() {
        XCTAssertEqual(dark.labelActive.base, .white, "premise: the text is white")
        XCTAssertEqual(dark.chipPillFill.normal.base, .black)
        XCTAssertEqual(dark.chipPillFill.emphasized.base, .black)
        XCTAssertGreaterThan(dark.chipPillFill.emphasized.opacity, dark.chipPillFill.normal.opacity)
        // The card's outline is the rim's job; on a dark backdrop the fill is nearly invisible.
        XCTAssertEqual(dark.chipPillRimTop.normal.base, .white)
        XCTAssertGreaterThan(dark.chipPillRimTop.emphasized.opacity, dark.chipPillRimTop.normal.opacity)
    }

    /// **The contrast floor.** Composite the pill onto the plate, then the *translucent* text onto
    /// the pill, then take the sRGB contrast ratio — leaving the text's own opacity out overstates
    /// it badly. Each column is judged on its worst backdrop, read off the system Dock glass:
    /// light = bar over black (plate 38), dark = bar over white (plate 176). The floor is what
    /// the signed-off light column achieves there, so dark may not read worse than light already does.
    func testTitlesKeepTheContrastFloorOnEachColumnsWorstBackdrop() {
        let activeFloor = 2.8, inactiveFloor = 2.3
        let cases: [(String, DockThemeTokens, Double)] = [("light", theme, 38), ("dark", dark, 176)]
        for (name, column, plate) in cases {
            for (state, pill) in [("normal", column.chipPillFill.normal), ("hover", column.chipPillFill.emphasized)] {
                let pillLevel = Self.composite(pill, over: plate)
                let active = Self.contrast(Self.composite(column.labelActive, over: pillLevel), pillLevel)
                let inactive = Self.contrast(Self.composite(column.labelInactive, over: pillLevel), pillLevel)
                XCTAssertGreaterThanOrEqual(active, activeFloor, "\(name) \(state): active title \(active)")
                XCTAssertGreaterThanOrEqual(inactive, inactiveFloor, "\(name) \(state): inactive title \(inactive)")
            }
        }
    }

    /// The dark bubble is the system's regular glass on the glass path (the native one reads the
    /// same, row for row); the plate is only the frosted path's stand-in, solved from the native
    /// bubble on two backdrops: 64 over 35 and 172 over 219.
    func testDarkTooltipIsSystemGlassWithAPlateFittedForTheFrostedPath() {
        XCTAssertEqual(dark.tooltipGlassSurface, .regularGlassAlone)
        XCTAssertEqual(theme.tooltipGlassSurface, .plateOverClearGlass,
                       "light: regular glass alone falls to 45 on black, the native bubble stays 173")
        func composite(over background: Double) -> Double {
            dark.tooltipPlateOpacity * dark.tooltipPlate.luminance * 255
                + (1 - dark.tooltipPlateOpacity) * background
        }
        XCTAssertEqual(composite(over: 35), 64, accuracy: 4)
        XCTAssertEqual(composite(over: 219), 172, accuracy: 4)
        XCTAssertEqual(dark.tooltipRim.base, .white, "a dark rim is no rim")
    }

    /// No unaccepted effect rides in with the dark column: zero means the layers never enter the tree.
    func testDarkColumnCarriesNoEffectCandidates() {
        XCTAssertFalse(dark.drawsPanelThickness)
        XCTAssertEqual(dark.panelBackdropSaturation, 1.0)
    }

    func testResolvedColumnFollowsTheColourScheme() {
        XCTAssertEqual(DockThemeTokens.resolved(for: .light), .light)
        XCTAssertEqual(DockThemeTokens.resolved(for: .dark), .dark)
    }

    /// The glass pill is tinted to the side opposite the text, like the flat pill it falls back to
    /// (frosted path, drag-carrier bitmap) — and the light column has no glass pill at all.
    func testGlassPillKeepsTheFlatPillsDirection() throws {
        let glass = try XCTUnwrap(dark.chipPillGlass)
        XCTAssertEqual(glass.tint.base, .black)
        XCTAssertEqual(dark.chipPillFill.normal.base, .black, "the fallback under the glass candidate")
        XCTAssertNil(theme.chipPillGlass, "the light pill is signed off as the flat one")
    }

    // MARK: - Contrast helpers (levels are 0…255)

    private static func composite(_ tint: DockTint, over background: Double) -> Double {
        let base: Double = tint.base == .white ? 255 : 0
        return background * (1 - tint.opacity) + base * tint.opacity
    }

    private static func relativeLuminance(_ level: Double) -> Double {
        let c = level / 255
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    private static func contrast(_ a: Double, _ b: Double) -> Double {
        let la = relativeLuminance(a), lb = relativeLuminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
}

private extension DockThemeTokens {
    /// For iteration: all tint values in this table (including the tint that shadows carry). Add new fields here.
    var allTints: [DockTint] {
        [panelRimTop, panelRimBottom, panelRimHighlighted,
         panelInnerHighlight, panelInnerShadow,
         stripShadow.tint, popupShadow.tint,
         chipPillFill.normal, chipPillFill.emphasized,
         chipPillRimTop.normal, chipPillRimTop.emphasized, chipPillRimBottom,
         labelActive, labelInactive, labelSubtitle,
         runningDot, zoneDivider,
         shelfDropGlow,
         capsuleGlyph, capsuleStashGlow,
         folderDropRing, folderThumbHairline,
         stackPopupText, stackPopupNote, stackPopupGlyph, stackPopupBackFill,
         stackPopupHairline, stackPopupSeparator, stackPopupShadow.tint,
         tooltipRim, tooltipText, tooltipShadow.tint]
    }
}
