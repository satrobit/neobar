import CoreGraphics

/// Dropping app bundles from outside (Finder) onto the drawer capsule or into the open drawer:
/// where it lands and how the drawer order changes. The receiver is `DrawerAppDropReceiver`; the
/// commit is `PanelCoordinator.stashDroppedApplications`.
enum DrawerAppDrop {
    /// The capsule's drop zone reaches this far past its visible content, the same as the
    /// strip→capsule stash zone (`PanelCoordinator.dragDropZones`), so both drags agree on the
    /// gap between bar and capsule (also 8pt) belonging to the capsule.
    static let capsuleTolerance: CGFloat = 8

    /// Where dropped apps go in the drawer order. The capsule always lands them `.front`; a drop
    /// into the open drawer lands where the pointer was (`placement(at:frames:order:)`).
    enum Placement: Equatable {
        case front
        case before(String)
        case after(String)
        case end
    }

    /// Whether a hover may light the capsule and a release may land: at least one app bundle that
    /// is not inside a Trash, with the point inside `zone` (visible capsule + tolerance).
    static func accepts(containsApplication: Bool, point: CGPoint, zone: CGRect) -> Bool {
        containsApplication && zone.contains(point)
    }

    /// The drop point over the open drawer's grid: the cell under it decides, by its midline,
    /// whether the app goes before or after it; empty plate (title row, space past the last cell)
    /// appends at the end. `frames` and `point` share one coordinate space; `order` is the
    /// visible order and decides which cell wins when frames overlap mid-animation.
    static func placement(at point: CGPoint, frames: [String: CGRect], order: [String]) -> Placement {
        for id in order {
            guard let frame = frames[id], frame.contains(point) else { continue }
            return point.x > frame.midX ? .after(id) : .before(id)
        }
        return .end
    }

    /// Where the make-way slot sits while apps dragged from outside hover over the open plate.
    /// A cell other than the slot decides by its midline, as `placement(at:)` and the drawer's own
    /// reorder do; on the slot itself or off every cell the slot stays put (`current`), and a hover
    /// that has none yet starts at `.end` — or, entering over a dragged app's own cell, where that
    /// cell is. Staying put on the slot is what keeps it from oscillating: the slot opens where
    /// the pointer pushed the neighbour away from.
    static func hoverPlacement(current: Placement?, point: CGPoint, frames: [String: CGRect],
                               displayOrder: [String], ghostIDs: [String]) -> Placement {
        let slot = Set(ghostIDs)
        for (index, id) in displayOrder.enumerated() {
            guard let frame = frames[id], frame.contains(point) else { continue }
            guard slot.contains(id) else { return point.x > frame.midX ? .after(id) : .before(id) }
            if let current { return current }
            return displayOrder[(index + 1)...].first { !slot.contains($0) }.map(Placement.before) ?? .end
        }
        return current ?? .end
    }

    /// The drawer order after a drop: the dropped ids first in drag order (deduped), everything
    /// else in its existing order. Ids not yet in `existing` are new members and go first too.
    static func frontOrder(existing: [String], dropped: [String]) -> [String] {
        order(existing: existing, dropped: dropped, placement: .front)
    }

    /// The drawer order after a drop at `placement`: the dropped ids (deduped, drag order kept)
    /// leave wherever they were and go in as one block — first, last, or beside the target cell.
    /// A target that is no longer a member lands them at the end.
    static func order(existing: [String], dropped: [String], placement: Placement) -> [String] {
        var seen = Set<String>()
        let block = dropped.filter { !$0.isEmpty && seen.insert($0).inserted }
        guard !block.isEmpty else { return existing }
        let rest = existing.filter { !seen.contains($0) }
        switch placement {
        case .front:
            return block + rest
        case .end:
            return rest + block
        case .before(let target):
            guard let index = rest.firstIndex(of: target) else { return rest + block }
            return Array(rest[..<index]) + block + Array(rest[index...])
        case .after(let target):
            guard let index = rest.firstIndex(of: target) else { return rest + block }
            return Array(rest[...index]) + block + Array(rest[(index + 1)...])
        }
    }
}

/// The make-way slot of apps dragged from outside over the open drawer: view state only. The
/// dragged cells are drawn hidden at `placement`; nothing is written to `DrawerStore` or
/// `DrawerOrderStore` until the drop — a running app with cards on the bar would lose them for the
/// length of a hover.
struct ExternalDrawerGhost: Equatable {
    /// The dragged apps' bundle ids, in drag order.
    var ids: [String]
    var placement: DrawerAppDrop.Placement

    /// The grid order while the slot is open: the dragged ids leave their cells (an app already in
    /// the drawer moves) and sit together at `placement`.
    func displayOrder(visibleMembers: [String]) -> [String] {
        DrawerAppDrop.order(existing: visibleMembers, dropped: ids, placement: placement)
    }
}

/// Where the drag image of an app from outside goes when it turns into the drawer's cell bitmap
/// over the open plate, so the pointer keeps the same spot on the icon. All rects share the drop
/// receiver's coordinates (AppKit, y up).
enum DrawerDragImageGeometry {
    /// The icon's rect inside the cell bitmap (y up): `bitmapSize` includes the snapshot's bleed
    /// around `cellSize`; the icon is centred across and `iconTop` below the cell's top.
    static func iconRect(bitmapSize: CGSize, cellSize: CGSize, iconSize: CGFloat, iconTop: CGFloat) -> CGRect {
        let bleedX = (bitmapSize.width - cellSize.width) / 2
        let bleedY = (bitmapSize.height - cellSize.height) / 2
        return CGRect(x: bleedX + (cellSize.width - iconSize) / 2,
                      y: bitmapSize.height - bleedY - iconTop - iconSize,
                      width: iconSize, height: iconSize)
    }

    /// The new dragging frame. `iconComponent` is the source image's `.icon` component in the
    /// item's own coordinates (Finder's image is icon + name, so the whole frame is not the icon);
    /// `nil` uses the whole frame. The pointer's place in that icon maps to the same place in the
    /// cell's icon, unclamped — a pointer on the source's name stays off the cell's icon, as the
    /// system itself re-places the image by that fraction (`DrawerDragImage`); the origin snaps to
    /// device pixels.
    static func frame(itemFrame: CGRect, iconComponent: CGRect?, pointer: CGPoint,
                      bitmapSize: CGSize, cellIconRect: CGRect, backingScale: CGFloat) -> CGRect {
        let icon = iconComponent.map { $0.offsetBy(dx: itemFrame.minX, dy: itemFrame.minY) } ?? itemFrame
        func fraction(_ value: CGFloat, _ start: CGFloat, _ length: CGFloat) -> CGFloat {
            guard length > 0 else { return 0.5 }
            return (value - start) / length
        }
        let fx = fraction(pointer.x, icon.minX, icon.width)
        let fy = fraction(pointer.y, icon.minY, icon.height)
        let scale = max(backingScale, 1)
        func snap(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
        return CGRect(x: snap(pointer.x - fx * cellIconRect.width - cellIconRect.minX),
                      y: snap(pointer.y - fy * cellIconRect.height - cellIconRect.minY),
                      width: bitmapSize.width, height: bitmapSize.height)
    }
}
