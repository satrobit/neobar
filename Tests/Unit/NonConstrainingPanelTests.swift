import AppKit
import XCTest

@MainActor
final class NonConstrainingPanelTests: XCTestCase {
    private func makePanel() -> NonConstrainingPanel {
        let panel = NonConstrainingPanel(contentRect: NSRect(x: 300, y: 200, width: 500, height: 60),
                                         styleMask: [.borderless, .nonactivatingPanel],
                                         backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
        return panel
    }

    func testAccessibilityPositionAndSizeAreNotSettable() {
        let panel = makePanel()
        XCTAssertFalse(panel.accessibilityIsAttributeSettable(.position))
        XCTAssertFalse(panel.accessibilityIsAttributeSettable(.size))
    }

    func testAccessibilityPositionAndSizeWritesLeaveTheFrameAlone() {
        let panel = makePanel()
        let frame = panel.frame
        panel.accessibilitySetValue(NSValue(point: NSPoint(x: 10, y: 10)), forAttribute: .position)
        panel.accessibilitySetValue(NSValue(size: NSSize(width: 10, height: 10)), forAttribute: .size)
        XCTAssertEqual(panel.frame, frame)
    }

    func testFrameIsNotConstrainedToTheScreen() {
        let panel = makePanel()
        let offscreen = NSRect(x: -5000, y: -5000, width: 500, height: 60)
        XCTAssertEqual(panel.constrainFrameRect(offscreen, to: NSScreen.main), offscreen)
    }
}
