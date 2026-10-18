import CoreGraphics
import Foundation

/// **Pure decision layer** for whether to pop up the NeoBar menu when right-clicking the task strip's backing plate.
///
/// It recognizes only two places (decided by the owner 2026-08-03):
/// - **Blank space at both ends**: the inset margin to the left of the leftmost chip and to the right of the rightmost chip;
/// - **Around the zone divider**: the wide gap where the divider sits.
///
/// It deliberately **does not recognize the narrow gaps between chips**: when a user aims at an icon and misses by a few pt into the gap, popping up the NeoBar menu
/// (rather than that app's own menu) is worse than popping up nothing. The cost is that right-clicking a narrow gap does nothing at all; this is a known trade-off.
///
/// The two kinds of gap are told apart by width: the gap on both sides of the divider is
/// `2 (HStack spacing) + 9 (1pt hairline + 4pt inner padding on each side) + 2 (HStack spacing) = 13pt` (`dividerGapWidth`),
/// whereas ordinary chip spacing is only `2pt`; the threshold just needs to lie between the two, and scales with the tier.
///
/// **The threshold must lie strictly between the two; changing `Style.chipSpacing` requires changing it in step.**
/// On 2026-08-16, when icon spacing was aligned to the native Dock (center spacing 52->42pt, `chipSpacing` 8->2),
/// the divider gap shrank from 21pt to 9pt while the threshold was still 12pt -- which made even the divider gap unrecognizable,
/// so right-click on the whole task strip stopped working entirely.
enum StripContextMenuZone {
    /// Medium-tier baseline. Callers pass `defaultMinimumGapWidth * scale`.
    /// 5pt: larger than the ordinary gap of 2pt, smaller than the divider gap of 13pt.
    static let defaultMinimumGapWidth: CGFloat = 5

    /// Both `point` and `chipFrames` are in the "strip" coordinate space (top-left origin, y down).
    static func claims(
        point: CGPoint,
        chipFrames: [CGRect],
        bounds: CGRect,
        minimumGapWidth: CGFloat
    ) -> Bool {
        guard bounds.contains(point) else { return false }
        // When not a single chip has been measured yet (first frame), do not recognize: better that this one right-click does nothing
        // than to steal that app's menu when the click was "actually on an icon".
        guard !chipFrames.isEmpty else { return false }
        guard !chipFrames.contains(where: { $0.contains(point) }) else { return false }

        let sorted = chipFrames.sorted { $0.minX < $1.minX }
        guard let first = sorted.first, let last = sorted.last else { return false }

        // Blank space at both ends.
        if point.x < first.minX || point.x > last.maxX { return true }

        // In the middle: recognize only points that fall into "a gap wide enough". Use the running maximum of maxX rather than the previous chip's maxX:
        // frames may overlap (frames expanded outward in the messaging zone, temporary positions during a drag), and comparing one by one keeps overlaps from being counted as gaps.
        var gapStart = first.maxX
        for frame in sorted.dropFirst() {
            if point.x < frame.minX {
                let width = frame.minX - gapStart
                return width >= minimumGapWidth && point.x >= gapStart
            }
            gapStart = max(gapStart, frame.maxX)
        }
        return false
    }

    /// Native-tier width of the gap around a zone divider, chip edge to chip edge: the 1pt
    /// hairline, its side padding and one `chipSpacing` each side. `DockStripView` derives the
    /// divider's padding from it.
    static let dividerGapWidth: CGFloat = 13

    /// Native-tier clearance the drag-to-resize grip keeps from every chip. Callers pass
    /// `defaultGripChipClearance * scale`. 2.5pt leaves an 8pt band in the divider gap: the ▲▼
    /// cursor is 9pt wide and does not scale, so at the band's edge it stays ~2pt short of the
    /// icon artwork. Must stay below half the divider gap, or the grip disappears there.
    static let defaultGripChipClearance: CGFloat = 2.5

    /// The drag-to-resize grip: the right-click zones minus `chipClearance` on each side of
    /// every chip (x only — the gap test above is x only too). The right-click zone itself
    /// stays the full gap.
    ///
    /// The end insets are the grip's **fallback only**: while any divider gap exists the grip
    /// lives there alone, and the ends take over when the bar has a single zone and therefore
    /// no divider. Right-click keeps the ends either way.
    static func gripClaims(
        point: CGPoint,
        chipFrames: [CGRect],
        bounds: CGRect,
        minimumGapWidth: CGFloat,
        chipClearance: CGFloat
    ) -> Bool {
        guard claims(point: point, chipFrames: chipFrames, bounds: bounds,
                     minimumGapWidth: minimumGapWidth) else { return false }
        guard !chipFrames.contains(where: {
            point.x > $0.minX - chipClearance && point.x < $0.maxX + chipClearance
        }) else { return false }
        let isEndInset = !chipFrames.contains { $0.minX <= point.x }
            || !chipFrames.contains { $0.maxX >= point.x }
        return !isEndInset || !hasDividerGap(chipFrames: chipFrames, minimumGapWidth: minimumGapWidth)
    }

    /// Whether any chip-to-chip gap is wide enough to be a zone divider's — the same running-max
    /// walk as `claims`, so an overlap never reads as a gap.
    static func hasDividerGap(chipFrames: [CGRect], minimumGapWidth: CGFloat) -> Bool {
        let sorted = chipFrames.sorted { $0.minX < $1.minX }
        guard var gapStart = sorted.first?.maxX else { return false }
        for frame in sorted.dropFirst() {
            if frame.minX - gapStart >= minimumGapWidth { return true }
            gapStart = max(gapStart, frame.maxX)
        }
        return false
    }
}
