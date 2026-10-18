import Foundation

// MARK: - Light / dark visual value tables (pure data layer)
//
// Why it exists: the whole look was originally hand-tuned against **dark mode**, with zero appearance branches in the repo -- every foreground color was hardcoded
// to white and every shadow to black. In light mode `NSVisualEffectView` lightens itself (the material follows the system), but the white text,
// white strokes and white dots on top all stop working, and the black shadows turn into a ring of gray smudge. The real user report is item 3 of GitHub issue #3:
// "There are very obvious squares around it, then a shadow next to it that also extends and overflows; the overall style and texture are poor" -- they were in light mode,
// and every complaint maps to some token below failing in light.
//
// **This file does not import SwiftUI**: it stores only base colors + opacity + shadow geometry, all value types that compare exactly,
// so `DockThemeTests` can freeze the dark column item by item. The `Color` / `NSVisualEffectView.Material` bridging lives in
// `App/Scenes/DockTheme.swift`.
//
// Two columns, `light` and `dark`, picked by the window's appearance (`DockTheme.swift`,
// `DockThemeTokens.resolved(for:)`). The light column is the signed-off look and must not drift
// when the dark one is tuned.
//
// ⚠️ Two pitfalls of "looks like a color but isn't" -- they don't belong in this table and must never change by appearance:
//   - The `.black` / `.clear` of the `DockStripView` scroll-edge fade are the **alpha channel of a mask**, not colors.
//   - The `NSColor(white: 1.0, alpha: 0.0)` in `PanelCoordinator` is **fully transparent**, not a "white backing".

/// Base color. The whole look uses only pure white / pure black plus opacity layered over frosted glass; there is no third base color
/// (the only colored element is the badge red, which works in both modes and is not part of this table).
enum DockTintBase: Equatable {
    case white
    case black
}

/// A tint value of "base color + opacity".
struct DockTint: Equatable {
    let base: DockTintBase
    let opacity: Double

    static func white(_ opacity: Double) -> DockTint { .init(base: .white, opacity: opacity) }
    static func black(_ opacity: Double) -> DockTint { .init(base: .black, opacity: opacity) }
}

/// The normal / emphasized pair of values for the same visual (emphasis = hover, or a drop hit).
struct DockTintPair: Equatable {
    let normal: DockTint
    let emphasized: DockTint
}

/// Shadow: color + blur radius + downward offset (x is always 0; the whole look has no shadows with horizontal offset).
struct DockShadow: Equatable {
    let tint: DockTint
    let radius: CGFloat
    let y: CGFloat

    /// Total downward extent of the shadow. **Must be <= `PanelCoordinator.shadowPadding` (20pt)**, otherwise at the panel's
    /// transparent edge it is hard-cut into a flush straight edge -- exactly what the user meant by "the shadow also extends and overflows".
    /// The dark task strip's current 15 + 8 = 23 is 3pt over; dark is frozen and this round leaves it alone (a separate TODO is logged).
    /// All light-column values fit within the budget.
    var verticalExtent: CGFloat { radius + abs(y) }
}

/// Frosted-glass material. It uses its own enum rather than `NSVisualEffectView.Material` to keep this file free of AppKit
/// (the mapping is in `DockTheme.swift`). If the base plate looks too white in light, this is the exit for changing the material.
enum DockPanelMaterial: Equatable {
    case popover
    case hudWindow
    case menu
    case underWindowBackground
    case sidebar
    case titlebar
    case selection
    case headerView
    case fullScreenUI
    case toolTip
    case sheet
    case windowBackground
    case contentBackground
    case underPageBackground

    /// For tuning: `DOCK_PANEL_MATERIAL=<name>` swaps the material **without rebuilding**;
    /// one iteration takes about 8 seconds, which makes it easy to shoot a whole candidate comparison sheet in one go. The names are the cases above (case-insensitive).
    /// An unrecognized name **falls back to the passed-in default** and never crashes -- a typo while tuning shouldn't keep the app from starting.
    static func resolved(from environment: [String: String], fallback: DockPanelMaterial) -> DockPanelMaterial {
        guard let raw = DebugSwitch.panelMaterial.value(in: environment)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !raw.isEmpty else { return fallback }
        return all.first { "\($0)".lowercased() == raw } ?? fallback
    }

    /// The full candidate set, for parsing and for iterating the comparison sheet. All system materials are macOS 10.14+ and our minimum is 12, so no availability branch is needed.
    static let all: [DockPanelMaterial] = [
        .popover, .hudWindow, .menu, .underWindowBackground, .sidebar,
        .titlebar, .selection, .headerView, .fullScreenUI, .toolTip,
        .sheet, .windowBackground, .contentBackground, .underPageBackground,
    ]
}

// Icons are **no longer dimmed by state** (owner removed it 2026-08-02, light and dark together). Only two state signals remain:
// the running dot under the icon (whether it is running) and the titled card's `labelActive` / `labelInactive` (whether it is on the current desktop).
// For the rationale and the old values see `Docs/27-product-decisions.md`.

/// A title pill made of the system's regular glass (Liquid Glass path only): its edge light is
/// what gives the card thickness. `tint` pulls the glass toward the side opposite the text, the
/// same rule as `chipPillFill`; `hoverLift` is laid over it as the hover emphasis.
struct DockChipPillGlass: Equatable {
    let tint: DockTint
    let hoverLift: DockTint
}

/// How the hover bubble's surface is built when Liquid Glass is available.
enum DockTooltipSurface: Equatable {
    /// Our near-white plate over clear glass, with our own rim and shadow (`tooltipPlate`).
    case plateOverClearGlass
    /// The system's regular glass and nothing else — no plate, rim or shadow of ours.
    case regularGlassAlone
}

/// Appearance-independent shape constants. `cornerRadius: 16` used to live in `DockStripView`'s private `Style`,
/// so `DrawerView` / `FolderGridPopupView` / `ShelfGridPopupView` each hardcoded their own 16.
enum DockShape {
    /// Corner radius of all floating panels (task strip / drawer / capsule / the two popups).
    static let panelCornerRadius: CGFloat = 16
    /// NeoBar: the full-width taskbar and its drawer button sit flush with the screen edges,
    /// Windows-style, so they are square. Popups keep `panelCornerRadius`.
    static let taskbarCornerRadius: CGFloat = 0
}

/// NeoBar: a dark tint laid over every panel's glass so it reads more solid and darker than the
/// stock material. Raise the opacities for a more opaque bar, lower them for more glass.
enum DockGlassTint {
    static let darkModeOpacity: Double = 0.42
    static let lightModeOpacity: Double = 0.22
}

/// Solid color scheme for the shelf icon.
///
/// **Can't use `DockTint`**: it has only black / white base colors, whereas this piece needs a colored tile that "looks like a native app icon".
/// The three candidates live here rather than in the theme table -- they are mutually exclusive options for the same spot, not three independent values.
enum DockShelfTileStyle: String, CaseIterable {
    /// Dark stash bag + white paper sticking out of the top edge, vector self-drawn (`ShelfTrayArt`). The look the owner specified on 2026-08-16.
    case tray
    /// Graphite gradient + white tray symbol. The fallback if the tray drawing doesn't look right (the owner's "use graphite gray for now").
    case graphite
    /// System blue gradient + white symbol. Looks like a first-party tool icon, in the same color family as the folder zone on the right.
    case blue
    /// Near-white gradient + dark gray symbol. The least eye-catching; on a light wallpaper it holds up through the symbol and drop shadow.
    case light

    static func resolve(_ raw: String?) -> DockShelfTileStyle {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              let style = DockShelfTileStyle(rawValue: raw) else { return .tray }
        return style
    }

    /// Whether it is the self-drawn illustration (`tray`). The other three tiers are all "solid tile + SF symbol".
    var isIllustration: Bool { self == .tray }

    /// (top, bottom) gradient endpoints and symbol color, all opaque RGB. `tray` doesn't take this path and returns its own approximate colors,
    /// only so that invariants like "the symbol contrasts enough with the base" hold uniformly across all four tiers.
    var colors: (top: DockRGB, bottom: DockRGB, glyph: DockRGB) {
        switch self {
        case .tray:
            return (DockRGB(0.30, 0.30, 0.30), DockRGB(0.19, 0.19, 0.19), DockRGB(0.97, 0.97, 0.97))
        case .graphite:
            return (DockRGB(0.45, 0.47, 0.51), DockRGB(0.27, 0.29, 0.33), DockRGB(1, 1, 1))
        case .blue:
            return (DockRGB(0.36, 0.66, 0.98), DockRGB(0.13, 0.45, 0.90), DockRGB(1, 1, 1))
        case .light:
            return (DockRGB(0.99, 0.99, 1.00), DockRGB(0.88, 0.89, 0.92), DockRGB(0.26, 0.28, 0.32))
        }
    }

    /// Brighten the whole block on a drop hit (it used to be "darken the plate"; on a solid block it goes the other way).
    static let dropTargetLift: Double = 0.12
}

/// Opaque RGB. Deliberately minimal -- only the shelf tile uses it; don't use it to replace `DockTint`.
struct DockRGB: Equatable {
    let red: Double
    let green: Double
    let blue: Double

    init(_ red: Double, _ green: Double, _ blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Interpolate toward white, used for the drop-hit brightening.
    func lightened(by amount: Double) -> DockRGB {
        let t = min(max(amount, 0), 1)
        return DockRGB(red + (1 - red) * t, green + (1 - green) * t, blue + (1 - blue) * t)
    }

    /// Perceived luminance (Rec. 709). Used only by unit tests, to assert that the symbol and the tile don't collide.
    var luminance: Double { 0.2126 * red + 0.7152 * green + 0.0722 * blue }
}

// MARK: - Tokens

struct DockThemeTokens: Equatable {

    // MARK: Panels (shared by the task strip / drawer / drawer capsule / folder popup / shelf popup)

    /// The **top edge** of the panel stroke. Apple's native glass is "bright on top, almost nothing at the bottom", simulating light from above;
    /// before the rework it was a uniform ring of white 0.15, which in light turned into the "obvious square" gray frame the user described.
    /// Dark has the same value at both ends (0.15 / 0.15) -> the gradient degenerates into a uniform color, pixel-identical to before the rework.
    let panelRimTop: DockTint
    /// The panel stroke's **bottom edge / sides**.
    let panelRimBottom: DockTint
    /// Whole-frame highlight on a drop hit (a drawer icon dragged over the task strip, an external directory hovering over the folder zone).
    let panelRimHighlighted: DockTint
    let panelRimLineWidth: CGFloat
    let panelRimHighlightedLineWidth: CGFloat

    // MARK: Glass thickness (inner highlight + inner shadow)
    //
    // Real glass gets its "thickness" from two signals at the edges: a bright line on the upper inner edge (light entering the medium from above) + a dark closing line on the lower inner edge
    // (the medium's self-shadow at the bottom). These two layers are drawn **above** the material and **below** the content, and are our own pixels,
    // so they aren't subject to the limit of "we can't get the pixels behind the window" -- refraction and background saturation can't be done, but thickness can.
    //
    // **Dark is always opacity 0 + width 0**, which is equivalent to not drawing in rendering, so dark stays pixel-frozen.

    let panelInnerHighlight: DockTint
    let panelInnerHighlightWidth: CGFloat
    let panelInnerHighlightBlur: CGFloat
    let panelInnerShadow: DockTint
    let panelInnerShadowWidth: CGFloat
    let panelInnerShadowBlur: CGFloat

    /// Background saturation multiplier. **1.0 = no filter** (the whole modifier isn't attached then, same reasoning as the thickness layer).
    ///
    /// Measured 2026-07-30: SwiftUI's `.saturation()` acts on the frosted glass's **composited result** (material + already blurred
    /// background), so it really can intensify the background color, and **the blur is preserved** -- on a color target, saturation inside the strip
    /// went 0.221 -> 0.534, while the outside control stayed at 0.398.
    ///
    /// By contrast, `.opacity()` is a **dead end**, don't try it again: it erases part of the material itself and exposes the **unblurred**
    /// original desktop (measured: the transition band inside the strip collapses from 115px to 0.9px, as sharp as outside the strip), which looks cheap --
    /// not "more transparent glass" but "glass with a hole cut in it". Transparency can only be changed by switching material.
    let panelBackdropSaturation: Double
    /// Landing shadow for the task strip + drawer capsule.
    let stripShadow: DockShadow
    /// Landing shadow for the drawer + the two popups (slightly tighter than the task strip, since they hover higher).
    let popupShadow: DockShadow
    let panelMaterial: DockPanelMaterial

    // MARK: Title pill of the multi-window chip

    /// Card base.
    ///
    /// **The direction must be opposite to the text.** The plate is see-through and its brightness follows the **wallpaper**, while the text color is a fixed black;
    /// going the same direction would flatten the contrast. Before 2026-08-16 this was "add black 0.05" -- tuned back then to
    /// "make the card look like a card", not for legibility, and it happened to go the same direction. **Don't change it back to adding black on that instinct.**
    ///
    /// ⚠️ **Lightening this can't rescue the gray text of the `labelInactive` tier; the two values must be tuned as a pair.**
    /// Translucent black text drawn on the pill has brightness = pill brightness x (1-alpha), so the text brightens along with the pill:
    /// with gray text alpha=0.45, plate 110 -> contrast 2.13; lifting the pill to 145 only gets 2.57, and even 180 only 2.82;
    /// on the same plate, deepening the gray text itself from 0.45 to 0.62 reaches 2.8+ in one step. What lightening the pill mainly gains is
    /// `labelActive` (black 0.85 is almost opaque, so it gains however much brighter the plate gets).
    ///
    /// The current 0.24 was set in the 2026-08-28 round for "can't see it on a dark wallpaper", and the owner signed it off on a real device the same day
    /// (previously 0.13, which the owner picked on 2026-08-16 from 0.10 / 0.12 / 0.13, compared on light wallpapers only).
    /// The hover tier keeps the existing x1.4 relationship. Tuning exit: `DOCK_CHIP_PILL_FILL`.
    ///
    /// The card's "looks like a card" quality is carried by the stroke from `chipPillRimTop`, not by the fill -- so the stroke must be brighter than the fill.
    let chipPillFill: DockTintPair
    let chipPillRimTop: DockTintPair
    let chipPillRimBottom: DockTint
    /// Non-nil = the pill is system glass where Liquid Glass is available, and `chipPillFill` +
    /// rim are only the fallback (frosted path, drag-carrier bitmap). `nil` = always the flat pill.
    let chipPillGlass: DockChipPillGlass?

    // MARK: Text

    /// Window title (when that window is visible on the desktop).
    let labelActive: DockTint
    /// Window title (when minimized / hidden).
    ///
    /// This is the most fragile contrast on the whole strip: translucent black text, with plate brightness following the wallpaper. On a dark wallpaper 0.45 simply melts away
    /// (reported by the owner 2026-08-28), and **lightening the pill can't rescue it** -- see the comment on `chipPillFill` for why.
    /// The current 0.62 was signed off by the owner on a real device 2026-08-28. Deepening further starts to eat the light/dark distinction of "is it on the current desktop";
    /// don't go past `labelActive` 0.85.
    /// Tuning exit: `DOCK_LABEL_INACTIVE`.
    let labelInactive: DockTint
    /// App-name subtitle below the title pill.
    let labelSubtitle: DockTint

    // MARK: Indicators

    /// The small running dot under the icon. In light, a white dot is completely invisible on light glass.
    let runningDot: DockTint
    /// Vertical divider between task strip sections.
    let zoneDivider: DockTint

    // MARK: Shelf

    /// Shelf tile colors. **Must be opaque** -- it is the only chip on the strip that isn't an app icon,
    /// and if translucent it disappears as soon as the glass behind it darkens (reported by the owner 2026-08-16). See `ShelfChip.shelfIcon`.
    /// Use `DOCK_SHELF_TILE=blue|graphite|light` to swap tiers on the spot, with no recompile.
    let shelfTile: DockShelfTileStyle
    /// Glow expanding outward from the plate on a drop hit.
    let shelfDropGlow: DockTint

    // MARK: Drawer capsule

    /// Placeholder symbol for the 2x2 grid shown when the drawer is empty.
    let capsuleGlyph: DockTint
    /// The "faint glow" when a dragged card hovers over the capsule (the replacement feedback after removing the overly harsh white ring, owner 2026-06-21).
    let capsuleStashGlow: DockTint

    // MARK: Pinned folder chip

    /// Hit ring when an external file is dragged onto the folder chip (= move into that folder).
    let folderDropRing: DockTint
    /// Thin stroke on a real-thumbnail cover (icon covers get no stroke).
    let folderThumbHairline: DockTint

    // MARK: Folder / shelf / Trash popup

    // Native readings, not taste. macOS 27's stack grid follows the appearance: light glass with
    // near-black text in light mode, dark glass with white text in dark mode. The drawer forces the
    // dark column whatever the appearance (`StackPopupAppearance.alwaysDark`).
    /// Title and cell names.
    let stackPopupText: DockTint
    /// The status line (empty shelf, Trash state, unreadable folder).
    let stackPopupNote: DockTint
    /// "Open in Finder" ring. Dark: composited plus-lighter, the native glyph reads backdrop + 124.
    /// Light: composited plus-darker, black 0.5 takes 127 off the backdrop (native (18,69,101) on
    /// (145,196,228)).
    let stackPopupGlyph: DockTint
    /// Back-button plate when the Dock's own art cannot be loaded (plus-lighter is not used there).
    let stackPopupBackFill: DockTint
    /// Frosted fallback only — the glass draws its own edge and shadow.
    let stackPopupHairline: DockTint
    /// The drawer's rule under its title row: the system separator's dark value.
    let stackPopupSeparator: DockTint
    let stackPopupShadow: DockShadow

    // MARK: Window title tooltip

    /// The bubble's plate. **Not `DockTint`**: the two base colors, white/black, can't produce "near-white but not pure white".
    ///
    /// The values were solved for, not tuned. Readings of the same native bubble on two backgrounds:
    /// **173** on a pure black background, **216** on a green wallpaper (about 145). Let `reading = a*L + (1-a)*background`:
    /// `173 = a*L`, `216 = 173 + (1-a)*145` -> **a = 0.70, L = 246**.
    ///
    /// That is, the native bubble is **a near-white plate, 30% see-through**. There was a detour on the way: with only the black-background reading,
    /// I took 173 as its true color and concluded "an opaque neutral gray" -- exactly backwards. **One background can't solve
    /// two unknowns**; whenever measuring this kind of translucent surface later, take two backgrounds.
    let tooltipPlate: DockRGB
    /// See `tooltipPlate`: 0.70 = 30% of the background shows through.
    let tooltipPlateOpacity: Double
    /// Bubble stroke. **Must be brighter than the fill** -- this is the glass's specular edge and also the source of the "crisp" look;
    /// if it is a darker edge instead it amounts to no edge, and the bubble melts into the background (measured on the native cross-section 2026-08-17).
    let tooltipRim: DockTint
    let tooltipText: DockTint
    /// Whether the bubble's text is drawn with CoreGraphics font smoothing. Smoothing dilates
    /// light-on-dark glyphs: measured on the same two characters, the native dark label's stems
    /// are 1.15px against 2.07px smoothed and 1.14px unsmoothed.
    let tooltipTextSmoothing: Bool
    let tooltipShadow: DockShadow
    /// Liquid Glass path only; the frosted path always draws the plate, rim and shadow above.
    let tooltipGlassSurface: DockTooltipSurface

    /// Whether this set of values draws the thickness layer at all. **Dark must be `false`** -- not "draw a fully transparent one" but
    /// keep the layer out of the view tree entirely. `.blur(radius: 0)` can still trigger offscreen rendering in SwiftUI,
    /// and one extra layer could make dark's pixel-by-pixel comparison differ, so the freeze would no longer be strict.
    var drawsPanelThickness: Bool {
        Self.drawsThickness(highlight: panelInnerHighlight, highlightWidth: panelInnerHighlightWidth,
                            shadow: panelInnerShadow, shadowWidth: panelInnerShadowWidth)
    }

    /// The pure-function form of the check above (unit tests hit this directly, instead of constructing the whole 44-field table just to try 4 values).
    /// Transparent color **or** zero line width both mean invisible; both conditions must hold for it to count as "draw".
    static func drawsThickness(highlight: DockTint, highlightWidth: CGFloat,
                               shadow: DockTint, shadowWidth: CGFloat) -> Bool {
        (highlight.opacity > 0 && highlightWidth > 0) || (shadow.opacity > 0 && shadowWidth > 0)
    }
}

// MARK: - The two columns

extension DockThemeTokens {
    /// The light column. Text and material must flip together: `NSVisualEffectView` and Liquid
    /// Glass follow the **window's** `effectiveAppearance`, and so does SwiftUI's `colorScheme`,
    /// which is what `resolved(for:)` keys on — never pick a column from anything else.
    static let light = DockThemeTokens(
        panelRimTop: .white(0.6),
        panelRimBottom: .black(0.1),
        // Drop highlight: a brighter ring laid **on top of** the usual border (`DockPanelRimPlan`).
        // On 2026-08-20 changed from black 0.35 to white 0.45 -- the black version was left over from before the glass went live; laid over the glass's white
        // specular edge it becomes "a ring of black frame". White 0.45 is exactly the value the deleted dark table used back then.
        panelRimHighlighted: .white(0.45),
        panelRimLineWidth: 0.5,
        panelRimHighlightedLineWidth: 1,
        // ⚠️ The two groups below are **candidate values, not in effect by default** -- the owner hasn't signed off yet, and per the rule "anything unsigned-off is opt-in"
        // they are switched on by environment variables (`DOCK_PANEL_THICKNESS=1` / `DOCK_PANEL_SATURATION=candidate`,
        // see `DockEffectSwitches`). The values stay in the table so that tuning only touches one table.
        //
        // Thickness candidate: a bright line on the upper inner edge + a dark closing line on the lower inner edge.
        panelInnerHighlight: .white(0.5),
        panelInnerHighlightWidth: 1.5,
        panelInnerHighlightBlur: 2,
        panelInnerShadow: .black(0.06),
        panelInnerShadowWidth: 2,
        panelInnerShadowBlur: 3,
        // Background-saturation candidate. 3.0 is an extreme value for experiments; day to day this order of magnitude is enough.
        panelBackdropSaturation: 1.25,
        stripShadow: DockShadow(tint: .black(0.14), radius: 8, y: 3),
        popupShadow: DockShadow(tint: .black(0.14), radius: 8, y: 3),
        // Transparency candidate awaits the owner's pick from the comparison sheet; until then keep .popover.
        panelMaterial: .popover,

        // The owner compared 0.10 / 0.12 / 0.13 on a real device on 2026-08-16 and settled on 0.13. Hover state x1.4.
        chipPillFill: DockTintPair(normal: .white(0.24), emphasized: .white(0.336)),
        chipPillRimTop: DockTintPair(normal: .white(0.55), emphasized: .white(0.7)),
        chipPillRimBottom: .black(0.1),
        chipPillGlass: nil,

        labelActive: .black(0.85),
        labelInactive: .black(0.62),
        labelSubtitle: .black(0.55),

        runningDot: .black(0.5),
        zoneDivider: .black(0.12),

        shelfTile: .tray,
        shelfDropGlow: .black(0.1),

        capsuleGlyph: .black(0.55),
        capsuleStashGlow: .black(0.1),

        folderDropRing: .black(0.45),
        folderThumbHairline: .black(0.15),

        // Native light: text (22,27,34) on a (150,199,237) plate.
        stackPopupText: .black(0.86),
        stackPopupNote: .black(0.5),
        stackPopupGlyph: .black(0.5),
        stackPopupBackFill: .black(0.08),
        stackPopupHairline: .black(0.12),
        stackPopupSeparator: .black(0.1),
        stackPopupShadow: DockShadow(tint: .black(0.3), radius: 18, y: 6),

        // Set 2026-08-17 against the edge cross-section of a native screenshot (black background, @2x):
        // the native one reads "0 -> 191 -> **209** -> 173 173 173..." -- a 1px highlight ring **brighter than the fill**,
        // and only then the 173 fill. Ours used to be "59 -> 157 -> 189 -> 202": no edge, and the fill also leaned white,
        // so the bubble "melted" into the background, which is what the owner meant by "not crisp / soft".
        //
        // The bright edge is the glass's specular edge, same logic as the panel stroke (see `panelRimTop`); the direction can't be reversed.
        // 246/255 = 0.965, 30% see-through -- obtained by solving the equations, see the comment on `tooltipPlate`.
        tooltipPlate: DockRGB(0.965, 0.965, 0.968),
        tooltipPlateOpacity: 0.70,
        // Initial value, pending real-device calibration (see the three target points in the field comments).
        tooltipRim: .white(0.45),
        tooltipText: .black(0.85),
        // The signed-off light bubble; not re-measured against the native one for stem width.
        tooltipTextSmoothing: true,
        tooltipShadow: DockShadow(tint: .black(0.14), radius: 5, y: 2),
        // Regular glass alone was measured and rejected here: it follows the backdrop down to 45
        // on black, where the native light bubble stays 173 (`hover-bubble.md`).
        tooltipGlassSurface: .plateOverClearGlass
    )

    /// The dark column: white marks on the system Dock glass in its dark appearance.
    ///
    /// The plate is the system's (variant 3 under `darkAqua`), so nothing here colours it. It
    /// barely lifts a dark backdrop and dims a bright one — white 255 reads about 176 through it —
    /// which makes the bar over a white window the worst case for white text.
    static let dark = DockThemeTokens(
        // The theme rim is drawn only on the frosted / fallback plate; the system glass has its own.
        panelRimTop: .white(0.15),
        panelRimBottom: .white(0.15),
        panelRimHighlighted: light.panelRimHighlighted,
        panelRimLineWidth: light.panelRimLineWidth,
        panelRimHighlightedLineWidth: light.panelRimHighlightedLineWidth,
        // No thickness or saturation candidates in dark: zero means the layers never enter the tree.
        panelInnerHighlight: .white(0),
        panelInnerHighlightWidth: 0,
        panelInnerHighlightBlur: 0,
        panelInnerShadow: .black(0),
        panelInnerShadowWidth: 0,
        panelInnerShadowBlur: 0,
        panelBackdropSaturation: 1.0,
        stripShadow: DockShadow(tint: .black(0.35), radius: 12, y: 5),
        popupShadow: DockShadow(tint: .black(0.35), radius: 12, y: 5),
        panelMaterial: .popover,

        // Against the text, as in the light column: white text needs a darker pill. Worst case
        // (plate 176): 3.44 active / 2.37 inactive, at or above the light column's own worst case.
        // The pill and `labelInactive` are one pair — tune both, then re-run the contrast test.
        // A lightening pill (white 0.10) was compared and dropped: 1.9 / 1.5 over a white window.
        chipPillFill: DockTintPair(normal: .black(0.25), emphasized: .black(0.33)),
        chipPillRimTop: DockTintPair(normal: .white(0.22), emphasized: .white(0.34)),
        chipPillRimBottom: .white(0.04),
        // Measured through the real materials (dark Dock plate under the pill): over a white
        // backdrop the pill reads 111 — 2.9 inactive / 4.5 active, better than the flat pill —
        // and over blue or black it sits at the plate's level, so the edge light carries the card.
        chipPillGlass: DockChipPillGlass(tint: .black(0.3), hoverLift: .white(0.07)),

        labelActive: .white(0.92),
        labelInactive: .white(0.6),
        labelSubtitle: .white(0.6),

        // The native dot is the plate plus ~124 per channel (additive). Chips sit under the
        // strip's edge-fade mask, where a plus-lighter blend cannot see the glass, so this is
        // the translucent white that lands on the same value over a typical dark plate (36).
        runningDot: .white(0.57),
        zoneDivider: .white(0.18),

        shelfTile: light.shelfTile,
        shelfDropGlow: .white(0.25),

        capsuleGlyph: .white(0.6),
        capsuleStashGlow: .white(0.18),

        folderDropRing: .white(0.9),
        folderThumbHairline: .white(0.3),

        stackPopupText: .white(0.95),
        stackPopupNote: .white(0.6),
        stackPopupGlyph: .white(124.0 / 255.0),
        stackPopupBackFill: .white(60.0 / 255.0),
        stackPopupHairline: .white(0.18),
        stackPopupSeparator: .white(0.1),
        stackPopupShadow: light.stackPopupShadow,

        // The native dark bubble *is* the system's regular glass in its dark appearance: fill
        // 64 over a 35 backdrop and 172 over 219, and the same edge profile and shadow, row for
        // row. So the glass path draws that material and nothing of ours on top.
        // The plate below is the frosted path's stand-in, solved from those two readings
        // (grey 105 at 0.41); it matches them but not a coloured backdrop, which it greys out.
        tooltipPlate: DockRGB(105.0 / 255.0, 105.0 / 255.0, 105.0 / 255.0),
        tooltipPlateOpacity: 0.41,
        tooltipRim: .white(0.12),
        tooltipText: .white(0.96),
        tooltipTextSmoothing: false,
        tooltipShadow: DockShadow(tint: .black(0.25), radius: 5, y: 2),
        tooltipGlassSurface: .regularGlassAlone
    )
}
