import AppKit
import SwiftUI

/// The ▲▼ "cursor" drawn while the pointer is over a taskbar grip zone or dragging the bar's
/// height. It is a real view in its own tiny panel, not an `NSCursor`: a background app cannot
/// change the system cursor, but it can hide it (`SystemCursorHider`) and draw its own glyph
/// under the pointer. Use the system frame-resize artwork, including its padding and hotspot.
@MainActor
struct ResizeCursorGlyph: View {
    private static let cursor: NSCursor = {
        if #available(macOS 15.0, *) {
            return .frameResize(position: .top, directions: .all)
        }
        // The public frame-resize cursor arrived in macOS 15. Older systems use the same
        // two-triangle silhouette rather than resizeUpDown, which adds a horizontal bar.
        let size = NSSize(width: 18, height: 28)
        let image = NSImage(size: size, flipped: false) { _ in
            for direction: CGFloat in [-1, 1] {
                let path = NSBezierPath()
                path.move(to: NSPoint(x: 9, y: 14 + direction * 11))
                path.line(to: NSPoint(x: 3.5, y: 14 + direction * 3.5))
                path.line(to: NSPoint(x: 14.5, y: 14 + direction * 3.5))
                path.close()
                path.lineWidth = 2
                path.lineJoinStyle = .round
                NSColor.white.setStroke()
                path.stroke()
                NSColor.black.setFill()
                path.fill()
            }
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: 9, y: 14))
    }()

    static var size: CGSize { cursor.image.size }
    static var hotSpot: CGPoint { cursor.hotSpot }
    static var image: NSImage { cursor.image }

    var body: some View {
        Image(nsImage: Self.image)
            .frame(width: Self.size.width, height: Self.size.height)
    }
}
