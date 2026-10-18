import CoreGraphics

/// Drop-point classification when a pinned-folder chip drag is released (pure function, unit-tested).
///
/// Coordinate system: the caller first converts `DragController.globalLocation` (screen coordinates) via `stripPoint(from:)`
/// into a "strip" local-coordinate point, then passes it to `classify`. `stripVisibleRect` is the visible area of the taskbar content
///(in "strip" local coordinates it is simply `(0,0)`-`stripRootScreenRect.size`, naturally excluding the transparent shadowPadding edge,
/// so no extra conversion is needed). `folderZoneMinX` is the left boundary of the pinned-folder zone (folder chips) in the same coordinate system:
/// the zone runs from there to the bar's right end (the Trash, when shown, is its last cell), and
/// everything left of it is the window zone and the pinned-app zone (shelf included).
/// No buffer is added at the boundary -- the owner's feedback explicitly required "hit range computed from the visible area, no large buffer zone".
enum FolderChipDropZone: Equatable {
    /// Still inside the pinned zone: in-zone reordering was already committed live during the drag, so there is no extra action on release.
    case folderZone
    /// Dropped in the taskbar window zone: unpin + open that folder's real Finder window (the caller's responsibility, not this type's).
    case liveZone
    /// Dropped outside the taskbar's visible range: remove the pin.
    case outsideStrip

    /// The zone's left edge while a folder chip is dragged. `nil` = not measured yet (install no
    /// geometry; the drop falls back to `.folderZone`, a no-op). An empty frame table is **not**
    /// always "not measured": once the only pinned folder leaves the bar its slot collapses and
    /// its frame is gone, and treating that as unmeasured turns the drag-out into a no-op. The
    /// zone is then the Trash alone, or nothing at all — the bar's right edge.
    static func zoneMinX(folderMinX: CGFloat?, draggedSlotCollapsed: Bool,
                         trashMinX: CGFloat?, stripWidth: CGFloat) -> CGFloat? {
        if let folderMinX { return folderMinX }
        guard draggedSlotCollapsed else { return nil }
        return trashMinX ?? stripWidth
    }

    static func classify(point: CGPoint, stripVisibleRect: CGRect, folderZoneMinX: CGFloat) -> FolderChipDropZone {
        guard stripVisibleRect.contains(point) else { return .outsideStrip }
        // A folder chip released over the Trash is a no-op: the Trash is inside this range.
        return point.x >= folderZoneMinX ? .folderZone : .liveZone
    }
}

/// Screen-coordinate geometry snapshot for a pinned-folder drag.
///
/// `DragController`'s final mouseUp coordinate is in screen coordinates; this wraps it as a pure conversion, so the final settle doesn't depend again on
/// SwiftUI gesture callbacks. `stripScreenRect` is the screen frame of the taskbar's visible content area, excluding shadowPadding.
struct FolderChipDropGeometry: Equatable {
    let stripScreenRect: CGRect
    let folderZoneMinX: CGFloat

    func classify(screenPoint: CGPoint) -> FolderChipDropZone {
        guard stripScreenRect != .zero else { return .outsideStrip }
        let localPoint = CGPoint(
            x: screenPoint.x - stripScreenRect.minX,
            y: stripScreenRect.maxY - screenPoint.y
        )
        return FolderChipDropZone.classify(
            point: localPoint,
            stripVisibleRect: CGRect(origin: .zero, size: stripScreenRect.size),
            folderZoneMinX: folderZoneMinX
        )
    }
}
