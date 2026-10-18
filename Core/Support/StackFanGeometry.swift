import CoreGraphics
import Foundation

/// The native Dock's stack stage: the screen area a stack may spread over. Bottom Dock only —
/// the bar never sits on a side.
enum StackStage {
    /// Height of one fan item, and the step the stage height is divided by to count fan slots.
    static let fanItemSide = 64

    /// `Int(0.8 × (screen height below the menu bar − the height the bar takes off the bottom))`.
    /// `barOccupiedHeight` is the bar plate's visible top above the screen's bottom edge.
    static func height(screenHeightBelowMenuBar: CGFloat, barOccupiedHeight: CGFloat) -> Int {
        Int(0.8 * (screenHeightBelowMenuBar - barOccupiedHeight))
    }

    /// How many fan items the stage holds, the last one included ("Open in Finder" / "N More").
    static func maxFanItems(stageHeight: Int) -> Int {
        max(1, stageHeight / fanItemSide)
    }
}

/// What a pinned folder's popup shows for one opening.
enum FolderPopupView: Equatable {
    /// `fileItems` items from the top of the sort, then one top cell: "Open in Finder" when
    /// `hiddenCount == 0`, else "N More in Finder" with N = `hiddenCount`.
    case fan(fileItems: Int, hiddenCount: Int)
    case grid
    case list
}

/// The native Dock's `expandUsingHandler` choice for a bottom Dock, from a measured
/// threshold: fan when `fileCount + 1 ≤ stageHeight / 64` (1512 × 982, menu bar 33, Dock 61 →
/// 10 files fan, 11 grid). It never looks at icon size.
enum FolderViewResolution {
    static func resolve(mode: FolderViewMode, fileCount: Int, stageHeight: Int) -> FolderPopupView {
        switch mode {
        case .list:
            return .list
        case .grid:
            return .grid
        case .fan:
            return fan(fileCount: fileCount, stageHeight: stageHeight)
        case .automatic:
            return fileCount + 1 <= stageHeight / StackStage.fanItemSide
                ? fan(fileCount: fileCount, stageHeight: stageHeight)
                : .grid
        }
    }

    /// A forced fan cuts at the stage: the top slot becomes "N More in Finder".
    static func fan(fileCount: Int, stageHeight: Int) -> FolderPopupView {
        let slots = StackStage.maxFanItems(stageHeight: stageHeight)
        let count = max(0, fileCount)
        if count + 1 <= slots { return .fan(fileItems: count, hiddenCount: 0) }
        let shown = slots - 1
        return .fan(fileItems: shown, hiddenCount: count - shown)
    }

    /// Which copy the overflow cell uses. The native strings keep "one more" separate (Italian
    /// words it differently).
    enum MoreInFinderCopy: Equatable { case one, many }

    static func moreInFinderCopy(hiddenCount: Int) -> MoreInFinderCopy {
        hiddenCount == 1 ? .one : .many
    }

    static func moreInFinderTitle(hiddenCount: Int) -> String {
        switch moreInFinderCopy(hiddenCount: hiddenCount) {
        case .one: return String(localized: "1 More in Finder")
        case .many: return String(format: String(localized: "%@ More in Finder"), "\(hiddenCount)")
        }
    }
}

/// Reopening the same stack is refused for 0.1s after it collapsed (`canBeExpanded`), per stack:
/// clicking another folder's chip closes the first on mouse-down and opens the second on
/// mouse-up, often well inside 0.1s.
struct StackReopenCooldown {
    static let interval: TimeInterval = 0.1
    private var lastClosed: (path: String, at: TimeInterval)?

    mutating func noteClosed(path: String, at time: TimeInterval) {
        lastClosed = (path, time)
    }

    func allowsOpening(path: String, at time: TimeInterval) -> Bool {
        guard let lastClosed, lastClosed.path == path else { return true }
        return time - lastClosed.at >= Self.interval
    }
}

/// The cover pile on a folder chip, as fractions of the icon slot: each item is fitted into a
/// square canvas centred on the slot's vertical axis; items behind shrink and climb, so the whole
/// pile spans the slot's height. Measured off the system Dock at tile size 40. The chip draws
/// these and the fan flies its items out of and back into them, so both read one table.
enum FolderCoverPile {
    static let depths: [(canvas: CGFloat, centerY: CGFloat)] = [
        (0.925, 0.05), (0.85, -0.04), (0.74, -0.13),
    ]

    /// Layer `k`'s square in screen coordinates (y up) for a slot centred at `slotCenter`. Items
    /// past the pile share its last layer, as the native fan does.
    static func layerRect(_ k: Int, slotCenter: CGPoint, slot: CGFloat) -> CGRect {
        let depth = depths[min(max(k, 0), depths.count - 1)]
        let side = slot * depth.canvas
        // `centerY` is measured downward (SwiftUI); the screen is y-up.
        let center = CGPoint(x: slotCenter.x, y: slotCenter.y - slot * depth.centerY)
        return CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
    }
}

/// The native fan's geometry (`FanLayer layout`): 64pt items stacked 64pt apart up a circle of
/// radius 3000 whose centre sits 3000 to the right of the stack's tile, each turned clockwise by
/// its angle on that circle. Screen coordinates, y up.
struct StackFanLayout: Equatable {
    static let itemSide: CGFloat = 64
    static let radius: CGFloat = 3000
    /// The name capsule: 13pt text, 13pt padding each side, at least 26 high, its right edge 5pt
    /// left of the item.
    static let labelFontSize: CGFloat = 13
    static let labelPadding: CGFloat = 13
    static let labelMinHeight: CGFloat = 26
    static let labelGap: CGFloat = 5
    static let labelMaxTextWidth: CGFloat = 500
    /// `stackitemshadow` drawn 96 × 96, centred 15pt below the item, at opacity 0.4.
    static let shadowSide: CGFloat = 96
    static let shadowDrop: CGFloat = 15
    static let shadowOpacity: Float = 0.4

    struct Item: Equatable {
        var center: CGPoint
        /// Radians; negative turns clockwise.
        var rotation: CGFloat
        var labelSize: CGSize
    }

    var items: [Item]

    /// How far the first item's centre sits above the open tile's centre, from two native
    /// readings (square 25.5 → 67, 33 → 73.5); used as is outside them too.
    static func firstItemRise(squareSide: CGFloat) -> CGFloat {
        67 + (squareSide - 25.5) * 0.867
    }

    /// A capsule for a name of `textSize` (one line, already cut to `labelMaxTextWidth`).
    static func labelSize(textSize: CGSize) -> CGSize {
        CGSize(width: min(textSize.width, labelMaxTextWidth) + 2 * labelPadding,
               height: max(textSize.height, labelMinHeight))
    }

    init(items: [Item]) { self.items = items }

    init(tileCenter: CGPoint, squareSide: CGFloat, labelSizes: [CGSize]) {
        let rise = Self.firstItemRise(squareSide: squareSide)
        items = labelSizes.enumerated().map { index, labelSize in
            let t = rise + Self.itemSide * CGFloat(index)
            let dx = Self.radius - (Self.radius * Self.radius - t * t).squareRoot()
            return Item(center: CGPoint(x: tileCenter.x + dx, y: tileCenter.y + t),
                        rotation: -asin(t / Self.radius),
                        labelSize: labelSize)
        }
    }

    /// The item's 64pt square, turned, as an axis-aligned box.
    func iconBox(_ index: Int) -> CGRect {
        let item = items[index]
        let half = Self.itemSide / 2
        return Self.turnedBox(CGRect(x: -half, y: -half, width: Self.itemSide, height: Self.itemSide), item: item)
    }

    /// The name capsule in the item's own frame (origin at the item's centre, unturned).
    static func labelRect(for item: Item) -> CGRect {
        CGRect(x: -itemSide / 2 - labelGap - item.labelSize.width,
               y: -item.labelSize.height / 2,
               width: item.labelSize.width, height: item.labelSize.height)
    }

    static func shadowRect() -> CGRect {
        CGRect(x: -shadowSide / 2, y: -shadowDrop - shadowSide / 2, width: shadowSide, height: shadowSide)
    }

    /// Everything the fan draws — icons, capsules, shadows — as one box.
    var boundingBox: CGRect {
        items.reduce(CGRect.null) { box, item in
            box.union(Self.turnedBox(Self.labelRect(for: item), item: item))
                .union(Self.turnedBox(Self.shadowRect(), item: item))
                .union(Self.turnedBox(CGRect(x: -Self.itemSide / 2, y: -Self.itemSide / 2,
                                             width: Self.itemSide, height: Self.itemSide), item: item))
        }
    }

    /// `rect` (in the item's frame) turned with the item, as an axis-aligned box on screen.
    static func turnedBox(_ rect: CGRect, item: Item) -> CGRect {
        let turn = CGAffineTransform(rotationAngle: item.rotation)
        let corners = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                       CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)]
            .map { $0.applying(turn) }
        let xs = corners.map(\.x), ys = corners.map(\.y)
        return CGRect(x: item.center.x + xs.min()!, y: item.center.y + ys.min()!,
                      width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    /// Whether a screen point lands on item `index`'s icon square (not its capsule).
    func iconContains(_ point: CGPoint, index: Int) -> Bool {
        let item = items[index]
        let local = CGPoint(x: point.x - item.center.x, y: point.y - item.center.y)
            .applying(CGAffineTransform(rotationAngle: -item.rotation))
        return abs(local.x) <= Self.itemSide / 2 && abs(local.y) <= Self.itemSide / 2
    }

    func itemIndex(at point: CGPoint) -> Int? {
        items.indices.last { iconContains(point, index: $0) }
    }
}
