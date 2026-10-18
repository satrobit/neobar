import CoreGraphics
import Foundation

/// Cross-display window drag (multi-display ③④): drag a window icon from one display's taskbar onto another display's taskbar, and the window moves to that display.
/// Pure geometry: size is unchanged (shrunk to the usable area if larger than the target display's usable area); position = the same offset from the top-left of the **source display's usable area**,
/// clamped into the target display's usable area; unknown source → centered in the target usable area. All in Quartz coordinates (top-left origin).
enum WindowDisplayMove {
    static func targetFrame(window: CGRect,
                            from source: WindowDisplayAttribution.Display?,
                            to target: WindowDisplayAttribution.Display) -> CGRect {
        let area = target.visibleCGFrame
        let width = min(window.width, area.width)
        let height = min(window.height, area.height)
        var origin: CGPoint
        if let source {
            let offset = CGPoint(x: window.minX - source.visibleCGFrame.minX,
                                 y: window.minY - source.visibleCGFrame.minY)
            origin = CGPoint(x: area.minX + offset.x, y: area.minY + offset.y)
        } else {
            origin = CGPoint(x: area.midX - width / 2, y: area.midY - height / 2)
        }
        origin.x = min(max(origin.x, area.minX), area.maxX - width)
        origin.y = min(max(origin.y, area.minY), area.maxY - height)
        // Only the origin is rounded; the size is kept as is (`.integral` would grow the size by 1pt at half-pixel positions).
        return CGRect(x: origin.x.rounded(), y: origin.y.rounded(), width: width, height: height)
    }

    /// Whether the window move succeeded: look at **which display** the read-back frame belongs to and whether it is the target display, not at how many pt it differs from the requested frame. When moving across displays, AppKit
    /// often corrects the frame by a few pt on its own (menu bar / usable-area constraints, differing scale between the two displays); judging failure by ±2pt would move a window that was already moved
    /// back again (owner 2026-09-03: "the window gets to B, flashes, then the window and its card both go back to A").
    static func landedOnTarget(actual: CGRect, target: String, table: WindowDisplayAttribution.Table) -> Bool {
        WindowDisplayAttribution.displayUUID(for: actual, table: table) == target
    }
}
