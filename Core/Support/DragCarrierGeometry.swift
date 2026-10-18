import CoreGraphics

/// Coordinate conversion for the carrier layer (pure decision logic).
///
/// There are **three** coordinate systems here at once, and mixing them makes the icon fly toward the other end of the screen, an error that in eyeball acceptance
/// would only be described as "the animation feels off". So it is split out and pinned down:
///
/// | Coordinate system | Origin | y direction | Who uses it |
/// |---|---|---|---|
/// | Screen | main screen bottom-left | up | `NSEvent.mouseLocation`, each panel's frame, `sourceScreenRect` |
/// | Inside the carrier panel | panel frame bottom-left | up | `CALayer.position` (the host view is non-flipped) |
/// | `"strip"` / `"drawer"` | panel content top-left | **down** | `grabOffset`, the start and end points of `DragLandingPlan` |
enum DragCarrierGeometry {
    /// **The carrier panel covers only one screen at a time**: the one containing `point`; if none contains it, take the first (when the panel hasn't been built yet
    /// the caller treats it as `.zero`).
    ///
    /// The reason for not covering the "union of all screens" (stepped on 2026-08-19): macOS defaults to "Displays have separate Spaces", so a
    /// window belongs to only one display, and the part extending beyond that screen is **not drawn at all**. A union window gets assigned by the system to the larger screen,
    /// and when the taskbar was on the other screen the carrier didn't show on screen for the whole drag, which was the owner's "icon disappears when dragging on the built-in display"
    /// (the external 5K display is larger, so everything worked there). Cross-screen dragging was changed to "when the pointer enters another screen, move the panel over".
    static func screenFrame(containing point: CGPoint, in frames: [CGRect]) -> CGRect {
        frames.first { $0.contains(point) } ?? frames.first ?? .zero
    }

    /// Move a center point to the nearest position where "the layer's bottom-left corner lands on whole device pixels".
    ///
    /// The premise for the bitmap being pixel-identical to the card on the strip is that it isn't resampled: layer size = bitmap pixels / scale
    /// (which is how `CarrierSnapshot.size` is computed), plus aligning the origin to the pixel grid, and CA moves pixels 1:1.
    /// If the landing endpoint sat on a half pixel, the last frame would be a slightly blurry image, and the moment the card reappears it would "suddenly sharpen"
    /// (a flaw the owner reported 2026-08-19).
    static func pixelAligned(center: CGPoint, size: CGSize, scale: CGFloat) -> CGPoint {
        guard scale > 0 else { return center }
        let originX = (center.x - size.width / 2) * scale
        let originY = (center.y - size.height / 2) * scale
        return CGPoint(x: originX.rounded() / scale + size.width / 2,
                       y: originY.rounded() / scale + size.height / 2)
    }

    /// Screen point (bottom-left origin) -> AppKit point inside the carrier panel (bottom-left origin).
    static func panelPoint(screen point: CGPoint, panelFrame: CGRect) -> CGPoint {
        CGPoint(x: point.x - panelFrame.minX, y: point.y - panelFrame.minY)
    }

    /// Center of a screen rect -> AppKit point inside the carrier panel. At drag start the carrier is placed here (the slot's original position).
    static func panelCenter(ofScreenRect rect: CGRect, panelFrame: CGRect) -> CGPoint {
        panelPoint(screen: CGPoint(x: rect.midX, y: rect.midY), panelFrame: panelFrame)
    }

    /// Where the carrier should be when "held in hand": pointer + grab offset.
    ///
    /// `grabOffset` is measured in spaces like `"strip"` / `"drawer"` where **y points down**
    /// (`frame.midY - value.startLocation.y`), so the vertical component must have its sign flipped.
    static func carriedCenter(pointer: CGPoint, grabOffset: CGSize, panelFrame: CGRect) -> CGPoint {
        CGPoint(x: pointer.x - panelFrame.minX + grabOffset.width,
                y: pointer.y - panelFrame.minY - grabOffset.height)
    }

    /// The inverse of `carriedCenter`: given the carrier's current center (bottom-left origin inside the panel) and the pointer, derive `grabOffset`,
    /// used when re-grabbed mid-landing-flight (`DragController.regrabLanding`), so dragging continues from the icon's current position
    /// without a jump. The vertical sign-flip trap is the same as in `carriedCenter`: unit tests lock the round trip closed.
    static func grabOffset(pointer: CGPoint, carriedCenter: CGPoint, panelFrame: CGRect) -> CGSize {
        CGSize(width: carriedCenter.x - (pointer.x - panelFrame.minX),
               height: (pointer.y - panelFrame.minY) - carriedCenter.y)
    }

    /// The point computed by `DragLandingPlan` is "top-left origin inside the panel, y down"; flip it to AppKit's bottom-left origin.
    static func panelPoint(fromTopLeft point: CGPoint, panelFrame: CGRect) -> CGPoint {
        CGPoint(x: point.x, y: panelFrame.height - point.y)
    }

    /// The reverse: current carrier center -> "top-left origin inside the panel, y down", feeding the start point of `DragLandingPlan.flight`.
    static func topLeftCarriedCenter(pointer: CGPoint, grabOffset: CGSize, panelFrame: CGRect) -> CGPoint {
        CGPoint(x: pointer.x - panelFrame.minX + grabOffset.width,
                y: panelFrame.maxY - pointer.y + grabOffset.height)
    }

    // MARK: - Pose at the moment of drag start

    /// What the carrier should look like when it appears at the slot's original position: how much overall scale, and how much higher the visual center is than the slot center.
    ///
    /// **The carrier's first frame must pixel-for-pixel coincide with the slot's rendering at that moment.** A real-device drag is always "hover first, then press, then drag",
    /// and at the moment the drag starts the card in the slot isn't at rest: in the quiet level hover enlarges anchored at the **bottom edge** (`chipQuietHoverScale`),
    /// and press then shrinks to 0.93 anchored at the **center** (`chipPressScale`). If the carrier were placed at the slot center at the resting-state 0.93,
    /// during those one or two overlapping frames the two icons would differ in size by ten percent and be offset up and down by two or three pt; the owner's 2026-08-19 report of
    /// "ghosting up and down" was exactly this (the first bitmap carrier matched only the press, not the hover).
    struct PickUpPose: Equatable {
        /// Overall scale relative to the slot's resting size.
        let scale: CGFloat
        /// How much **higher** the visual center is than the slot center (pt, positive = up). The stretch that bottom-anchored enlargement pushes the center of mass up by.
        let dy: CGFloat

        static let resting = PickUpPose(scale: 1, dy: 0)
    }

    /// - Parameters:
    ///   - chipHeight: the slot's layout height (the hover-enlarge anchor is at its bottom edge, the press-scale anchor at its center).
    ///   - pressedScale: the factor the card is currently pressed down to; `nil` = no press (folder chips have no press feedback).
    ///   - hoverScale: the factor the card is currently enlarged to with bottom anchoring; `nil` = no enlargement (standard level / not hovered).
    ///
    /// Derivation: bottom-anchored enlargement s_h raises the center by (s_h - 1)*h/2; then the press s_p about the layout center multiplies this
    /// displacement by s_p as well. Both are uniform scalings on the vertical center line, so the composition is still "uniform scaling about the center + vertical translation",
    /// which a `CALayer` transform + position can reproduce exactly.
    static func pickUpPose(chipHeight: CGFloat,
                           pressedScale: CGFloat?,
                           hoverScale: CGFloat?) -> PickUpPose {
        let hover = max(0, hoverScale ?? 1)
        let press = max(0, pressedScale ?? 1)
        let dy = (hover - 1) * chipHeight / 2 * press
        return PickUpPose(scale: hover * press, dy: dy)
    }
}
