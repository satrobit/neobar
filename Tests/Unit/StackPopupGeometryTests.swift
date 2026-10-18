import XCTest

/// The stack grid's shape rule against the native Dock's own answers (macOS 27, 1352×878 screen).
final class StackPopupGeometryTests: XCTestCase {
    // MARK: - Drawer grid (the stack rule, held still during a conversion)

    private let drawerLimits = StackGridLayout.Limits(maxColumns: 7, nominalRows: 4, fitRows: 5, fitRowsWithNote: 4)

    private func drawerShape(settled: Int, actual: Int) -> DrawerGridShape.Result {
        DrawerGridShape.resolve(settledCount: settled, actualCount: actual, limits: drawerLimits)
    }

    func testDrawerGridAtRestIsTheStackRule() {
        for count in 1...40 {
            XCTAssertEqual(drawerShape(settled: count, actual: count).layout,
                           StackGridLayout.resolve(cellCount: count, limits: drawerLimits, hasNote: false))
            XCTAssertFalse(drawerShape(settled: count, actual: count).showsHint)
        }
        let empty = drawerShape(settled: 0, actual: 0)
        XCTAssertTrue(empty.showsHint)
        XCTAssertEqual(empty.layout, .init(columns: StackGridLayout.noteMinColumns, visibleRows: 0, scrolls: false))
    }

    func testDrawerGridKeepsItsColumnsWhileAChipIsConvertedInOrOut() {
        for settled in 1...30 {
            let columns = drawerShape(settled: settled, actual: settled).layout.columns
            let rows = drawerShape(settled: settled, actual: settled).layout.visibleRows
            let convertedIn = drawerShape(settled: settled, actual: settled + 1).layout
            XCTAssertEqual(convertedIn.columns, columns, "in, settled \(settled)")
            XCTAssertLessThanOrEqual(convertedIn.visibleRows, rows + 1)
            XCTAssertGreaterThanOrEqual(convertedIn.visibleRows, rows)
            let convertedOut = drawerShape(settled: settled, actual: settled - 1)
            XCTAssertEqual(convertedOut.layout.columns, columns, "out, settled \(settled)")
            XCTAssertGreaterThanOrEqual(convertedOut.layout.visibleRows, 1)
            XCTAssertFalse(convertedOut.showsHint)
        }
    }

    func testDrawerGridThroughTheEmptyBoundary() {
        // 0 → 1 → 0: first drag-in keeps the hint plate's three columns until the release.
        let entering = drawerShape(settled: 0, actual: 1)
        XCTAssertEqual(entering.layout, .init(columns: 3, visibleRows: 1, scrolls: false))
        XCTAssertFalse(entering.showsHint)
        XCTAssertTrue(drawerShape(settled: 0, actual: 0).showsHint)                    // reverted
        XCTAssertEqual(drawerShape(settled: 1, actual: 1).layout.columns, 1)           // committed
        // 1 → 0 → 1: dragging the last one out keeps the one-cell plate, no hint.
        let leaving = drawerShape(settled: 1, actual: 0)
        XCTAssertEqual(leaving.layout, .init(columns: 1, visibleRows: 1, scrolls: false))
        XCTAssertFalse(leaving.showsHint)
        XCTAssertEqual(drawerShape(settled: 1, actual: 1).layout.columns, 1)           // reverted
        XCTAssertTrue(drawerShape(settled: 0, actual: 0).showsHint)                    // committed
    }

    /// An outside drag's make-way slot holds every dragged app at once: the columns stay the
    /// members', only rows may grow.
    func testDrawerGridKeepsItsColumnsUnderSeveralSlotCells() {
        for settled in 1...30 {
            let columns = drawerShape(settled: settled, actual: settled).layout.columns
            for extra in 1...3 {
                XCTAssertEqual(drawerShape(settled: settled, actual: settled + extra).layout.columns, columns,
                               "settled \(settled) + \(extra)")
            }
        }
    }

    /// The open drawer's shape through `columnBasis`, as `DrawerView.gridShape` builds it.
    private func openShape(held: Int?, settled: Int, actual: Int) -> DrawerGridShape.Result {
        DrawerGridShape.resolve(
            settledCount: DrawerGridShape.columnBasis(heldCount: held, settledCount: settled, actualCount: actual),
            actualCount: actual, limits: drawerLimits)
    }

    /// The release keeps the shape the drag showed: no new columns, no new plate size.
    func testOpenDrawerKeepsItsShapeAcrossTheRelease() {
        let limits = StackGridLayout.Limits(maxColumns: 7, nominalRows: 5, fitRows: 5, fitRowsWithNote: 5)
        func shape(_ held: Int?, _ settled: Int, _ actual: Int) -> StackGridLayout.Result {
            DrawerGridShape.resolve(
                settledCount: DrawerGridShape.columnBasis(heldCount: held, settledCount: settled, actualCount: actual),
                actualCount: actual, limits: limits).layout
        }
        // 25 → 26 is 5 × 5 → 7 × 4 at rest; the open drawer stays on five columns and scrolls.
        XCTAssertEqual(StackGridLayout.resolve(cellCount: 26, limits: limits, hasNote: false).columns, 7)
        let converting = shape(25, 25, 26)
        XCTAssertEqual(converting, .init(columns: 5, visibleRows: 5, scrolls: true))
        XCTAssertEqual(shape(25, 26, 26), converting)                                   // committed
        // Dragging one out of 26: seven columns through the release.
        XCTAssertEqual(shape(26, 26, 25), shape(26, 25, 25))
        XCTAssertEqual(shape(26, 25, 25).columns, 7)
        // An outside drop: the slot's cells, then the members they became.
        XCTAssertEqual(shape(25, 25, 27), shape(25, 27, 27))
        // Nothing held (closed drawer): the native rule.
        XCTAssertEqual(shape(nil, 26, 26), StackGridLayout.resolve(cellCount: 26, limits: limits, hasNote: false))
    }

    func testOpenDrawerThroughTheEmptyBoundary() {
        // Last one dragged out: one cell, no hint, while it is out; back in, the same; released, the hint.
        let leaving = openShape(held: 1, settled: 1, actual: 0)
        XCTAssertEqual(leaving.layout, .init(columns: 1, visibleRows: 1, scrolls: false))
        XCTAssertFalse(leaving.showsHint)
        XCTAssertEqual(openShape(held: 1, settled: 1, actual: 1).layout.columns, 1)
        XCTAssertTrue(openShape(held: 1, settled: 0, actual: 0).showsHint)
        // Opened empty, one dragged in: the hint plate's three columns while converting and after.
        let entering = openShape(held: 0, settled: 0, actual: 1)
        XCTAssertEqual(entering.layout, .init(columns: 3, visibleRows: 1, scrolls: false))
        XCTAssertEqual(openShape(held: 0, settled: 1, actual: 1), entering)
        XCTAssertFalse(entering.showsHint)
        // Same showing: that one dragged back out keeps the plate; only its release is the hint.
        XCTAssertEqual(openShape(held: 0, settled: 1, actual: 0).layout, entering.layout)
        XCTAssertFalse(openShape(held: 0, settled: 1, actual: 0).showsHint)
        XCTAssertEqual(openShape(held: 0, settled: 1, actual: 1), entering)            // back in
        XCTAssertTrue(openShape(held: 0, settled: 0, actual: 0).showsHint)             // released out
        XCTAssertEqual(openShape(held: 0, settled: 2, actual: 2).layout.columns, 3)    // a second one in
    }

    func testColumnHoldCapturesOncePerShowing() {
        var hold = DrawerColumnHold()
        XCTAssertNil(hold.heldCount(capturing: 5))                   // closed: nothing held
        XCTAssertTrue(hold.begin(plateOnScreen: false))
        XCTAssertEqual(hold.heldCount(capturing: 25), 25)
        XCTAssertEqual(hold.heldCount(capturing: 26), 25)            // same showing
        XCTAssertFalse(hold.begin(plateOnScreen: true))              // reopened mid fade-out
        XCTAssertEqual(hold.heldCount(capturing: 30), 25)
        hold.end()
        XCTAssertNil(hold.heldCount(capturing: 26))
        XCTAssertTrue(hold.begin(plateOnScreen: false))
        XCTAssertEqual(hold.heldCount(capturing: 26), 26)
        // Ordered out by a path that never called `end`: the next opening still starts afresh.
        XCTAssertTrue(hold.begin(plateOnScreen: false))
        XCTAssertEqual(hold.heldCount(capturing: 12), 12)
    }

    func testDrawerSettledCountUndoesTheConversionByID() {
        let visible = ["a", "b", "c"]
        XCTAssertEqual(DrawerGridShape.settledCount(visibleIDs: visible, convertedInID: nil, convertedOutID: nil), 3)
        // Strip chip "c" converted in: not counted yet.
        XCTAssertEqual(DrawerGridShape.settledCount(visibleIDs: visible, convertedInID: "c", convertedOutID: nil), 2)
        // "d" converted out (unstash and keepPlacement both remove placement): still counted.
        XCTAssertEqual(DrawerGridShape.settledCount(visibleIDs: visible, convertedInID: nil, convertedOutID: "d"), 4)
        // An id already (or still) in the list is never counted twice.
        XCTAssertEqual(DrawerGridShape.settledCount(visibleIDs: visible, convertedInID: nil, convertedOutID: "a"), 3)
        XCTAssertEqual(DrawerGridShape.settledCount(visibleIDs: visible, convertedInID: "z", convertedOutID: nil), 3)
    }

    /// Limits of the measured screen: 7 columns, 4 rows once scrolling, 5 rows fit above the Dock.
    private let measured = StackGridLayout.Limits(maxColumns: 7, nominalRows: 4, fitRows: 5, fitRowsWithNote: 5)

    func testShapesMatchTheNativeDock() {
        let native: [(cells: Int, columns: Int, rows: Int)] = [
            (3, 3, 1), (7, 4, 2), (8, 4, 2), (9, 3, 3), (10, 5, 2), (11, 4, 3), (12, 4, 3),
            (13, 5, 3), (14, 5, 3), (15, 5, 3), (16, 4, 4), (17, 6, 3), (18, 6, 3), (19, 5, 4),
            (20, 5, 4), (21, 6, 4), (22, 6, 4), (23, 6, 4), (24, 6, 4), (25, 5, 5), (26, 7, 4),
            (27, 7, 4), (28, 7, 4),
        ]
        for point in native {
            XCTAssertEqual(StackGridLayout.resolve(cellCount: point.cells, limits: measured, hasNote: false),
                           .init(columns: point.columns, visibleRows: point.rows, scrolls: false),
                           "\(point.cells) cells")
        }
    }

    func testOverCapacityScrollsAtFullWidth() {
        for cells in [29, 30, 36, 67] {
            XCTAssertEqual(StackGridLayout.resolve(cellCount: cells, limits: measured, hasNote: false),
                           .init(columns: 7, visibleRows: 4, scrolls: true), "\(cells) cells")
        }
    }

    func testLimitsOfTheMeasuredScreen() {
        // Plate top 8pt under the menu bar, arrow tip 3pt above a Dock whose top edge is at 57pt.
        let limits = StackGridLayout.limits(screenSize: CGSize(width: 1352, height: 878), availablePlateHeight: 772)
        XCTAssertEqual(limits, measured)
    }

    func testAShortScreenStillYieldsAGrid() {
        let limits = StackGridLayout.limits(screenSize: CGSize(width: 800, height: 400), availablePlateHeight: 150)
        XCTAssertEqual(limits.fitRows, 1)
        let one = StackGridLayout.resolve(cellCount: 2, limits: limits, hasNote: false)
        XCTAssertEqual(one, .init(columns: 2, visibleRows: 1, scrolls: false))
        let many = StackGridLayout.resolve(cellCount: 40, limits: limits, hasNote: false)
        XCTAssertEqual(many.visibleRows, 1)
        XCTAssertTrue(many.scrolls)
        XCTAssertEqual(many.columns, limits.maxColumns)
    }

    /// A status line takes its height only when there is one: the same 25 cells stay the native
    /// 5×5 without it and fall back to 7×4 with it, where a fifth row would no longer fit.
    func testAStatusLineCostsRowsOnlyWhenPresent() {
        // A tall bar on the measured screen: 719pt for the plate, five rows without a note.
        let limits = StackGridLayout.limits(screenSize: CGSize(width: 1352, height: 878), availablePlateHeight: 719)
        XCTAssertEqual(limits.fitRows, 5)
        XCTAssertEqual(limits.fitRowsWithNote, 4)
        XCTAssertEqual(StackGridLayout.resolve(cellCount: 25, limits: limits, hasNote: false),
                       .init(columns: 5, visibleRows: 5, scrolls: false))
        XCTAssertEqual(StackGridLayout.resolve(cellCount: 25, limits: limits, hasNote: true),
                       .init(columns: 7, visibleRows: 4, scrolls: false))
        for hasNote in [false, true] {
            for cells in 1...80 {
                let shape = StackGridLayout.resolve(cellCount: cells, limits: limits, hasNote: hasNote)
                let plate = StackPopupMetrics.plateSize(columns: shape.columns, rows: shape.visibleRows, hasNote: hasNote)
                XCTAssertLessThanOrEqual(plate.height, 719, "\(cells) cells, note \(hasNote)")
            }
        }
    }

    func testAStatusLineWidensANarrowPlate() {
        XCTAssertEqual(StackGridLayout.resolve(cellCount: 1, limits: measured, hasNote: true),
                       .init(columns: 3, visibleRows: 1, scrolls: false))
        XCTAssertEqual(StackGridLayout.resolve(cellCount: 1, limits: measured, hasNote: false),
                       .init(columns: 1, visibleRows: 1, scrolls: false))
    }

    /// The drawer at full size is the system Apps panel's frame as measured off the owner's
    /// screenshot: 844 × 578, seven columns, five rows, whatever the screen offers beyond that.
    func testFullDrawerIsTheAppsPanel() {
        let limits = StackGridLayout.drawerLimits(screenSize: CGSize(width: 1512, height: 982), availablePlateHeight: 860)
        XCTAssertEqual(limits, .init(maxColumns: 7, nominalRows: 5, fitRows: 5, fitRowsWithNote: 5))
        let full = StackGridLayout.resolve(cellCount: 40, limits: limits, hasNote: false)
        XCTAssertEqual(full, .init(columns: 7, visibleRows: 5, scrolls: true))
        let plate = StackPlateMetrics.drawer
        XCTAssertEqual(plate.plateSize(columns: 7, rows: 5, hasNote: false, scrolls: true), CGSize(width: 844, height: 578))
        // Not scrolling, the scroller's strip is not kept: the grid sits between equal margins.
        XCTAssertEqual(plate.plateSize(columns: 7, rows: 5, hasNote: false, scrolls: false).width, 827.5)
        // A larger screen does not make it larger.
        XCTAssertEqual(StackGridLayout.drawerLimits(screenSize: CGSize(width: 2560, height: 1440),
                                                    availablePlateHeight: 1300), limits)
        // A short space above the capsule takes rows off; the plate never outgrows it.
        let short = StackGridLayout.drawerLimits(screenSize: CGSize(width: 1352, height: 600), availablePlateHeight: 400)
        XCTAssertEqual(short.fitRows, 3)
        XCTAssertLessThanOrEqual(plate.plateSize(columns: 7, rows: short.fitRows, hasNote: false, scrolls: true).height, 400)
    }

    func testSizesAreDerivedFromTheShape() {
        // The native 4×3 plate measured 546 wide (+ hairline) and 428 tall.
        let plate = StackPopupMetrics.plateSize(columns: 4, rows: 3, hasNote: false)
        XCTAssertEqual(plate, CGSize(width: 546, height: 428))
        XCTAssertEqual(StackPopupMetrics.panelSize(forPlate: plate), CGSize(width: 626, height: 516))
    }

    func testOutlineHangsTheArrowBelowThePlate() {
        let plate = CGSize(width: 546, height: 428)
        let plain = StackPopupOutline.path(plateSize: plate, arrowCenterX: nil).boundingBoxOfPath
        XCTAssertEqual(plain.origin, .zero)
        XCTAssertEqual(plain.width, plate.width, accuracy: 0.001)
        XCTAssertEqual(plain.height, plate.height, accuracy: 0.001)
        let box = StackPopupOutline.path(plateSize: plate, arrowCenterX: 273).boundingBoxOfPath
        XCTAssertEqual(box.minY, 0)
        XCTAssertEqual(box.width, plate.width, accuracy: 0.001)
        XCTAssertEqual(box.maxY, plate.height + StackPopupMetrics.arrowHeight, accuracy: 0.05)
    }

    func testArrowStaysOffTheCorners() {
        XCTAssertEqual(StackPopupOutline.clampedArrowCenterX(2, plateWidth: 546), 42)
        XCTAssertEqual(StackPopupOutline.clampedArrowCenterX(540, plateWidth: 546), 504)
        XCTAssertEqual(StackPopupOutline.clampedArrowCenterX(300, plateWidth: 546), 300)
        // Too narrow for a clamp range: centre it.
        XCTAssertEqual(StackPopupOutline.clampedArrowCenterX(10, plateWidth: 80), 40)
    }
}
