import CoreGraphics

/// Pointer position -> which chip should own hover.
///
/// **Why the strip no longer has each card attach its own `.onHover`.** That would mean each card owns an `NSTrackingArea`,
/// with hover relying on the system dispatching "enter / exit" in pairs. Once the pointer gets fast, macOS coalesces mouse-move events, and the enter/exit
/// pairs of the cards in between are dropped entirely -- those cards never learn the pointer came by. Measured (2026-08-17, a fixed 120Hz synthetic event sweep across
/// a row of 10 cards): 800pt/s hits 9 cards, 1600pt/s hits 6, 2400pt/s only 3, and rerunning the same speed
/// can drop from 9 to 5. In the same round of controlled experiments, turning off liquid glass (which makes placing one tooltip cost half as much) produced no
/// systematic change in the hit count, so **the bottleneck is not rendering but events**. This is the owner's report that "the native tooltip keeps up when swiping across quickly,
/// NeoBar does not".
///
/// Incidentally, the same root cause explains the "unstable boundary": between two cards' hit rectangles lies a `chipSpacing` dead zone,
/// and the pointer must **fully enter** the next card before it takes over, so the switch point depends on direction -- moving right it sits right of the geometric midpoint, moving left it sits left,
/// with a measured hysteresis of 3.5pt (owner 2026-08-17).
///
/// **The native Dock does not do it this way**: the whole strip is one block, and each mouse event looks up which tile it lands on by position.
/// This type is that lookup. A pure function whose boundary is determined only by geometry, independent of direction of approach; the tracking area that calls it covers
/// the entire strip, so it recomputes on every pointer move and does not depend on paired events.
///
/// Note this is **not** the resident global `.mouseMoved` monitor banned by AGENTS "Menus, Panels, And Screens":
/// what that bans is `NSEvent.addGlobalMonitorForEvents` (an event tap: system-wide mouse events pass through our process first,
/// and it slows by 100ms when we pop up our own menu). This is an ordinary tracking area **inside our own window**, a different thing.
enum StripHoverResolution {
    /// In the gap between cards, expand the hit region outward by at most this much (pt, before the tier multiplier).
    ///
    /// Why 2pt: the card spacing itself is `ChipPillMetrics.chipSpacing` (2pt), and expanding 2pt on each side
    /// overlaps exactly in the middle of the gap, so there is no dead zone in the gap and the boundary falls right at the **midpoint of the two cards**, regardless of direction of approach.
    /// As for the 13pt-wide gap at the section divider, after expanding 2 on each side 9pt is still left empty in the middle, so hovering the divider still
    /// pops nothing (native behaves the same); the margins at both ends of the strip are likewise.
    static let defaultGapBridge: CGFloat = 2

    /// Ownership determination.
    ///
    /// - Parameters:
    ///   - point: the pointer, in the same coordinate system as `frames` (the `"strip"` space inside the strip).
    ///   - frames: all chip frames taking part in the determination (all four sections), keyed by chip identity.
    ///   - gapBridge: the gap bridging amount, already multiplied by the tier.
    /// - Returns: the identity of the chip hit; in the wide divider gap / margins at the strip ends / outside the strip -> `nil`.
    ///
    /// Within a gap, the ruling goes to the nearer by **distance to the card edge**, not by distance to the card center: when cards of different widths sit side by side,
    /// going by center would let the narrow card eat an extra piece, while going by edge gives the exact middle of the gap.
    static func chip(at point: CGPoint,
                     frames: [String: CGRect],
                     gapBridge: CGFloat = defaultGapBridge) -> String? {
        var best: (id: String, distance: CGFloat)?
        for (id, frame) in frames {
            guard frame.width > 0, frame.height > 0 else { continue }
            guard frame.insetBy(dx: -gapBridge, dy: 0).contains(point) else { continue }
            let distance = max(frame.minX - point.x, point.x - frame.maxX, 0)
            guard let current = best else {
                best = (id, distance)
                continue
            }
            // Break ties by id, so the dictionary iteration order does not make the result jump between frames.
            if distance < current.distance || (distance == current.distance && id < current.id) {
                best = (id, distance)
            }
        }
        return best?.id
    }
}

/// Where a chip's hover state comes from. **Deliberately no default value**, same reason as `scale` / `hoverStyle`:
/// forgetting to pass it must be a compile error.
enum ChipHoverInput: Equatable {
    /// Hover state computed externally. The strip uses this: one tracking area for the whole strip + `StripHoverResolution`.
    case resolved(Bool)
    /// The view attaches `.onHover` tracking itself. The drawer panel has no tracking area and uses this.
    case selfTracked
}
