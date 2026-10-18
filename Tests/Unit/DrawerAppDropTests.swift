import XCTest
@testable import NeoBar

final class DrawerAppDropTests: XCTestCase {

    func testNewMemberGoesFirst() {
        XCTAssertEqual(DrawerAppDrop.frontOrder(existing: ["a", "b"], dropped: ["new"]),
                       ["new", "a", "b"])
    }

    func testExistingMemberMovesToFront() {
        XCTAssertEqual(DrawerAppDrop.frontOrder(existing: ["a", "b", "c"], dropped: ["b"]),
                       ["b", "a", "c"])
    }

    func testFrontMemberStaysPut() {
        XCTAssertEqual(DrawerAppDrop.frontOrder(existing: ["a", "b"], dropped: ["a"]),
                       ["a", "b"])
    }

    func testSeveralKeepDragOrderAndDedupe() {
        XCTAssertEqual(DrawerAppDrop.frontOrder(existing: ["a", "b", "c"],
                                                dropped: ["c", "x", "c", "", "a"]),
                       ["c", "x", "a", "b"])
    }

    func testEmptyDropKeepsOrder() {
        XCTAssertEqual(DrawerAppDrop.frontOrder(existing: ["a", "b"], dropped: []), ["a", "b"])
    }

    func testAcceptsOnlyAppsInsideTheZone() {
        let capsule = CGRect(x: 100, y: 0, width: 60, height: 60)
        let zone = capsule.insetBy(dx: -DrawerAppDrop.capsuleTolerance, dy: -DrawerAppDrop.capsuleTolerance)
        XCTAssertTrue(DrawerAppDrop.accepts(containsApplication: true, point: CGPoint(x: 130, y: 30), zone: zone))
        // Inside the tolerance, e.g. the gap between bar and capsule.
        XCTAssertTrue(DrawerAppDrop.accepts(containsApplication: true, point: CGPoint(x: 93, y: 30), zone: zone))
        XCTAssertFalse(DrawerAppDrop.accepts(containsApplication: true, point: CGPoint(x: 91, y: 30), zone: zone))
        XCTAssertFalse(DrawerAppDrop.accepts(containsApplication: false, point: CGPoint(x: 130, y: 30), zone: zone))
    }
}

extension DrawerAppDropTests {
    func testPlacementFollowsTheCellUnderThePointer() {
        let frames = ["a": CGRect(x: 0, y: 0, width: 100, height: 100),
                      "b": CGRect(x: 100, y: 0, width: 100, height: 100)]
        let order = ["a", "b"]
        XCTAssertEqual(DrawerAppDrop.placement(at: CGPoint(x: 20, y: 50), frames: frames, order: order), .before("a"))
        XCTAssertEqual(DrawerAppDrop.placement(at: CGPoint(x: 80, y: 50), frames: frames, order: order), .after("a"))
        XCTAssertEqual(DrawerAppDrop.placement(at: CGPoint(x: 120, y: 50), frames: frames, order: order), .before("b"))
        // Off every cell (title row, space past the last cell): the end.
        XCTAssertEqual(DrawerAppDrop.placement(at: CGPoint(x: 150, y: 150), frames: frames, order: order), .end)
    }

    func testOrderAtEveryPlacement() {
        let existing = ["a", "b", "c"]
        XCTAssertEqual(DrawerAppDrop.order(existing: existing, dropped: ["x"], placement: .end), ["a", "b", "c", "x"])
        XCTAssertEqual(DrawerAppDrop.order(existing: existing, dropped: ["x"], placement: .before("b")), ["a", "x", "b", "c"])
        XCTAssertEqual(DrawerAppDrop.order(existing: existing, dropped: ["x"], placement: .after("b")), ["a", "b", "x", "c"])
        XCTAssertEqual(DrawerAppDrop.order(existing: existing, dropped: ["x", "y"], placement: .after("c")), ["a", "b", "c", "x", "y"])
    }

    func testExistingMemberMovesBesideTheTarget() {
        XCTAssertEqual(DrawerAppDrop.order(existing: ["a", "b", "c"], dropped: ["a"], placement: .after("c")), ["b", "c", "a"])
        XCTAssertEqual(DrawerAppDrop.order(existing: ["a", "b", "c"], dropped: ["c"], placement: .before("a")), ["c", "a", "b"])
    }

    func testTargetThatIsNoMemberLandsAtTheEnd() {
        XCTAssertEqual(DrawerAppDrop.order(existing: ["a", "b"], dropped: ["x"], placement: .before("gone")), ["a", "b", "x"])
        // Dropping onto the cell being moved itself: it has left the order, so it goes last.
        XCTAssertEqual(DrawerAppDrop.order(existing: ["a", "b"], dropped: ["a"], placement: .after("a")), ["b", "a"])
    }

    func testPlainFilesAreRefused() {
        let zone = CGRect(x: 0, y: 0, width: 300, height: 200)
        XCTAssertFalse(DrawerAppDrop.accepts(containsApplication: false, point: CGPoint(x: 150, y: 100), zone: zone))
    }
}

// MARK: - The make-way slot of an outside drag over the open drawer

extension DrawerAppDropTests {
    /// a | x(slot) | b, one row of 100pt cells.
    private var slotFrames: [String: CGRect] {
        ["a": CGRect(x: 0, y: 0, width: 100, height: 100),
         "x": CGRect(x: 100, y: 0, width: 100, height: 100),
         "b": CGRect(x: 200, y: 0, width: 100, height: 100)]
    }

    func testSlotFollowsTheMidlineOfAnotherCell() {
        let order = ["a", "x", "b"]
        XCTAssertEqual(DrawerAppDrop.hoverPlacement(current: .after("a"), point: CGPoint(x: 20, y: 50),
                                                    frames: slotFrames, displayOrder: order, ghostIDs: ["x"]),
                       .before("a"))
        XCTAssertEqual(DrawerAppDrop.hoverPlacement(current: .after("a"), point: CGPoint(x: 280, y: 50),
                                                    frames: slotFrames, displayOrder: order, ghostIDs: ["x"]),
                       .after("b"))
    }

    func testSlotStaysPutUnderThePointerAndOffEveryCell() {
        let order = ["a", "x", "b"]
        XCTAssertEqual(DrawerAppDrop.hoverPlacement(current: .after("a"), point: CGPoint(x: 150, y: 50),
                                                    frames: slotFrames, displayOrder: order, ghostIDs: ["x"]),
                       .after("a"))
        XCTAssertEqual(DrawerAppDrop.hoverPlacement(current: .after("a"), point: CGPoint(x: 150, y: 300),
                                                    frames: slotFrames, displayOrder: order, ghostIDs: ["x"]),
                       .after("a"))
    }

    func testFirstHoverOffEveryCellOpensTheSlotAtTheEnd() {
        let frames = ["a": CGRect(x: 0, y: 0, width: 100, height: 100)]
        XCTAssertEqual(DrawerAppDrop.hoverPlacement(current: nil, point: CGPoint(x: 150, y: 50),
                                                    frames: frames, displayOrder: ["a"], ghostIDs: ["new"]),
                       .end)
        XCTAssertEqual(DrawerAppDrop.hoverPlacement(current: nil, point: CGPoint(x: 20, y: 50),
                                                    frames: frames, displayOrder: ["a"], ghostIDs: ["new"]),
                       .before("a"))
    }

    /// An app already in the drawer, entering over its own cell: the slot is where the cell was.
    func testFirstHoverOverTheDraggedAppsOwnCellKeepsItWhereItIs() {
        let order = ["a", "x", "b"]
        let placement = DrawerAppDrop.hoverPlacement(current: nil, point: CGPoint(x: 150, y: 50),
                                                     frames: slotFrames, displayOrder: order, ghostIDs: ["x"])
        XCTAssertEqual(placement, .before("b"))
        XCTAssertEqual(ExternalDrawerGhost(ids: ["x"], placement: placement).displayOrder(visibleMembers: order), order)
        // The last cell has nothing after it.
        XCTAssertEqual(DrawerAppDrop.hoverPlacement(current: nil, point: CGPoint(x: 250, y: 50),
                                                    frames: slotFrames, displayOrder: order, ghostIDs: ["b"]),
                       .end)
    }

    func testGhostOrderMovesAMemberAndInsertsANewcomer() {
        let members = ["a", "b", "c"]
        // Already a member: its cell empties and the slot opens where the pointer is.
        XCTAssertEqual(ExternalDrawerGhost(ids: ["a"], placement: .after("c")).displayOrder(visibleMembers: members),
                       ["b", "c", "a"])
        // New: one more cell; the order the drop commits is the one shown.
        let ghost = ExternalDrawerGhost(ids: ["x", "y"], placement: .before("b"))
        XCTAssertEqual(ghost.displayOrder(visibleMembers: members), ["a", "x", "y", "b", "c"])
        XCTAssertEqual(ghost.displayOrder(visibleMembers: members),
                       DrawerAppDrop.order(existing: members, dropped: ghost.ids, placement: ghost.placement))
    }

    /// `.after(a)` and `.before(b)` are one slot: the view compares orders, not placements.
    func testTwoPlacementsCanShowTheSameSlot() {
        let members = ["a", "b"]
        XCTAssertNotEqual(DrawerAppDrop.Placement.after("a"), .before("b"))
        XCTAssertEqual(ExternalDrawerGhost(ids: ["x"], placement: .after("a")).displayOrder(visibleMembers: members),
                       ExternalDrawerGhost(ids: ["x"], placement: .before("b")).displayOrder(visibleMembers: members))
    }
}

// MARK: - The drag image turning into the drawer cell

extension DrawerAppDropTests {
    private var cellBitmap: CGSize { CGSize(width: 124.5, height: 114) }   // 112.5 × 102 + 6pt bleed
    private var cellIcon: CGRect {
        DrawerDragImageGeometry.iconRect(bitmapSize: cellBitmap, cellSize: CGSize(width: 112.5, height: 102),
                                         iconSize: 76, iconTop: 5)
    }

    func testCellIconSitsCentredUnderTheTopInset() {
        XCTAssertEqual(cellIcon, CGRect(x: 24.25, y: 114 - 6 - 5 - 76, width: 76, height: 76))
    }

    func testPointerKeepsItsPlaceOnTheIcon() {
        // Finder: icon component at (10, 20) inside an item framed at (100, 200); the pointer a
        // quarter across and three quarters up the 64pt icon.
        let itemFrame = CGRect(x: 100, y: 200, width: 84, height: 100)
        let component = CGRect(x: 10, y: 20, width: 64, height: 64)
        let pointer = CGPoint(x: 110 + 16, y: 220 + 48)
        let frame = DrawerDragImageGeometry.frame(itemFrame: itemFrame, iconComponent: component, pointer: pointer,
                                                  bitmapSize: cellBitmap, cellIconRect: cellIcon, backingScale: 2)
        XCTAssertEqual(frame.size, cellBitmap)
        let icon = cellIcon.offsetBy(dx: frame.minX, dy: frame.minY)
        XCTAssertEqual((pointer.x - icon.minX) / icon.width, 0.25, accuracy: 0.01)
        XCTAssertEqual((pointer.y - icon.minY) / icon.height, 0.75, accuracy: 0.01)
        // Moving the whole drag moves the result by the same amount.
        let moved = DrawerDragImageGeometry.frame(itemFrame: itemFrame.offsetBy(dx: 30, dy: -7), iconComponent: component,
                                                  pointer: CGPoint(x: pointer.x + 30, y: pointer.y - 7),
                                                  bitmapSize: cellBitmap, cellIconRect: cellIcon, backingScale: 2)
        XCTAssertEqual(moved.minX - frame.minX, 30, accuracy: 0.5)
        XCTAssertEqual(moved.minY - frame.minY, -7, accuracy: 0.5)
    }

    func testNoIconComponentUsesTheWholeFrameAndSnapsToPixels() {
        let frame = DrawerDragImageGeometry.frame(itemFrame: CGRect(x: 0.3, y: 0.3, width: 64, height: 64), iconComponent: nil,
                                                  pointer: CGPoint(x: 32.3, y: 32.3),
                                                  bitmapSize: cellBitmap, cellIconRect: cellIcon, backingScale: 2)
        XCTAssertEqual(frame.minX * 2, (frame.minX * 2).rounded())
        XCTAssertEqual(frame.minY * 2, (frame.minY * 2).rounded())
        XCTAssertEqual(frame.minX + cellIcon.midX, 32.3, accuracy: 0.5)
    }
}
