import AppKit
import SwiftUI

// MARK: - SwiftUI / AppKit bridge for DockThemeTokens
//
// The pure value table is in `Core/Support/DockThemeTokens.swift` (it does not import SwiftUI, so unit tests can freeze it exactly).
// This file only translates "values -> Color / Material / modifiers" and contains no value-selection logic.
//
// Usage — a view that needs colour declares
//     @Environment(\.colorScheme) private var colorScheme
//     private var theme: DockThemeTokens { .resolved(for: colorScheme) }
// and reads `theme.xxx.color`.
//
// `colorScheme` comes from the hosting window's `effectiveAppearance`, the same source the frosted
// material and Liquid Glass follow, so text and plate always flip together. There is deliberately
// no appearance-free accessor: a view that skipped the environment would stay light on a dark plate.

extension DockThemeTokens {
    /// The column for a SwiftUI colour scheme (anything that is not `.dark` is light).
    static func resolved(for colorScheme: ColorScheme) -> DockThemeTokens {
        colorScheme == .dark ? .dark : .light
    }

    /// The material actually in effect: `DOCK_PANEL_MATERIAL` overrides the token value (unrecognized names fall back, no crash).
    var effectivePanelMaterial: DockPanelMaterial {
        DockPanelMaterial.resolved(from: DockEffectSwitches.environment, fallback: panelMaterial)
    }

    /// The backdrop saturation actually in effect. Off -> `1.0` (the bridge layer's `dockBackdropSaturation` skips the modifier entirely).
    /// Only when on does it use the candidate value from the table; a number can also be given directly in the environment variable to override it.
    var effectiveBackdropSaturation: Double {
        DockEffectSwitches.saturation(from: DockEffectSwitches.environment, candidate: panelBackdropSaturation)
    }

    /// The shelf tile color scheme actually in effect: `DOCK_SHELF_TILE=blue|graphite|light` overrides the token value
    ///(unrecognized names fall back to `.blue`, no crash). The three options are mutually exclusive at the same slot, switchable live without recompiling.
    var effectiveShelfTile: DockShelfTileStyle {
        guard let raw = DebugSwitch.shelfTile.value(in: DockEffectSwitches.environment) else { return shelfTile }
        return DockShelfTileStyle.resolve(raw)
    }

    /// Whether the thickness layer is drawn: **check the switch first**, then the pure condition (`drawsPanelThickness`; color and line width must both be non-zero).
    /// Two safeguards in dark mode -- the candidate value is already 0, so it is not drawn even if the switch is on.
    var drawsEffectiveThickness: Bool {
        DockEffectSwitches.thicknessEnabled(from: DockEffectSwitches.environment) && drawsPanelThickness
    }

    /// The title-card pill fill actually in effect: `DOCK_CHIP_PILL_FILL` overrides the value in the table.
    /// Unlike the ones above, the default here **is the signed-off look**; the environment variable is just a tuning outlet that needs no recompile
    ///(like `DOCK_DRAG_FLIGHT_MS`), not the "unaccepted effect, opt-in" kind.
    var effectiveChipPillFill: DockTintPair {
        DockEffectSwitches.chipPillFill(from: DockEffectSwitches.environment, candidate: chipPillFill)
    }

    /// The "not on the current desktop" title color actually in effect: `DOCK_LABEL_INACTIVE` overrides the value in the table.
    /// Must be tuned together with `effectiveChipPillFill`; see the `chipPillFill` comment for why.
    var effectiveLabelInactive: DockTint {
        DockEffectSwitches.labelInactive(from: DockEffectSwitches.environment, candidate: labelInactive)
    }
}

enum DockEffectSwitches {
    /// Read once and then fixed -- during tuning, change the environment variable and restart once; this also avoids inconsistency within one session.
    static let environment = ProcessInfo.processInfo.environment

    /// `DOCK_PANEL_SATURATION=1.25`. Unset / non-numeric / out of the reasonable range -> `1.0` (= no filter).
    /// Special case: treating `1` as "on, use the candidate value from the table" makes no sense -- the number is the multiplier itself, and `1` means no saturation boost.
    /// To use the candidate value from the table, write `candidate`.
    static func saturation(from environment: [String: String], candidate: Double) -> Double {
        guard let raw = DebugSwitch.panelSaturation.value(in: environment)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !raw.isEmpty else { return 1.0 }
        if raw == "candidate" { return candidate }
        guard let value = Double(raw), value > 0, value <= 5 else { return 1.0 }
        return value
    }

    /// Only `DOCK_PANEL_THICKNESS=1` turns it on. Everything else (including unset, `0`, and garbage) is off.
    static func thicknessEnabled(from environment: [String: String]) -> Bool {
        DebugSwitch.panelThickness.value(in: environment)?.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }

    /// `DOCK_CHIP_PILL_FILL=<normal>[,<hover>]`, both opacities in 0...1.
    /// With only one number, the hover state is derived from the existing **x1.4** relationship in the table. Unset / non-numeric / out of range -> fall back to the table value.
    /// Only the opacity is overridden; the base stays the column's own, so the pill cannot be
    /// flipped onto the text's side (`DockThemeTokens.chipPillFill`).
    static func chipPillFill(from environment: [String: String], candidate: DockTintPair) -> DockTintPair {
        guard let raw = DebugSwitch.chipPillFill.value(in: environment)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return candidate }
        let parts = raw.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard (1...2).contains(parts.count), let normal = opacity(parts[0]) else { return candidate }
        let emphasized: Double
        if parts.count == 2 {
            guard let parsed = opacity(parts[1]) else { return candidate }
            emphasized = parsed
        } else {
            emphasized = min(normal * 1.4, 1)
        }
        return DockTintPair(normal: DockTint(base: candidate.normal.base, opacity: normal),
                            emphasized: DockTint(base: candidate.emphasized.base, opacity: emphasized))
    }

    /// `DOCK_LABEL_INACTIVE=<opacity>` (0...1). Unset / non-numeric / out of range -> fall back to the table value.
    /// The base stays the column's own, as above.
    static func labelInactive(from environment: [String: String], candidate: DockTint) -> DockTint {
        guard let raw = DebugSwitch.labelInactive.value(in: environment)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              let value = opacity(raw) else { return candidate }
        return DockTint(base: candidate.base, opacity: value)
    }

    /// Parse an opacity in 0...1. Empty string / non-numeric / out of range are all `nil`, and the caller falls back.
    private static func opacity(_ raw: String) -> Double? {
        guard !raw.isEmpty, let value = Double(raw), value >= 0, value <= 1 else { return nil }
        return value
    }

    /// Tuning diagnostic: print a line only if a switch was actually set, and it prints the **parsed** value --
    /// a wrong name or number (that was fallen back) is obvious on the spot, so you won't compare against a reference image that never actually took effect.
    static func logActiveOverrides(material: DockPanelMaterial, saturation: Double, thickness: Bool) {
        if let raw = DebugSwitch.panelMaterial.value(in: environment) {
            print("[panel] DOCK_PANEL_MATERIAL=\"\(raw)\" → 实际生效 \(material)")
        }
        if let raw = DebugSwitch.panelSaturation.value(in: environment) {
            print("[panel] DOCK_PANEL_SATURATION=\"\(raw)\" → 实际生效 \(saturation)")
        }
        if let raw = DebugSwitch.panelThickness.value(in: environment) {
            print("[panel] DOCK_PANEL_THICKNESS=\"\(raw)\" → 厚度层\(thickness ? "开" : "关")")
        }
        // These two don't belong to the base panel, but they are looked at together with the ones above when tuning contrast, so they are printed in the same place.
        // Both overrides apply to whichever column is showing (opacity only).
        if let raw = DebugSwitch.chipPillFill.value(in: environment) {
            let pair = DockThemeTokens.light.effectiveChipPillFill
            print("[panel] DOCK_CHIP_PILL_FILL=\"\(raw)\" → 实际生效 常态 \(pair.normal.opacity) / 悬停 \(pair.emphasized.opacity)")
        }
        if let raw = DebugSwitch.labelInactive.value(in: environment) {
            print("[panel] DOCK_LABEL_INACTIVE=\"\(raw)\" → 实际生效 \(DockThemeTokens.light.effectiveLabelInactive.opacity)")
        }
    }
}

extension DockRGB {
    var color: Color { Color(red: red, green: green, blue: blue) }
}

extension DockShelfTileStyle {
    /// Tile's top->bottom gradient. `lifted` = an external file hover hit; the whole tile is lifted slightly toward white.
    func gradient(lifted: Bool) -> LinearGradient {
        let c = colors
        let amount = lifted ? Self.dropTargetLift : 0
        return LinearGradient(colors: [c.top.lightened(by: amount).color,
                                       c.bottom.lightened(by: amount).color],
                              startPoint: .top,
                              endPoint: .bottom)
    }

    var glyphColor: Color { colors.glyph.color }
}

extension DockTint {
    var color: Color {
        switch base {
        case .white: return Color.white.opacity(opacity)
        case .black: return Color.black.opacity(opacity)
        }
    }

    /// The fully transparent version of the same base color.
    /// **Don't substitute `Color.clear`**: the animation interpolates between two colors, and fading from `.clear` toward a white stroke
    /// shows a gray fringe midway; the pre-refactor code was already `opacity(isActive ? 0.9 : 0)`.
    var transparent: Color { DockTint(base: base, opacity: 0).color }

    /// Toggle the same tint by state (off = fully transparent version of the same base color).
    func color(active: Bool) -> Color { active ? color : transparent }
}

extension DockTintPair {
    /// - Parameter emphasized: hovering, or a drop hit.
    func color(emphasized: Bool) -> Color {
        (emphasized ? self.emphasized : normal).color
    }

    func color(emphasisProgress rawProgress: Double) -> Color {
        let progress = min(max(rawProgress, 0), 1)
        let opacity = normal.opacity + (emphasized.opacity - normal.opacity) * progress
        return DockTint(base: normal.base, opacity: opacity).color
    }
}

extension DockPanelMaterial {
    var nsMaterial: NSVisualEffectView.Material {
        switch self {
        case .popover: return .popover
        case .hudWindow: return .hudWindow
        case .menu: return .menu
        case .underWindowBackground: return .underWindowBackground
        case .sidebar: return .sidebar
        case .titlebar: return .titlebar
        case .selection: return .selection
        case .headerView: return .headerView
        case .fullScreenUI: return .fullScreenUI
        case .toolTip: return .toolTip
        case .sheet: return .sheet
        case .windowBackground: return .windowBackground
        case .contentBackground: return .contentBackground
        case .underPageBackground: return .underPageBackground
        }
    }
}

// MARK: - Switches for unaccepted effects
//
// **Default value = the look the owner has already approved; unaccepted effects are always opt-in.**
//
// This was corrected on 2026-07-30: the glass exploration was made default-off with `DOCK_LIQUID_GLASS=1` required to enable it,
// but the saturation boost and thickness layer added the same day took effect by default -- the same kind of unaccepted effect, two standards. As a result the owner's
// view drifted away from the version he had signed off on without his knowing, and he found out himself.
//
// So the three below are uniformly opt-in. When tuning, restart once to switch one at a time, which also solves "three variables stacked together can't be attributed".
// Candidate values still live in just one table (`DockThemeTokens.light`); the switch only decides whether to use them.

extension DockThemeTokens {
    /// Panel stroke: bright on top, dark on the bottom, simulating light from above (the lighting direction of Apple's native glass).
    /// Same value at both dark-mode ends -> the gradient degenerates to a uniform color, pixel-identical to the pre-refactor `.strokeBorder(.white.opacity(0.15))`.
    var panelRimStyle: LinearGradient {
        LinearGradient(colors: [panelRimTop.color, panelRimBottom.color],
                       startPoint: .top,
                       endPoint: .bottom)
    }

    /// Use a solid-color full frame on a drop hit; otherwise use the top-bottom gradient.
    func panelRimStyle(highlighted: Bool) -> AnyShapeStyle {
        highlighted ? AnyShapeStyle(panelRimHighlighted.color) : AnyShapeStyle(panelRimStyle)
    }

    func panelRimLineWidth(highlighted: Bool) -> CGFloat {
        highlighted ? panelRimHighlightedLineWidth : panelRimLineWidth
    }

    /// Glass thickness layer: a bright line on the upper inner edge (light entering the medium from above) + a dark closure on the lower inner edge (the medium's self-shadow at the bottom).
    /// Drawn **above** the material and **below** the content, using our own pixels -- so it isn't subject to the "can't get the pixels behind the window"
    /// limitation (which is exactly where refraction and backdrop saturation get stuck).
    ///
    /// The caller must first check `drawsEffectiveThickness` (switch + pure condition): in dark mode and when off, the whole layer stays out of the view tree.
    @ViewBuilder
    func panelThicknessLayer(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            shape
                .strokeBorder(
                    LinearGradient(colors: [panelInnerHighlight.color, panelInnerHighlight.transparent],
                                   startPoint: .top, endPoint: .center),
                    lineWidth: panelInnerHighlightWidth
                )
                .blur(radius: panelInnerHighlightBlur)
            shape
                .strokeBorder(
                    LinearGradient(colors: [panelInnerShadow.transparent, panelInnerShadow.color],
                                   startPoint: .center, endPoint: .bottom),
                    lineWidth: panelInnerShadowWidth
                )
                .blur(radius: panelInnerShadowBlur)
        }
        // The blur spills past the shape and must be clipped back, otherwise the thickness layer would smear outside the panel.
        .clipShape(shape)
        // A purely decorative layer that must never steal chip clicks (the panel is a nonactivatingPanel, and chips rely entirely on onTapGesture).
        .allowsHitTesting(false)
    }

    /// Stroke of the title pill: likewise bright on top, dark at the bottom.
    /// - Parameter emphasized: hovering.
    func chipPillRimStyle(emphasized: Bool) -> LinearGradient {
        LinearGradient(colors: [chipPillRimTop.color(emphasized: emphasized), chipPillRimBottom.color],
                       startPoint: .top,
                       endPoint: .bottom)
    }

    func chipPillRimStyle(emphasisProgress: Double) -> LinearGradient {
        LinearGradient(
            colors: [chipPillRimTop.color(emphasisProgress: emphasisProgress), chipPillRimBottom.color],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

extension View {
    /// Hover feedback for the quiet tier: the whole tile **scales up slightly**. The criterion is in `HoverStyle.showsQuietHoverFeedback`.
    ///
    /// `scaleEffect` is a pure rendering transform: it **does not change layout size** (this tier's baseline is "moving the mouse across the taskbar causes no reflow"),
    /// and it doesn't affect the drop-hit rectangle reported by the GeometryReader in `.background` -- `PinnedFolderChip`'s
    /// whole-tile scale-up has long worked this way; the same existing conclusion.
    ///
    /// anchor is `.bottom`: the strip is only 54pt tall and the card fills the strip height, so scaling from the center would overflow the strip downward;
    /// pushing up from the bottom edge both stays inside the strip and feels more like the native Dock's magnification direction.
    ///
    /// The animation uses `.animation(_:value:)` (value-scoped) and moves only when `isActive` changes.
    /// `LauncherChip`'s launch bounce has its own, more inner `.animation(_:value: bounceUp)`;
    /// the inner one takes priority and won't be swept away by this layer -- what AGENTS' "quiet tier produces no transaction" guards against is the bounce being hijacked.
    ///
    /// **The curve was chosen by the owner on 2026-08-17 from three options (`easeOut 0.12` = keep as is)**, not a casually written default.
    /// The basis has two layers, so don't read them mixed: **measured** -- with a synthesized hover, the main thread had zero hitches in those 120ms, zero whole-strip recomputation,
    /// and zero relayout; **inferred from that** -- what he called "not smooth enough" is a curve preference, not resources being taken by something else,
    /// and the curve belongs to look-and-feel, which can't be measured, so it was made three options for him to compare by eye. He picked the status quo after comparing, and the scaffolding was removed right away.
    /// `cardWidth` is **this card's own width** (already scaled by tier), used to cap the outward expansion on each side --
    /// proportional scaling would expand 8.4pt per side on a 168pt title card, eating the 10pt gap between cards (reported by the owner 2026-08-17).
    /// **Deliberately no default value**: omitting it must be a compile error, the same existing rule as `scale` / `hoverStyle`.
    func chipQuietHoverScale(_ isActive: Bool, cardWidth: CGFloat, scale: CGFloat) -> some View {
        let target = ChipPillMetrics.quietHoverScale(forCardWidth: cardWidth, scale: scale)
        return self
            .scaleEffect(isActive ? target : 1, anchor: .bottom)
            .animation(.easeOut(duration: 0.12), value: isActive)
    }

    /// Add background saturation boost to the frosted-glass panel. **At 1.0 the whole modifier isn't attached** -- `.saturation(1.0)` is an identity,
    /// but it can still trigger offscreen rendering, and one extra layer could break the pixel-exact freeze of dark mode (same reasoning as the thickness layer).
    @ViewBuilder
    func dockBackdropSaturation(_ amount: Double) -> some View {
        if amount == 1.0 { self } else { self.saturation(amount) }
    }

    /// Apply a `DockShadow` (x is always 0). **Never drawn when snapshotting the drag copy** (reason and measurements in
    /// `EnvironmentValues.isDragCarrierSnapshot`).
    ///
    /// Note there is **no icon drop shadow path anymore**: icons / shelf / folder covers carry no outer shadow
    ///(owner 2026-08-19, matching the native Dock). The remaining users are the panel, popups, bubbles, and text glow.
    func dockShadow(_ shadow: DockShadow) -> some View {
        modifier(DockShadowModifier(shadow: shadow))
    }

    /// `visible == false` attaches nothing at all — a zero-alpha `.shadow` is still a filter.
    @ViewBuilder
    func dockShadow(_ shadow: DockShadow, visible: Bool) -> some View {
        if visible { dockShadow(shadow) } else { self }
    }

    /// Conditional glow: when `active` is false, both radius and opacity go to zero (equivalent to not drawing).
    /// The glow is outside the scope of "don't bake shadows": it is part of the card itself (it should follow along during the drag), not a drop shadow to be handed off at landing.
    func dockGlow(_ tint: DockTint, radius: CGFloat, active: Bool) -> some View {
        self.shadow(color: tint.color(active: active), radius: active ? radius : 0)
    }
}

struct ChipPillUsesGlassKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Whether title pills may be drawn as system glass. Set only by the taskbar, from its panel's
    /// `usesLiquidGlass`. The default is the safe side on purpose: a drag-carrier bitmap is rendered
    /// off-window, where a glass effect captures as nothing, so it must get the flat pill.
    var chipPillUsesGlass: Bool {
        get { self[ChipPillUsesGlassKey.self] }
        set { self[ChipPillUsesGlassKey.self] = newValue }
    }
}

struct DragCarrierSnapshotKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Whether this view tree is currently being captured as the bitmap of a drag copy.
    ///
    /// The captured bitmap differs from the card on screen in **two deliberate ways**, both controlled by it:
    /// - **Don't draw the running dot**: in the native Dock, the dot disappears when you pick up an icon with a dot and returns on drop (owner 2026-08-19).
    /// - **Don't bake any `dockShadow`**: currently no card still draws `dockShadow` (the icon drop shadow and folder-name glow
    ///   have both been removed); this stays to guard against later re-additions: `cacheDisplay` captures SwiftUI's `.shadow` at only about a quarter
    ///   of its strength -- measured: a 0.6 shadow on the same white board captured only alpha 23 (`ImageRenderer` gets 99 on the same one) -- baking it in
    ///   would produce a shadow far fainter than the one on the card, leaving a step at the landing handoff, which is worse than not drawing it at all.
    var isDragCarrierSnapshot: Bool {
        get { self[DragCarrierSnapshotKey.self] }
        set { self[DragCarrierSnapshotKey.self] = newValue }
    }
}

/// The implementation body of `dockShadow`. Made a `ViewModifier` only so it can read the environment -- an extension method on `View` can't read it.
private struct DockShadowModifier: ViewModifier {
    let shadow: DockShadow
    @Environment(\.isDragCarrierSnapshot) private var isSnapshot

    func body(content: Content) -> some View {
        if isSnapshot {
            content
        } else {
            content.shadow(color: shadow.tint.color, radius: shadow.radius, x: 0, y: shadow.y)
        }
    }
}
