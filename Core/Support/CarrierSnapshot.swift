import CoreGraphics

/// The **bitmap** of the floating copy held during a drag.
///
/// Since 2026-08-18 the carrier is no longer a standalone SwiftUI tree but an image captured at the instant the drag starts
/// (see `ChipSnapshotter`). The reason is structural: the card on the strip and the carrier used to belong to two unsynchronized renderers,
/// and both drag start and landing needed a "who shows, who hides" handoff, yet only SwiftUI itself knows when each side actually hits the screen —
/// every handoff was a race: overlap if you won, a gap if you lost. Four rounds of flag patches (`carrierReady` / `onAppear`
/// reporting / fallback timer / early fade-out) all just added referees to the race and never converged. With a bitmap, every pixel of the carrier
/// is decided synchronously by `DragController` in the same run-loop turn that receives the mouse event, so the handoff no longer exists.
struct CarrierSnapshot {
    /// The bitmap itself. Pixel size = `size × scale`.
    let image: CGImage
    /// Logical size (pt), **including bleed** — the carrier layer's `bounds` is exactly this.
    /// See `ChipSnapshotter.bleed` for the reason for the bleed: the icon drop shadow inside the card overflows the layout frame,
    /// and cropping to the layout frame would cut that shadow off, so on landing it would not match the card on the strip.
    let size: CGSize
    /// The slot's own size (pt, excluding bleed). Used for diagnostics only: if it does not match the size of the `sourceScreenRect`
    /// reported at drag start, the snapshot was not drawn from the same view as the slot.
    let contentSize: CGSize
    /// The backing scale used when rendering. The carrier layer's `contentsScale` takes it, otherwise it would look blurry on Retina.
    let scale: CGFloat
}
