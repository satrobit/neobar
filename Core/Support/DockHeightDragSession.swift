import CoreGraphics

/// One vertical drag on a taskbar grip (the bar's end insets or a zone divider gap), from
/// mouse-down to mouse-up. Pointer up = taller, matching the native Dock's divider drag.
///
/// Coordinates are **screen** y (AppKit, bottom-left origin): the panel grows and re-centres
/// on every tick, so window-local coordinates drift mid-drag. The formula is stateless on
/// purpose: past the clamp the pointer has to come back to the clamp point before the bar
/// shrinks again, which is how the native divider behaves.
struct DockHeightDragSession: Equatable {
    let startHeight: CGFloat
    let startPointerY: CGFloat

    init(startHeight: CGFloat, startPointerY: CGFloat) {
        self.startHeight = startHeight
        self.startPointerY = startPointerY
    }

    func height(forPointerY pointerY: CGFloat) -> DockPanelHeight {
        DockPanelHeight(clamping: startHeight + (pointerY - startPointerY))
    }
}
