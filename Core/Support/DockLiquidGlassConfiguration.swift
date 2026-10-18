import CoreGraphics
import Foundation

enum DockLiquidGlassRenderPath: Equatable {
    case visualEffectFallback
    case layeredTaskbar
}

/// Tunable parameters for the Liquid Glass backplate.
///
/// **This holds only "how the glass backplate is drawn", not geometry.** Panel height, corner radius, and off-screen bottom distance all come from
/// `DockPanelHeight.metrics` and `DockShape.panelCornerRadius` (`AGENTS.md`: single source of truth for geometry) --
/// if the glass carried a second set of sizes, height scaling would break, because the definition of `scale` is itself `panelHeight / 54`.
///
/// **No shadow here either.** The drop shadow is drawn by the SwiftUI-side `.dockShadow(theme.stripShadow)` inside the content window's
/// 20pt transparent border; we once tried drawing it on the layer of the background window, but that window's frame is exactly equal to the backplate itself,
/// so a layer shadow drawn outside the window gets clipped entirely -- the net effect was no shadow in the glass state. Do not change it back.
struct DockLiquidGlassConfiguration: Equatable {
    let isEnabled: Bool
    /// Gray tint strength of `Glass.clear`. Raw glass is too transparent and icons become unrecognizable (the reason the owner rejected
    /// pure native glass on 2026-07-30); this layer is the main handle for pulling transparency back into a usable range.
    let clearTintOpacity: Double
    /// A layer of white added **beneath** the glass. Default 0.
    let whiteOverlayOpacity: Double
    /// The darken/lighten layer in the background window (black or white depending on light/dark appearance). Default 0.
    ///
    /// **Drawn only once, in the background window.** The content window used to stack a hard-coded black layer too, and the two colors were inconsistent
    /// (always black on the SwiftUI side, switched by appearance on the background window side); at the default 0 it was invisible, but any adjustment exposed it.
    let dimmingOpacity: Double
    /// The **peak** alpha of the edge highlight, appearing at the top-left / bottom-right corners. The whole ring is drawn with it and then pressed down by the mask.
    ///
    /// **It cannot be computed directly as `α = 78/171 ≈ 0.45`**: a 0.5pt stroke on a straight edge lands exactly on a full row of pixels,
    /// while on a rounded corner it is diagonal and thinned out by anti-aliasing, so the same alpha only reaches about 2/3 at the corner. 0.75 was tuned from measurement
    /// (0.45 -> only +52 at the corner, 0.62 -> +64, 0.75 -> +73; combined with the left-side wallpaper raising the backplate baseline by about 8,
    /// it actually lands on the native +76 / +81).
    ///
    /// **This is the most valuable knob for "does it look native".** The native Dock uses this ring to pick the outline out from the background;
    /// without it the bar blurs into the background as if painted directly on the screen, and even the corners look squarer than they are
    /// (measured: NeoBar's 16pt corner radius is actually larger than the native 14pt, but looks squarer).
    let borderPeakOpacity: Double
    /// The ratio of the four long edges relative to the peak. The absolute alpha the long edges need is 0.375 (+67 above the backplate),
    /// divided by the peak 0.75 gives 0.5. **Changing the peak must change this in sync**, otherwise the long edges would brighten along with it.
    let borderEdgeLevel: Double
    /// The amount carved out at the top-right / bottom-left corners (applied on `borderEdgeLevel`).
    /// The native highlight line at these two corners is only +5 / +7 above the backplate, essentially nothing.
    let borderCornerCut: Double
    /// Effective radius of the corner modulation, in **multiples of the corner radius** (so it scales with the tier).
    let borderCornerSpread: Double
    /// Stroke width. The outermost line measured on native is 1px @2x = **0.5pt**, much thinner than intuition suggests.
    let borderLineWidth: Double
    /// Draw a darker one right on the **inside** of the outer ring, to make up the native two-pixel bright edge.
    ///
    /// The measured native top-edge profile is `148 -> 120 -> 81 (backplate)`: one full pixel + one half-level, two pixels in all.
    /// Drawing only one line gives the same peak of 148, but **the visual weight is only half, and to the eye it is simply "not as bright as native"**
    /// (owner feedback 2026-08-16; only after measuring did we find the peak had matched all along and the width was what was off).
    /// Working backwards: raising a backplate of 84 to 120 requires `α = (120 - 84) / (255 - 84) ≈ 0.21`.
    let borderInnerOpacity: Double
    /// Opacity of the `.menu` material layer in the background window, used to add a bit of solidity on top of the glass. Default 0.
    let backgroundMaterialOpacity: Double
    /// WindowServer blur radius of the background window (SkyLight). **Default 0 = not used.**
    ///
    /// This value was brought in by copying BestDock's on-device layer hierarchy (6pt on their side). In NeoBar's composition it
    /// **brings only harm**: WindowServer's window background blur applies to the **window rectangle** and doesn't follow the rounded corners we draw,
    /// so at the four corners the area "outside the rounded corner but inside the bounding rectangle" gets blurred into a square, and the blur's spread overflows a further ring --
    /// the owner reported on 2026-08-16 "there's some problem outside the rounded corners", which vanished on the spot after A/B to 0.
    ///
    /// Transparency does **not depend on it**: backplate brightness is determined by `.glassEffect(.clear)` plus `clearTintOpacity`,
    /// and measurement shows blur 6 -> 0 changes the backplate only from 138.4 to 138.5.
    ///
    /// If re-enabled in the future: **the corners must be solved first** -- either give the background window itself a rounded shape
    /// (currently only the content layer is rounded, and the window shape is still a rectangle), or don't use window-level blur.
    /// Also, it **must be drawn on a window separate from the glass host**: setting this value directly on the same window that hosts SwiftUI glass
    /// re-composites the vertical lighting a second time (controlled color-bar measurement: top/bottom average brightness went from about 131/127
    /// to an amplified 101/163).
    let windowBlurRadius: Double
    /// The WindowServer blur radius worth asking for, or nil when it is 0: a 0 radius asks for
    /// nothing, so no SkyLight call is made for it and its outcome can never decide the render path
    /// (the old guard on that call is the suspected cause of the macOS 26.x frosted-plate fallback).
    var requestedWindowBlurRadius: UInt32? {
        guard windowBlurRadius > 0 else { return nil }
        return UInt32(min(windowBlurRadius.rounded(), 64))
    }
    /// The amount the glass shape is first expanded then inset, leaving margin for the glass's own edge rendering.
    let contentInset: Double
    /// Opacity of the black base on the background window's root layer. **Not an appearance parameter**: WindowServer needs a shape with non-zero alpha
    /// before it will apply background blur to this window; this is the minimal anchor for it.
    let backgroundPlateOpacity: Double
    /// Private `NSGlassEffectView` variant the plate is rendered with. **3 is the material the
    /// native Dock itself uses**: plate colour, the backdrop-coloured 1px rim and the dark
    /// "thickness" line on the left all come with it and match the Dock to within ±2.
    ///
    /// `nil` (`DOCK_LIQUID_GLASS_SYSTEM_VARIANT=off`, or the private selector gone) falls back to
    /// the SwiftUI `.glassEffect(.clear)` plate below — every other field in this struct describes
    /// **that fallback only**; the variant plate takes no tint and no hand-drawn rim.
    /// Callers read it through `DockGlassPresentation.activeSystemVariant`, which checks
    /// `TEDockGlassSupportsSystemVariant()` first.
    let systemVariant: Int?

    static let dockSystemVariant = 3

    // The native Dock resolves its material at Size.medium, independently of the bar height.
    // These are optical distances, not panel geometry; do not scale them with the bar.
    static let dockInnerRefractionHeight = 13.28
    static let dockInnerRefractionAmount = -29.88

    // System highlight angles are measured clockwise from the top edge normal.
    static let diagonalKeyAngle = -25 * Double.pi / 180
    static let diagonalFillAngle = Double.pi + diagonalKeyAngle
    // Compensate for the long-edge falloff at the accepted diagonal angle.
    static let boostedHighlightAmount = 0.75

    /// `DockPanelBackdrop`'s legacy 2pt outset + clip would cut off the variant plate's own rim.
    static func backdropOutset(usesLiquidGlass: Bool, usesSystemVariant: Bool) -> CGFloat {
        usesLiquidGlass && usesSystemVariant ? 0 : 2
    }

    /// The native Dock casts no drop shadow; with its material ours reads as a grey slab around
    /// the plate. `stripShadow` only (taskbar + capsule) — popups keep theirs.
    static func stripShadowVisible(usesLiquidGlass: Bool, usesSystemVariant: Bool) -> Bool {
        !(usesLiquidGlass && usesSystemVariant)
    }

    func renderPath(
        isGlassAPIAvailable: Bool,
        isCompositeAvailable: Bool
    ) -> DockLiquidGlassRenderPath {
        guard isEnabled, isGlassAPIAvailable, isCompositeAvailable else {
            return .visualEffectFallback
        }
        return .layeredTaskbar
    }

    static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> Self {
        Self(
            // **On by default** (promoted by the owner 2026-08-17). It used to be "off by default, on only with `DOCK_LIQUID_GLASS=1`",
            // which is how it should be during the exploration phase; keeping it off by default after visual sign-off would only cause "running the wrong instance" --
            // a process auto-launched after a system restart carries no environment variables and would show the old no-glass look (this really happened).
            // `=0` is still the switch to turn it off; the frosted-glass fallback in `renderPath` for macOS 12-25 is unrelated to this.
            isEnabled: trimmed(DebugSwitch.liquidGlass.value(in: environment)) != "0",
            clearTintOpacity: boundedDouble(
                DebugSwitch.liquidGlassClearTint.value(in: environment),
                range: 0 ... 1,
                fallback: 0.4
            ),
            whiteOverlayOpacity: boundedDouble(
                DebugSwitch.liquidGlassWhiteOverlay.value(in: environment),
                range: 0 ... 1,
                fallback: 0
            ),
            dimmingOpacity: boundedDouble(
                DebugSwitch.liquidGlassDimming.value(in: environment),
                range: 0 ... 1,
                fallback: 0
            ),
            borderPeakOpacity: boundedDouble(
                DebugSwitch.liquidGlassBorder.value(in: environment),
                range: 0 ... 1,
                fallback: 0.75
            ),
            borderEdgeLevel: boundedDouble(
                DebugSwitch.liquidGlassBorderEdge.value(in: environment),
                range: 0 ... 1,
                fallback: 0.5
            ),
            borderCornerCut: boundedDouble(
                DebugSwitch.liquidGlassBorderCut.value(in: environment),
                range: 0 ... 1,
                fallback: 0.92
            ),
            borderCornerSpread: boundedDouble(
                DebugSwitch.liquidGlassBorderSpread.value(in: environment),
                range: 0.5 ... 6,
                fallback: 2.2
            ),
            borderLineWidth: boundedDouble(
                DebugSwitch.liquidGlassBorderWidth.value(in: environment),
                range: 0 ... 4,
                fallback: 0.5
            ),
            borderInnerOpacity: boundedDouble(
                DebugSwitch.liquidGlassBorderInner.value(in: environment),
                range: 0 ... 1,
                fallback: 0.21
            ),
            backgroundMaterialOpacity: boundedDouble(
                DebugSwitch.liquidGlassBackgroundOpacity.value(in: environment),
                range: 0 ... 1,
                fallback: 0
            ),
            windowBlurRadius: boundedDouble(
                DebugSwitch.liquidGlassWindowBlur.value(in: environment),
                range: 0 ... 64,
                fallback: 0
            ),
            contentInset: boundedDouble(
                DebugSwitch.liquidGlassContentInset.value(in: environment),
                range: 0 ... 12,
                fallback: 4
            ),
            backgroundPlateOpacity: 0.001,
            systemVariant: systemVariant(DebugSwitch.liquidGlassSystemVariant.value(in: environment))
        )
    }

    private static func systemVariant(_ raw: String?) -> Int? {
        guard let raw = trimmed(raw) else { return dockSystemVariant }
        if raw == "off" { return nil }
        guard let value = Int(raw), (0 ... 40).contains(value) else { return dockSystemVariant }
        return value
    }

    private static func boundedDouble(
        _ raw: String?,
        range: ClosedRange<Double>,
        fallback: Double
    ) -> Double {
        guard let raw = trimmed(raw),
              let value = Double(raw),
              value.isFinite,
              range.contains(value) else { return fallback }
        return value
    }

    private static func trimmed(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}

enum DockLiquidGlassPanelGeometry {
    /// The background window's frame = the **visible backplate rectangle** of the content window with the 20pt shadow transparent border removed.
    ///
    /// The content window keeps the transparent border (the shadow lives there, and a batch of drop-zone / hit-test logic converts via "window frame minus
    /// shadowPadding"), whereas the background window must fit the backplate flush, otherwise WindowServer's blur
    /// would leak out from the edge of the glass.
    static func backgroundFrame(
        for contentPanelFrame: CGRect,
        shadowPadding: CGFloat
    ) -> CGRect {
        guard shadowPadding > 0 else { return contentPanelFrame }
        return contentPanelFrame.insetBy(dx: shadowPadding, dy: shadowPadding)
    }
}

enum DockLiquidGlassPanelRole: Equatable {
    case background
    case content
}

enum DockLiquidGlassPanelLifecyclePlan {
    static func ordering(
        isCompositeActive: Bool,
        shouldShow: Bool
    ) -> [DockLiquidGlassPanelRole] {
        guard isCompositeActive else { return [.content] }
        return shouldShow ? [.background, .content] : [.content, .background]
    }
}
