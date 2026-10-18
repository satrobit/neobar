import CoreGraphics
import Foundation

/// Every number of the folder / shelf / Trash popup, measured off the native Dock's stack grid
/// (macOS 27, AX frames plus screenshots over a solid backdrop). They are the look, not tuning
/// knobs: change one only against a new native measurement.
enum StackPopupMetrics {
    static let cell: CGFloat = 128
    static let iconSize: CGFloat = 100
    static let iconTop: CGFloat = 6
    static let labelSize: CGFloat = 13
    /// Width a name too long for the cell is truncated to (one that fits the cell is not cut).
    static let labelWidth: CGFloat = 120
    static let labelHeight: CGFloat = 16

    static let sidePadding: CGFloat = 17
    /// The title row above the grid.
    static let headerHeight: CGFloat = 32
    static let bottomPadding: CGFloat = 12
    static let cornerRadius: CGFloat = 26

    static let titleSize: CGFloat = 14
    /// Vertical centre of the title's line box, from the plate's top edge.
    static let titleCenterY: CGFloat = 18
    static let backButtonOrigin = CGPoint(x: 15.5, y: 7)
    static let backButtonSize = CGSize(width: 21, height: 22)

    /// A status line between title and grid (no native counterpart: empty shelf, Trash state).
    static let noteHeight: CGFloat = 36

    static let arrowHeight: CGFloat = 8
    /// Height the arrow would have with a sharp tip; its sides run at 45°.
    static let arrowSharpHeight: CGFloat = 9.75
    static let arrowTipRadius: CGFloat = 4.2
    static let arrowBaseRadius: CGFloat = 14
    /// Arrow tip to the anchor's top edge.
    static let tipGap: CGFloat = 3
    /// The plate's distance to the screen's left / right edge (native reading) …
    static let screenMargin: CGFloat = 31
    /// … which gives way, down to this, when the anchor itself sits at the edge: a plate held
    /// 31pt in could not put its arrow on the first or last chip of a full-width bar.
    static let minimumScreenMargin: CGFloat = 4
    /// Closest the arrow's centre comes to the plate's side: the corner radius plus the arrow's
    /// half base (9.75) and its base fillet's tangent length (5.8). Closer and it enters the arc.
    static let arrowInset: CGFloat = 42
    /// Transparent border of the popup window around the plate. The glass draws its own shadow,
    /// which reaches ~38pt out.
    static let panelMargin: CGFloat = 40
    /// The scroller sits in the plate's right padding, not over the last column.
    static let scrollerGutter: CGFloat = 14

    /// The folder / shelf / Trash plate (`StackPlateMetrics.stack`); its width never depends on scrolling.
    static func plateSize(columns: Int, rows: Int, hasNote: Bool) -> CGSize {
        StackPlateMetrics.stack.plateSize(columns: columns, rows: rows, hasNote: hasNote, scrolls: false)
    }

    /// Size of the popup window for a plate: the transparent border plus the arrow below it.
    static func panelSize(forPlate plate: CGSize) -> CGSize {
        CGSize(width: plate.width + 2 * panelMargin, height: plate.height + arrowHeight + 2 * panelMargin)
    }
}

/// One grid cell's numbers. The folder / shelf / Trash popups use `native`. The drawer's are read
/// off the system Apps panel (owner 2026-10-04, his screenshots at 2x): icons 112.5pt apart, rows
/// 102pt apart, a 62pt visible icon body (= a 76pt icon), a 13pt name 2pt under the icon, cut at
/// its tail.
struct StackCellMetrics: Equatable {
    var cellSize: CGSize
    var iconSize: CGFloat
    var iconTop: CGFloat
    /// Icon bottom to the name's line box.
    var labelGap: CGFloat
    var labelSize: CGFloat
    var labelWidth: CGFloat
    var labelHeight: CGFloat
    /// A name too long for the cell loses its tail (Apps panel) rather than its middle (Dock).
    var truncatesLabelTail: Bool

    static let native = StackCellMetrics(
        cellSize: CGSize(width: StackPopupMetrics.cell, height: StackPopupMetrics.cell),
        iconSize: StackPopupMetrics.iconSize, iconTop: StackPopupMetrics.iconTop, labelGap: 0,
        labelSize: StackPopupMetrics.labelSize, labelWidth: StackPopupMetrics.labelWidth,
        labelHeight: StackPopupMetrics.labelHeight, truncatesLabelTail: false)
    static let drawer = StackCellMetrics(cellSize: CGSize(width: 112.5, height: 102), iconSize: 76, iconTop: 5,
                                         labelGap: 2, labelSize: 13, labelWidth: 104, labelHeight: 16,
                                         truncatesLabelTail: true)
}

/// The plate around a grid: everything but the cells. `stack` is the native Dock's stack grid
/// (`StackPopupMetrics`). `drawer` is the system Apps panel's frame (owner 2026-10-04: the
/// drawer's size and margins "exactly like it"), read off his screenshot at 2x and checked against
/// the drawer's own: at full size the plate is 844 × 578 for 7 × 5 cells — 20pt to the grid on the
/// left, 36.5pt on the right where the scroller sits (ending 3pt in), a 56.5pt top row ruled off by
/// a 1pt line inset 20pt, and the grid scrolling under the bottom edge. The panel's search field
/// and category chips have no counterpart: the title sits in the search row, and the grid starts
/// below the rule as the panel's own sections start below theirs (rule to icon body 17pt).
struct StackPlateMetrics: Equatable {
    var cell: StackCellMetrics
    /// Plate edge to the grid on the left, and on the right while the grid does not scroll.
    var sidePadding: CGFloat
    /// Grid to the plate's right edge while it scrolls; the scroller sits in it.
    var scrollingTrailingPadding: CGFloat
    /// Width the scroll view takes past the grid; it sets where the scroller ends.
    var scrollerGutter: CGFloat
    var headerHeight: CGFloat
    /// Vertical centre of the title's line box, from the plate's top edge.
    var titleCenterY: CGFloat
    /// A 1pt rule under the title row, inset `sidePadding`.
    var hasSeparator: Bool
    /// Plate top to the status line or the grid's first row.
    var gridTop: CGFloat
    var bottomPadding: CGFloat
    /// A scrolling grid runs on under `bottomPadding` to the plate's edge, clipped by it.
    var scrollsToBottomEdge: Bool

    static let stack = StackPlateMetrics(
        cell: .native, sidePadding: StackPopupMetrics.sidePadding,
        scrollingTrailingPadding: StackPopupMetrics.sidePadding, scrollerGutter: StackPopupMetrics.scrollerGutter,
        headerHeight: StackPopupMetrics.headerHeight, titleCenterY: StackPopupMetrics.titleCenterY,
        hasSeparator: false, gridTop: StackPopupMetrics.headerHeight,
        bottomPadding: StackPopupMetrics.bottomPadding, scrollsToBottomEdge: false)
    static let drawer = StackPlateMetrics(
        cell: .drawer, sidePadding: 20, scrollingTrailingPadding: 36.5, scrollerGutter: 36,
        headerHeight: 56.5, titleCenterY: 28, hasSeparator: true, gridTop: 61.5,
        bottomPadding: 6.5, scrollsToBottomEdge: true)

    /// The drawer's grid never grows past the Apps panel's 7 × 5.
    static let drawerMaxColumns = 7
    static let drawerMaxRows = 5

    func plateSize(columns: Int, rows: Int, hasNote: Bool, scrolls: Bool) -> CGSize {
        let trailing = scrolls ? scrollingTrailingPadding : sidePadding
        return CGSize(width: sidePadding + CGFloat(columns) * cell.cellSize.width + trailing,
                      height: gridTop + (hasNote ? StackPopupMetrics.noteHeight : 0)
                          + CGFloat(rows) * cell.cellSize.height + bottomPadding)
    }
}

/// How many columns and rows the grid takes for a cell count — the native Dock's rule, derived
/// from 22 measured counts (`StackPopupGeometryTests`). Never replace it with a measured size.
enum StackGridLayout {
    struct Limits: Equatable {
        var maxColumns: Int
        /// Rows the native grid shows once it scrolls; with `maxColumns` it sets the capacity.
        var nominalRows: Int
        /// Rows that physically fit above the anchor. A non-scrolling grid may exceed
        /// `nominalRows` up to this (the native 5×5 on a screen whose capacity is 7×4).
        var fitRows: Int
        /// The same with a status line taking its height off the top.
        var fitRowsWithNote: Int
    }

    struct Result: Equatable {
        var columns: Int
        var visibleRows: Int
        var scrolls: Bool
    }

    /// `maxColumns` / `nominalRows` follow the screen; the 0.7 share is fitted to the one measured
    /// screen (1352×878 → 7 × 4) and extrapolated to others.
    static func limits(screenSize: CGSize, availablePlateHeight: CGFloat) -> Limits {
        let m = StackPopupMetrics.self
        let chromeHeight = m.headerHeight + m.bottomPadding
        let shareColumns = Int(((0.7 * screenSize.width - 2 * m.sidePadding) / m.cell).rounded(.down))
        let fitColumns = Int(((screenSize.width - 2 * m.screenMargin - 2 * m.sidePadding) / m.cell).rounded(.down))
        let nominalRows = Int(((0.7 * screenSize.height - chromeHeight) / m.cell).rounded(.down))
        func rows(in height: CGFloat) -> Int { max(1, Int(((height - chromeHeight) / m.cell).rounded(.down))) }
        return Limits(maxColumns: max(1, min(max(3, shareColumns), fitColumns)),
                      nominalRows: max(2, nominalRows),
                      fitRows: rows(in: availablePlateHeight),
                      fitRowsWithNote: rows(in: availablePlateHeight - m.noteHeight))
    }

    /// The drawer's limits: the Apps panel's 7 × 5 (`StackPlateMetrics.drawer`), giving way only
    /// to a screen or a space above the capsule too small for it.
    static func drawerLimits(screenSize: CGSize, availablePlateHeight: CGFloat) -> Limits {
        let plate = StackPlateMetrics.drawer
        let cell = plate.cell.cellSize
        let fitColumns = Int(((screenSize.width - 2 * StackPopupMetrics.screenMargin - plate.sidePadding
                               - plate.scrollingTrailingPadding) / cell.width).rounded(.down))
        func rows(in height: CGFloat) -> Int {
            let fit = Int(((height - plate.gridTop - plate.bottomPadding) / cell.height).rounded(.down))
            return max(1, min(StackPlateMetrics.drawerMaxRows, fit))
        }
        return Limits(maxColumns: max(1, min(StackPlateMetrics.drawerMaxColumns, fitColumns)),
                      nominalRows: StackPlateMetrics.drawerMaxRows,
                      fitRows: rows(in: availablePlateHeight),
                      fitRowsWithNote: rows(in: availablePlateHeight - StackPopupMetrics.noteHeight))
    }

    /// A status line needs room to be read; the native grid never shows one.
    static let noteMinColumns = 3

    /// The grid's shape. A status line (`hasNote`) costs the rows it displaces and widens a
    /// narrow plate to `noteMinColumns`; without one this is the native rule untouched.
    static func resolve(cellCount: Int, limits: Limits, hasNote: Bool) -> Result {
        guard hasNote else { return shape(cellCount: cellCount, limits: limits, fitRows: limits.fitRows) }
        let natural = shape(cellCount: cellCount, limits: limits, fitRows: limits.fitRowsWithNote)
        let columns = min(max(natural.columns, noteMinColumns), max(natural.columns, limits.maxColumns))
        guard columns > natural.columns else { return natural }
        let rows = Int((Double(max(1, cellCount)) / Double(columns)).rounded(.up))
        return Result(columns: columns, visibleRows: min(rows, natural.visibleRows), scrolls: natural.scrolls)
    }

    private static func shape(cellCount: Int, limits: Limits, fitRows: Int) -> Result {
        let count = max(1, cellCount)
        let pageRows = max(1, min(limits.nominalRows, fitRows))
        let capacity = limits.maxColumns * pageRows
        guard count <= capacity else {
            return Result(columns: limits.maxColumns, visibleRows: pageRows, scrolls: true)
        }
        // Fewest empty cells among near-square shapes (rows ≤ columns ≤ rows + 3) within the
        // capacity; ascending rows makes a tie go to the flatter shape.
        var best: (columns: Int, rows: Int, empty: Int)?
        for rows in 1...max(1, fitRows) {
            let columns = max(rows, Int((Double(count) / Double(rows)).rounded(.up)))
            guard columns <= min(limits.maxColumns, rows + 3), columns * rows <= capacity else { continue }
            let empty = columns * rows - count
            if best == nil || empty < best!.empty { best = (columns, rows, empty) }
        }
        if let best { return Result(columns: best.columns, visibleRows: best.rows, scrolls: false) }
        let rows = Int((Double(count) / Double(limits.maxColumns)).rounded(.up))
        return Result(columns: limits.maxColumns, visibleRows: min(rows, pageRows), scrolls: rows > pageRows)
    }
}

/// The drawer's grid: the stack rule, held still while a drag is converting a chip in or out.
/// A conversion adds or removes a member before the release decides anything; reshaping the
/// grid on that (4 cells are 2 × 2, 5 are 3 × 2) would resize the plate under the pointer and
/// flip the enter / leave test that caused it.
enum DrawerGridShape {
    struct Result: Equatable {
        var layout: StackGridLayout.Result
        /// The empty drawer's hint line.
        var showsHint: Bool
    }

    /// Visible members with the conversion in flight undone: a chip converted in is not counted
    /// yet, one converted out still is. By id, never ±1 — both drag-out modes remove placement.
    static func settledCount(visibleIDs: [String], convertedInID: String?, convertedOutID: String?) -> Int {
        var ids = Set(visibleIDs)
        if let convertedInID { ids.remove(convertedInID) }
        if let convertedOutID { ids.insert(convertedOutID) }
        return ids.count
    }

    /// The count the columns come from: the one this showing opened with (`DrawerColumnHold`), else
    /// the settled one. Only a drawer empty with nothing converting out is the hint plate — the
    /// last cell dragged out keeps its plate until the release. A showing that opened empty holds
    /// the hint plate's columns, so its first member dragged back out does not read as empty.
    static func columnBasis(heldCount: Int?, settledCount: Int, actualCount: Int) -> Int {
        if actualCount == 0 && settledCount == 0 { return 0 }
        guard let heldCount else { return settledCount }
        return heldCount == 0 ? StackGridLayout.noteMinColumns : heldCount
    }

    /// Columns come from `settledCount`; rows follow `actualCount` and never drop below one
    /// while the two differ. Only a drawer empty on both counts is the hint plate.
    static func resolve(settledCount: Int, actualCount: Int, limits: StackGridLayout.Limits) -> Result {
        if settledCount == actualCount {
            guard actualCount > 0 else {
                return Result(layout: .init(columns: StackGridLayout.noteMinColumns, visibleRows: 0, scrolls: false),
                              showsHint: true)
            }
            return Result(layout: StackGridLayout.resolve(cellCount: actualCount, limits: limits, hasNote: false),
                          showsHint: false)
        }
        let columns: Int
        let maxRows: Int
        if settledCount > 0 {
            let settled = StackGridLayout.resolve(cellCount: settledCount, limits: limits, hasNote: false)
            columns = settled.columns
            maxRows = settled.scrolls ? settled.visibleRows : limits.fitRows
        } else {
            columns = StackGridLayout.noteMinColumns
            maxRows = limits.fitRows
        }
        let rows = max(1, Int((Double(actualCount) / Double(columns)).rounded(.up)))
        let visibleRows = min(rows, max(1, maxRows))
        return Result(layout: .init(columns: columns, visibleRows: visibleRows, scrolls: rows > visibleRows),
                      showsHint: false)
    }
}

/// The open drawer's column basis: the count its first render of a showing saw, held until the
/// drawer is ordered out. A release, a drop from outside or an app quitting then only adds or
/// removes rows; columns change at the next opening, which has no animation. Reshaping the open
/// plate on a release lays the cells out at once while the window takes 0.22s to follow.
struct DrawerColumnHold {
    private(set) var isShowing = false
    /// Bumped when a closed drawer starts showing.
    private(set) var showing = 0
    private var heldShowing: Int?
    private var heldCount = 0

    /// Returns whether a new showing began. Reopening a plate still on screen (mid fade-out)
    /// keeps the old one; a plate that is not on screen always starts a new one, whichever path
    /// ordered it out.
    @discardableResult
    mutating func begin(plateOnScreen: Bool) -> Bool {
        guard !(isShowing && plateOnScreen) else { return false }
        isShowing = true
        showing &+= 1
        return true
    }

    mutating func end() { isShowing = false }

    /// The held count, captured from `settled` on the first call of a showing. A closed drawer
    /// holds nothing (another screen's view, the prewarmed host).
    mutating func heldCount(capturing settled: Int) -> Int? {
        guard isShowing else { return nil }
        if heldShowing != showing {
            heldShowing = showing
            heldCount = settled
        }
        return heldCount
    }
}

/// The plate's outline: a rounded rectangle with the arrow on its bottom edge. One path feeds both
/// the glass (`_setPath:`) and the frosted fallback's clip, so the two can never disagree.
enum StackPopupOutline {
    /// Keeps the arrow and its base fillets on the straight part of the bottom edge.
    static func clampedArrowCenterX(_ x: CGFloat, plateWidth: CGFloat) -> CGFloat {
        let inset = StackPopupMetrics.arrowInset
        guard plateWidth > 2 * inset else { return plateWidth / 2 }
        return min(max(x, inset), plateWidth - inset)
    }

    /// Top-left origin, y down; the arrow hangs below `plateSize.height`. `arrowCenterX == nil`
    /// draws the plate alone.
    static func path(plateSize: CGSize, arrowCenterX: CGFloat?) -> CGPath {
        let m = StackPopupMetrics.self
        let (w, h, r) = (plateSize.width, plateSize.height, min(m.cornerRadius, min(plateSize.width, plateSize.height) / 2))
        let path = CGMutablePath()
        path.move(to: CGPoint(x: r, y: 0))
        path.addArc(tangent1End: CGPoint(x: w, y: 0), tangent2End: CGPoint(x: w, y: h), radius: r)
        path.addArc(tangent1End: CGPoint(x: w, y: h), tangent2End: CGPoint(x: 0, y: h), radius: r)
        if let arrowCenterX {
            let cx = clampedArrowCenterX(arrowCenterX, plateWidth: w)
            let t = m.arrowSharpHeight
            path.addArc(tangent1End: CGPoint(x: cx + t, y: h), tangent2End: CGPoint(x: cx, y: h + t), radius: m.arrowBaseRadius)
            path.addArc(tangent1End: CGPoint(x: cx, y: h + t), tangent2End: CGPoint(x: cx - t, y: h), radius: m.arrowTipRadius)
            path.addArc(tangent1End: CGPoint(x: cx - t, y: h), tangent2End: CGPoint(x: 0, y: h), radius: m.arrowBaseRadius)
        }
        path.addArc(tangent1End: CGPoint(x: 0, y: h), tangent2End: CGPoint(x: 0, y: 0), radius: r)
        path.addArc(tangent1End: CGPoint(x: 0, y: 0), tangent2End: CGPoint(x: w, y: 0), radius: r)
        path.closeSubpath()
        return path
    }
}
