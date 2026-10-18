import CoreGraphics

/// When a drawer icon is dragged into the taskbar, whether this whole block should land to the left or right of which live card (pure decision logic).
///
/// **Look only at x, and always produce an answer** (as long as the live area has cards). Both points were forced out by measurement
/// (2026-08-18, `DOCK_HOVER_TRACE` drag logs):
///
/// - The promotion hit frame is deliberately placed **16pt beyond the strip's top edge**, so the user sees a reaction earlier when dragging down from the drawer.
///   But the original landing check used a whole-frame `contains`, which **never hits** in that 16pt outside the strip,
///   so the first landing degraded 100% of the time into "the whole block lands at the end of the live area".
/// - Afterwards, every cursor move is judged again, but when the cursor sits in the 2pt gap between two cards,
///   or over the messaging area / folder area, it likewise doesn't hit -> at that moment the whole block **stays where it is**.
///
/// Together, what the user sees is "the gap opens at a fixed position unrelated to the finger, and doesn't move however you move",
/// which is what the owner meant by "hard to trigger the animation that pushes other icons away".
///
/// The criterion is **nearest distance to the card center** (not to the card edge): what we want here is "between which two cards to insert",
/// and the card center is exactly the boundary between two adjacent insertion slots. `StripHoverResolution` uses nearest-to-edge,
/// because it answers a different question (which card the pointer is **on**); the two aren't interchangeable.
enum StripBlockLanding {
    /// - Parameter frames: frames of the live-area candidate cards (with the dragged block already excluded). Order doesn't matter.
    /// - Returns: `nil` appears only when the candidates are empty (the live area really has no other card).
    static func target(pointerX: CGFloat, frames: [String: CGRect]) -> (id: String, after: Bool)? {
        var best: (id: String, distance: CGFloat, after: Bool)?
        for (id, frame) in frames {
            guard frame.width > 0, frame.height > 0 else { continue }
            let distance = abs(pointerX - frame.midX)
            let after = pointerX > frame.midX
            guard let current = best else { best = (id, distance, after); continue }
            // On equal distance, break the tie by id so the decision is deterministic (dictionary iteration order is undefined).
            if distance < current.distance || (distance == current.distance && id < current.id) {
                best = (id, distance, after)
            }
        }
        guard let best else { return nil }
        return (best.id, best.after)
    }
}
