import XCTest

/// The native Dock's view-mode choice and fan overflow, locked against the measured screen
/// (1512 × 982, menu bar 33, Dock 61).
final class FolderViewResolutionTests: XCTestCase {
    private let measuredStage = StackStage.height(screenHeightBelowMenuBar: 982 - 33, barOccupiedHeight: 61)

    func testMeasuredStageHeight() {
        XCTAssertEqual(measuredStage, 710)
        XCTAssertEqual(StackStage.maxFanItems(stageHeight: measuredStage), 11)
    }

    func testAutomaticFansUpToTenFilesOnTheMeasuredScreen() {
        XCTAssertEqual(FolderViewResolution.resolve(mode: .automatic, fileCount: 9, stageHeight: measuredStage),
                       .fan(fileItems: 9, hiddenCount: 0))
        XCTAssertEqual(FolderViewResolution.resolve(mode: .automatic, fileCount: 10, stageHeight: measuredStage),
                       .fan(fileItems: 10, hiddenCount: 0))
        XCTAssertEqual(FolderViewResolution.resolve(mode: .automatic, fileCount: 11, stageHeight: measuredStage), .grid)
        XCTAssertEqual(FolderViewResolution.resolve(mode: .automatic, fileCount: 12, stageHeight: measuredStage), .grid)
    }

    func testEmptyFolderFansToTheFinderCellAlone() {
        XCTAssertEqual(FolderViewResolution.resolve(mode: .automatic, fileCount: 0, stageHeight: measuredStage),
                       .fan(fileItems: 0, hiddenCount: 0))
    }

    func testForcedFanOverflowsIntoMoreInFinder() {
        // Measured: a forced fan of 30 files shows 11 items, the top one "20 More in Finder".
        XCTAssertEqual(FolderViewResolution.resolve(mode: .fan, fileCount: 30, stageHeight: measuredStage),
                       .fan(fileItems: 10, hiddenCount: 20))
        // One past the edge leaves exactly one hidden.
        XCTAssertEqual(FolderViewResolution.resolve(mode: .fan, fileCount: 11, stageHeight: measuredStage),
                       .fan(fileItems: 10, hiddenCount: 1))
    }

    func testExplicitGridAndListIgnoreTheCount() {
        XCTAssertEqual(FolderViewResolution.resolve(mode: .grid, fileCount: 1, stageHeight: measuredStage), .grid)
        XCTAssertEqual(FolderViewResolution.resolve(mode: .list, fileCount: 1, stageHeight: measuredStage), .list)
        XCTAssertEqual(FolderViewResolution.resolve(mode: .list, fileCount: 500, stageHeight: measuredStage), .list)
    }

    func testMoreInFinderCopySeparatesOne() {
        XCTAssertEqual(FolderViewResolution.moreInFinderCopy(hiddenCount: 1), .one)
        XCTAssertEqual(FolderViewResolution.moreInFinderCopy(hiddenCount: 2), .many)
        XCTAssertEqual(FolderViewResolution.moreInFinderCopy(hiddenCount: 20), .many)
    }
}

/// FolderViewMode: the default and the persisted / menu shape.
final class FolderViewModeTests: XCTestCase {
    func testDefaultIsAutomaticAsOnTheNativeDock() {
        XCTAssertEqual(FolderViewMode.default, .automatic)
    }

    func testMenuOrderIsTheNativeOrder() {
        XCTAssertEqual(FolderViewMode.allCases, [.fan, .grid, .list, .automatic])
    }

    func testRawValuesRoundTrip() {
        for mode in FolderViewMode.allCases {
            XCTAssertEqual(FolderViewMode(rawValue: mode.rawValue), mode)
        }
        XCTAssertNil(FolderViewMode(rawValue: ""))
    }
}

final class StackReopenCooldownTests: XCTestCase {
    func testSamePathIsRefusedForATenthOfASecond() {
        var cooldown = StackReopenCooldown()
        cooldown.noteClosed(path: "/a", at: 10)
        XCTAssertFalse(cooldown.allowsOpening(path: "/a", at: 10.05))
        XCTAssertTrue(cooldown.allowsOpening(path: "/a", at: 10.15))
    }

    func testAnotherPathOpensAtOnce() {
        var cooldown = StackReopenCooldown()
        cooldown.noteClosed(path: "/a", at: 10)
        XCTAssertTrue(cooldown.allowsOpening(path: "/b", at: 10.01))
    }

    func testNothingClosedAllowsEverything() {
        XCTAssertTrue(StackReopenCooldown().allowsOpening(path: "/a", at: 0))
    }
}

/// The fan's arc, locked against the native recording (10 items: 1.41° → 12.53°, 64pt apart).
final class StackFanLayoutTests: XCTestCase {
    private func degrees(_ radians: CGFloat) -> CGFloat { radians * 180 / .pi }

    func testFirstItemRiseFollowsTheTwoReadings() {
        XCTAssertEqual(StackFanLayout.firstItemRise(squareSide: 25.5), 67, accuracy: 0.01)
        XCTAssertEqual(StackFanLayout.firstItemRise(squareSide: 33), 73.5, accuracy: 0.01)
    }

    func testTenItemAnglesMatchTheNativeFan() {
        let layout = StackFanLayout(tileCenter: .zero, squareSide: 33,
                                    labelSizes: Array(repeating: CGSize(width: 80, height: 26), count: 10))
        // Native turns clockwise: negative angles.
        XCTAssertEqual(-degrees(layout.items[0].rotation), 1.41, accuracy: 0.06)
        XCTAssertEqual(-degrees(layout.items[9].rotation), 12.53, accuracy: 0.06)
    }

    func testItemsAre64ApartVerticallyAndLeanRight() {
        let layout = StackFanLayout(tileCenter: CGPoint(x: 100, y: 50), squareSide: 32.5,
                                    labelSizes: Array(repeating: CGSize(width: 80, height: 26), count: 4))
        XCTAssertEqual(layout.items[0].center.y, 50 + StackFanLayout.firstItemRise(squareSide: 32.5), accuracy: 0.001)
        for i in 1..<4 {
            XCTAssertEqual(layout.items[i].center.y - layout.items[i - 1].center.y, 64, accuracy: 0.001)
            XCTAssertGreaterThan(layout.items[i].center.x, layout.items[i - 1].center.x)
        }
    }

    func testLabelCapsuleSize() {
        XCTAssertEqual(StackFanLayout.labelSize(textSize: CGSize(width: 60, height: 16)), CGSize(width: 86, height: 26))
        XCTAssertEqual(StackFanLayout.labelSize(textSize: CGSize(width: 900, height: 16)), CGSize(width: 526, height: 26))
    }

    func testLabelSitsFivePointsLeftOfTheItem() {
        let item = StackFanLayout.Item(center: .zero, rotation: 0, labelSize: CGSize(width: 86, height: 26))
        let rect = StackFanLayout.labelRect(for: item)
        XCTAssertEqual(rect.maxX, -32 - 5)
        XCTAssertEqual(rect.midY, 0)
    }

    func testHitTestFollowsTheTurnedSquareNotTheCapsule() {
        let layout = StackFanLayout(tileCenter: .zero, squareSide: 32.5,
                                    labelSizes: [CGSize(width: 86, height: 26)])
        let item = layout.items[0]
        XCTAssertEqual(layout.itemIndex(at: item.center), 0)
        // The capsule's middle is not the item.
        XCTAssertNil(layout.itemIndex(at: CGPoint(x: item.center.x - 32 - 5 - 43, y: item.center.y)))
    }

    func testBoundingBoxHoldsCapsulesAndShadows() {
        let layout = StackFanLayout(tileCenter: .zero, squareSide: 32.5,
                                    labelSizes: [CGSize(width: 86, height: 26)])
        let box = layout.boundingBox
        XCTAssertLessThanOrEqual(box.minX, layout.items[0].center.x - 32 - 5 - 86)
        XCTAssertLessThanOrEqual(box.minY, layout.items[0].center.y - 15 - 48)
    }
}

final class FolderCoverPileTests: XCTestCase {
    func testFrontLayerSitsLowAndLargest() {
        let front = FolderCoverPile.layerRect(0, slotCenter: .zero, slot: 40)
        let back = FolderCoverPile.layerRect(2, slotCenter: .zero, slot: 40)
        XCTAssertEqual(front.width, 37, accuracy: 0.001)
        XCTAssertLessThan(front.midY, back.midY, "the back of the pile climbs (screen y up)")
        XCTAssertEqual(FolderCoverPile.layerRect(7, slotCenter: .zero, slot: 40), back)
    }
}
