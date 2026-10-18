import CoreGraphics

/// The **pure decision layer** for the panel stroke: how wide each of the two edge layers (glass specular edge / theme stroke) is drawn at a given moment.
///
/// It exists because of a real regression (2026-08-20 the owner reported "dragging an icon from the drawer to the task strip puts a black border around the whole strip"):
/// the drop highlight was written to **remove the glass bright edge from the view tree entirely and swap in the theme stroke**. Before glass became the default
/// the theme stroke merely darkened the "white 0.6 -> black 0.1" gradient edge by one notch, which didn't look jarring; once glass became the default, the usual ring is
/// the white specular edge measured against the native Dock (peak 0.75), so the same code turned into "bright white edge -> pure black edge".
///
/// The current rule: **the glass bright edge is always drawn; the highlight is laid on top, not swapped in for it.**
enum DockPanelRimPlan {
    /// Whether the glass specular edge (`DockGlassRim`) is drawn. It depends only on whether the glass path is taken, regardless of highlight.
    /// The system variant plate draws its own rim; a hand-drawn one on top would double it.
    static func glassRimVisible(usesLiquidGlass: Bool, usesSystemVariant: Bool) -> Bool {
        usesLiquidGlass && !usesSystemVariant
    }

    /// Line width of the theme stroke.
    ///
    /// - Frosted path (macOS 12-25): it **is** that ring, drawn both normally and when highlighted.
    /// - Glass path: normally left to `DockGlassRim`, with the theme stroke at width 0 (the equivalent of not being in the view tree);
    ///   it appears only when highlighted. The width grows from 0 to `lineWidth`, so the 0.15s fade-in is achieved by line-width interpolation,
    ///   and the hard `AnyShapeStyle` cut between the highlight color and the usual gradient happens while the width is still 0, so it can't be seen.
    static func themeStrokeWidth(usesLiquidGlass: Bool,
                                 highlighted: Bool,
                                 lineWidth: CGFloat) -> CGFloat {
        guard usesLiquidGlass else { return lineWidth }
        return highlighted ? lineWidth : 0
    }
}
