import XCTest

/// Drop-target classification when a pinned-folder chip drag is released (FolderChipDropZone.classify).
/// Layout assumption: "strip" local coordinates, visible area 0..400 x 0..92; the pinned zone (including Trash) occupies the right end 200..400,
/// and to its left are the window zone and the messaging zone.
final class FolderChipDropZoneTests: XCTestCase {
    private let stripVisibleRect = CGRect(x: 0, y: 0, width: 400, height: 92)
    private let folderZoneMinX: CGFloat = 200
    private let screenRect = CGRect(x: 100, y: 500, width: 400, height: 92)

    private func classify(_ x: CGFloat, _ y: CGFloat = 40) -> FolderChipDropZone {
        FolderChipDropZone.classify(point: CGPoint(x: x, y: y), stripVisibleRect: stripVisibleRect,
                                    folderZoneMinX: folderZoneMinX)
    }

    func testEverythingFromTheZoneEdgeToTheBarEndIsFolderZone() {
        // The Trash is the zone's last cell, so a release over it is a no-op too.
        XCTAssertEqual(classify(200), .folderZone)
        XCTAssertEqual(classify(300), .folderZone)
        XCTAssertEqual(classify(399.9), .folderZone)
    }

    func testLeftOfTheZoneInsideTheStripIsLiveZone() {
        XCTAssertEqual(classify(199.9), .liveZone)
        XCTAssertEqual(classify(100), .liveZone)
        XCTAssertEqual(classify(0), .liveZone)
    }

    func testOutsideTheStripWinsWithNoBuffer() {
        // Owner feedback: the hit range is computed on the visible area with no large buffer -- just outside the boundary should be judged as moved out.
        XCTAssertEqual(classify(-10), .outsideStrip)
        XCTAssertEqual(classify(400.5), .outsideStrip)
        XCTAssertEqual(classify(300, -5), .outsideStrip)
        XCTAssertEqual(classify(300, 100), .outsideStrip)
    }

    func testScreenPointsConvertToStripSpace() {
        let geometry = FolderChipDropGeometry(stripScreenRect: screenRect, folderZoneMinX: folderZoneMinX)
        XCTAssertEqual(geometry.classify(screenPoint: CGPoint(x: 350, y: 552)), .folderZone)
        XCTAssertEqual(geometry.classify(screenPoint: CGPoint(x: 250, y: 552)), .liveZone)
        XCTAssertEqual(geometry.classify(screenPoint: CGPoint(x: 501, y: 552)), .outsideStrip)
        XCTAssertEqual(geometry.classify(screenPoint: CGPoint(x: 350, y: 600)), .outsideStrip)
    }

    func testZoneEdgeSurvivesTheOnlyFolderCollapsingOffTheBar() {
        // Frames present: they win, collapsed or not.
        XCTAssertEqual(FolderChipDropZone.zoneMinX(folderMinX: 200, draggedSlotCollapsed: false,
                                                   trashMinX: 340, stripWidth: 400), 200)
        XCTAssertEqual(FolderChipDropZone.zoneMinX(folderMinX: 200, draggedSlotCollapsed: true,
                                                   trashMinX: 340, stripWidth: 400), 200)
        // No frames and no collapse = not measured yet: no geometry, the drop is a no-op.
        XCTAssertNil(FolderChipDropZone.zoneMinX(folderMinX: nil, draggedSlotCollapsed: false,
                                                 trashMinX: 340, stripWidth: 400))
        // The only folder left the bar: the zone is the Trash alone, or the bar's right edge.
        XCTAssertEqual(FolderChipDropZone.zoneMinX(folderMinX: nil, draggedSlotCollapsed: true,
                                                   trashMinX: 340, stripWidth: 400), 340)
        XCTAssertEqual(FolderChipDropZone.zoneMinX(folderMinX: nil, draggedSlotCollapsed: true,
                                                   trashMinX: nil, stripWidth: 400), 400)
    }

    func testOnlyFolderDraggedOffTheBarStillUnpins() {
        for trashMinX: CGFloat? in [340, nil] {
            let minX = FolderChipDropZone.zoneMinX(folderMinX: nil, draggedSlotCollapsed: true,
                                                   trashMinX: trashMinX, stripWidth: 400)!
            let geometry = FolderChipDropGeometry(stripScreenRect: screenRect, folderZoneMinX: minX)
            XCTAssertEqual(geometry.classify(screenPoint: CGPoint(x: 300, y: 700)), .outsideStrip)
            XCTAssertEqual(geometry.classify(screenPoint: CGPoint(x: 250, y: 552)), .liveZone)
        }
    }

    func testUnmeasuredStripIsOutside() {
        let geometry = FolderChipDropGeometry(stripScreenRect: .zero, folderZoneMinX: folderZoneMinX)
        XCTAssertEqual(geometry.classify(screenPoint: CGPoint(x: 350, y: 552)), .outsideStrip)
    }
}
