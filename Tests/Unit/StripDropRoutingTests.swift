import XCTest

/// Pure function for the geometric routing of external files dragged onto the taskbar (StripDropRouting.route).
/// Layout assumption: in "strip" space, the shelf is at x=100..144, and folder chips are 52pt wide with 8pt spacing, laid out from x=152.
final class StripDropRoutingTests: XCTestCase {
    func testTrashRoutingAndApplicationPriority() {
        let trash = CGRect(x: 320, y: 0, width: 40, height: 54)
        for shelf: CGRect? in [nil, .zero, CGRect(x: 0, y: 0, width: 40, height: 54)] {
            for x: CGFloat in [320, 340, 360, 380] {
                XCTAssertEqual(StripDropRouting.route(location: CGPoint(x: x, y: 20), isApplicationDrag: false, isTrashItemDrag: false,
                    shelfFrame: shelf, trashFrame: trash, folderFrames: [:], orderedPaths: []), .trash)
                XCTAssertEqual(StripDropRouting.route(location: CGPoint(x: x, y: 20), isApplicationDrag: true, isTrashItemDrag: false,
                    shelfFrame: shelf, trashFrame: trash, folderFrames: [:], orderedPaths: []), .keepApp)
            }
        }
        for frame: CGRect? in [nil, .zero] {
            XCTAssertEqual(StripDropRouting.route(location: CGPoint(x: 350, y: 20), isApplicationDrag: false, isTrashItemDrag: false,
                shelfFrame: nil, trashFrame: frame, folderFrames: [:], orderedPaths: []), .none)
        }
    }
    private let shelf = CGRect(x: 100, y: 0, width: 44, height: 52)

    private func frames(_ paths: [String], startX: CGFloat = 152) -> [String: CGRect] {
        var result: [String: CGRect] = [:]
        var x = startX
        for path in paths {
            result["folder-" + path] = CGRect(x: x, y: 0, width: 52, height: 52)
            x += 60
        }
        return result
    }

    func testHitShelfStashes() {
        let target = StripDropRouting.route(location: CGPoint(x: 120, y: 26),
                                            isApplicationDrag: false, isTrashItemDrag: false,
                                            shelfFrame: shelf, trashFrame: nil, folderFrames: [:], orderedPaths: [])
        XCTAssertEqual(target, .stash)
    }

    func testLeftOfShelfIsNone() {
        let target = StripDropRouting.route(location: CGPoint(x: 50, y: 26),
                                            isApplicationDrag: false, isTrashItemDrag: false,
                                            shelfFrame: shelf, trashFrame: nil, folderFrames: [:], orderedPaths: [])
        XCTAssertEqual(target, .none)
    }

    func testZeroShelfFrameRejectsEverything() {
        let target = StripDropRouting.route(location: CGPoint(x: 120, y: 26),
                                            isApplicationDrag: false, isTrashItemDrag: false,
                                            shelfFrame: .zero, trashFrame: nil, folderFrames: [:], orderedPaths: [])
        XCTAssertEqual(target, .none)
    }

    func testNoFoldersPinsAtZeroJustLeftOfTheTrash() {
        // No pinned folder yet: the zone is the Trash alone and its head slack is the first-pin target.
        let trash = CGRect(x: 320, y: 0, width: 40, height: 54)
        func route(_ x: CGFloat, trash: CGRect?) -> StripDropRouting.Target {
            StripDropRouting.route(location: CGPoint(x: x, y: 26), isApplicationDrag: false, isTrashItemDrag: false,
                                   shelfFrame: shelf, trashFrame: trash, folderFrames: [:], orderedPaths: [])
        }
        XCTAssertEqual(route(315, trash: trash), .pin(insertIndex: 0))
        XCTAssertEqual(route(311, trash: trash), .none)
        // The shelf no longer heads the folder zone: beside it is not a pin target.
        XCTAssertEqual(route(160, trash: trash), .none)
        XCTAssertEqual(route(160, trash: nil), .none)
    }

    func testDropOnLeftHalfOfFirstFolderMovesIntoIt() {
        let paths = ["/a", "/b"]
        // The first chip spans 152..204; both its left and right halves belong to the move-into target.
        let target = StripDropRouting.route(location: CGPoint(x: 160, y: 26),
                                            isApplicationDrag: false, isTrashItemDrag: false,
                                            shelfFrame: shelf, trashFrame: nil, folderFrames: frames(paths), orderedPaths: paths)
        XCTAssertEqual(target, .moveInto(path: "/a"))
    }

    func testDropOnRightHalfOfFirstFolderMovesIntoIt() {
        let paths = ["/a", "/b"]
        let target = StripDropRouting.route(location: CGPoint(x: 190, y: 26),
                                            isApplicationDrag: false, isTrashItemDrag: false,
                                            shelfFrame: shelf, trashFrame: nil, folderFrames: frames(paths), orderedPaths: paths)
        XCTAssertEqual(target, .moveInto(path: "/a"))
    }

    func testDropUsesHorizontalChipBand() {
        let paths = ["/a"]
        let target = StripDropRouting.route(location: CGPoint(x: 180, y: 200),
                                            isApplicationDrag: false, isTrashItemDrag: false,
                                            shelfFrame: shelf, trashFrame: nil, folderFrames: frames(paths), orderedPaths: paths)
        XCTAssertEqual(target, .moveInto(path: "/a"))
    }

    func testGapBetweenFoldersStillPins() {
        let paths = ["/a", "/b"]
        // The first one's right edge is 204 and the second's left edge is 212; x=208 is the real 8pt gap.
        let target = StripDropRouting.route(location: CGPoint(x: 208, y: 26),
                                            isApplicationDrag: false, isTrashItemDrag: false,
                                            shelfFrame: shelf, trashFrame: nil, folderFrames: frames(paths), orderedPaths: paths)
        XCTAssertEqual(target, .pin(insertIndex: 1))
    }

    func testMissingFrameDoesNotBecomeMoveTarget() {
        let paths = ["/a", "/b"]
        let partial = ["folder-/b": CGRect(x: 212, y: 0, width: 52, height: 52)]
        let target = StripDropRouting.route(location: CGPoint(x: 206, y: 26),
                                            isApplicationDrag: false, isTrashItemDrag: false,
                                            shelfFrame: shelf, trashFrame: nil, folderFrames: partial, orderedPaths: paths)
        XCTAssertEqual(target, .pin(insertIndex: 0))
    }

    func testTailSlackAfterLastFolderPinsAtEnd() {
        let paths = ["/a", "/b"]
        // The second chip's right edge is 264; within the +24 slack -> append at the last position (2).
        let target = StripDropRouting.route(location: CGPoint(x: 276, y: 26),
                                            isApplicationDrag: false, isTrashItemDrag: false,
                                            shelfFrame: shelf, trashFrame: nil, folderFrames: frames(paths), orderedPaths: paths)
        XCTAssertEqual(target, .pin(insertIndex: 2))
    }

    func testFarRightIsNone() {
        let paths = ["/a", "/b"]
        let target = StripDropRouting.route(location: CGPoint(x: 400, y: 26),
                                            isApplicationDrag: false, isTrashItemDrag: false,
                                            shelfFrame: shelf, trashFrame: nil, folderFrames: frames(paths), orderedPaths: paths)
        XCTAssertEqual(target, .none)
    }

    // MARK: - Shelf turned off (shelfFrame = nil)

    func testHiddenShelfStillMovesIntoFolders() {
        let paths = ["/a", "/b"]
        let target = StripDropRouting.route(location: CGPoint(x: 160, y: 26),
                                            isApplicationDrag: false, isTrashItemDrag: false,
                                            shelfFrame: nil, trashFrame: nil, folderFrames: frames(paths), orderedPaths: paths)
        XCTAssertEqual(target, .moveInto(path: "/a"))
    }

    func testHiddenShelfKeepsHeadSlackForInsertAtZero() {
        let paths = ["/a", "/b"]
        // The first chip's left edge is 152, headSlack 8 -> 144..152 is the only drop point for "insert at the very front".
        // Without this segment the whole first chip would be judged moveInto first, and inserting at position 0 could never be done.
        let target = StripDropRouting.route(location: CGPoint(x: 147, y: 26),
                                            isApplicationDrag: false, isTrashItemDrag: false,
                                            shelfFrame: nil, trashFrame: nil, folderFrames: frames(paths), orderedPaths: paths)
        XCTAssertEqual(target, .pin(insertIndex: 0))
    }

    func testHiddenShelfRejectsLeftOfHeadSlack() {
        let paths = ["/a"]
        let target = StripDropRouting.route(location: CGPoint(x: 120, y: 26),
                                            isApplicationDrag: false, isTrashItemDrag: false,
                                            shelfFrame: nil, trashFrame: nil, folderFrames: frames(paths), orderedPaths: paths)
        XCTAssertEqual(target, .none, "中转格关掉后，它原来的位置不能再接收任何拖放")
    }

    func testHiddenShelfStillPinsInGapAndTailSlack() {
        let paths = ["/a", "/b"]
        XCTAssertEqual(
            StripDropRouting.route(location: CGPoint(x: 208, y: 26),
                                   isApplicationDrag: false, isTrashItemDrag: false,
                                   shelfFrame: nil, trashFrame: nil, folderFrames: frames(paths), orderedPaths: paths),
            .pin(insertIndex: 1)
        )
        XCTAssertEqual(
            StripDropRouting.route(location: CGPoint(x: 276, y: 26),
                                   isApplicationDrag: false, isTrashItemDrag: false,
                                   shelfFrame: nil, trashFrame: nil, folderFrames: frames(paths), orderedPaths: paths),
            .pin(insertIndex: 2)
        )
    }

    func testHiddenShelfWithNoFoldersRejectsEverything() {
        // Shelf turned off + no pinned folders at all -> the folder zone doesn't exist as a whole, and the taskbar has no drop point at all.
        // This is an accepted boundary: the way back is re-checking "Show Shelf" in the menu.
        for x in [CGFloat(50), 120, 160, 400] {
            XCTAssertEqual(
                StripDropRouting.route(location: CGPoint(x: x, y: 26),
                                       isApplicationDrag: false, isTrashItemDrag: false,
                                       shelfFrame: nil, trashFrame: nil, folderFrames: [:], orderedPaths: []),
                .none
            )
        }
    }

    // MARK: - What's dragged is an app (safety boundary)

    /// **The most important one in this file**: an app only ever gets `.keepApp`.
    /// `.moveInto` is a real file move (move on the same volume, copy across volumes) -- letting one app slip in would mean moving it out of
    /// "Applications"; `.pin` would pin it as a folder tile that expands the internals of the `.app`
    ///(a real bug before 2026-09-07: the `.app` itself is a directory, and `isDirectoryKey` can't tell).
    func testApplicationDragNeverReachesAnyFileTarget() {
        let paths = ["/a", "/b"]
        let folders = frames(paths)
        // On the shelf, on the first folder tile, in the seams between tiles, tail slack, outside the strip, the strip's far-left end -- all covered.
        for x in [CGFloat(0), 50, 120, 147, 160, 190, 208, 276, 400, 2000] {
            for shelfFrame in [shelf, nil] {
                let target = StripDropRouting.route(location: CGPoint(x: x, y: 26),
                                                    isApplicationDrag: true, isTrashItemDrag: false,
                                                    shelfFrame: shelfFrame, trashFrame: nil,
                                                    folderFrames: folders, orderedPaths: paths)
                XCTAssertEqual(target, .keepApp, "x=\(x) shelf=\(String(describing: shelfFrame))")
            }
        }
    }

    /// Shelf turned off + no pinned folders at all = the file path has no drop point at all (an accepted boundary),
    /// but apps can still drop -- this is exactly the entry point this change adds.
    func testApplicationDragLandsEvenWithNoFileDropTargetAtAll() {
        for x in [CGFloat(50), 120, 160, 400] {
            XCTAssertEqual(
                StripDropRouting.route(location: CGPoint(x: x, y: 26),
                                       isApplicationDrag: true, isTrashItemDrag: false,
                                       shelfFrame: nil, trashFrame: nil,
                                       folderFrames: [:], orderedPaths: []),
                .keepApp
            )
        }
    }

    /// Reverse lock: when it isn't an app, `.keepApp` never shows up (otherwise ordinary files would also go and tick keep).
    func testNonApplicationDragNeverKeepsAnApp() {
        let paths = ["/a", "/b"]
        for x in [CGFloat(0), 50, 120, 147, 160, 208, 276, 400] {
            XCTAssertNotEqual(
                StripDropRouting.route(location: CGPoint(x: x, y: 26),
                                       isApplicationDrag: false, isTrashItemDrag: false,
                                       shelfFrame: shelf, trashFrame: nil,
                                       folderFrames: frames(paths), orderedPaths: paths),
                .keepApp
            )
        }
    }

    // MARK: - Make-way gap

    func testGhostInsertsBeforeOrAfterTheAnchor() {
        let ids = ["a", "b", "c"]
        XCTAssertEqual(StripDropRouting.ghostInsertionIndex(orderedIDs: ids, targetID: "a", after: false), 0)
        XCTAssertEqual(StripDropRouting.ghostInsertionIndex(orderedIDs: ids, targetID: "a", after: true), 1)
        XCTAssertEqual(StripDropRouting.ghostInsertionIndex(orderedIDs: ids, targetID: "c", after: true), 3)
    }

    /// The anchor was computed on the previous frame, and that card may no longer exist this frame (app quit / display filtering).
    /// It must land at the end and must never return an out-of-bounds index -- the projection layer feeds it straight to `insert(at:)`.
    func testGhostFallsToTailWhenAnchorIsGone() {
        let ids = ["a", "b"]
        XCTAssertEqual(StripDropRouting.ghostInsertionIndex(orderedIDs: ids, targetID: "gone", after: false), 2)
        XCTAssertEqual(StripDropRouting.ghostInsertionIndex(orderedIDs: ids, targetID: nil, after: true), 2)
        XCTAssertEqual(StripDropRouting.ghostInsertionIndex(orderedIDs: [], targetID: "a", after: true), 0)
    }

    /// **The crux of the gate**: when the pointer rests in the gap, the left and right cards are equidistant, and the decision would oscillate between "right of the left neighbor" and
    /// "left of the right neighbor" -- both point at the same empty slot. Folding to an index must normalize them, otherwise every oscillation
    /// is a pass of "position unchanged yet the whole taskbar recomputes".
    func testEquivalentAnchorsCollapseToTheSameSlot() {
        let ids = ["a", "b", "c"]
        XCTAssertEqual(
            StripDropRouting.ghostInsertionIndex(orderedIDs: ids, targetID: "a", after: true),
            StripDropRouting.ghostInsertionIndex(orderedIDs: ids, targetID: "b", after: false)
        )
        XCTAssertEqual(
            StripDropRouting.ghostInsertionIndex(orderedIDs: ids, targetID: "b", after: true),
            StripDropRouting.ghostInsertionIndex(orderedIDs: ids, targetID: "c", after: false)
        )
    }

    /// Criterion of the change gate. Feeding the same slot repeatedly must be judged "unchanged".
    func testGhostEqualityGatesRedraws() {
        let a = StripDropGhost(zone: .live(bundleID: "com.foo"), insertIndex: 2)
        XCTAssertEqual(a, StripDropGhost(zone: .live(bundleID: "com.foo"), insertIndex: 2))
        XCTAssertNotEqual(a, StripDropGhost(zone: .live(bundleID: "com.foo"), insertIndex: 3))
        XCTAssertNotEqual(a, StripDropGhost(zone: .live(bundleID: "com.other"), insertIndex: 2))
        XCTAssertNotEqual(a, StripDropGhost(zone: .folder, insertIndex: 2))
    }

    // MARK: - Folder dragged in: pin edges and the make-way gap

    private let edge = StripDropRouting.folderPinEdgeFraction

    /// 52pt chips → 13pt pin edges. /a is 152..204, /b is 212..264.
    func testFolderDragPinsFromTheChipEdgesAndMovesIntoTheCentre() {
        let paths = ["/a", "/b"]
        let expected: [(CGFloat, StripDropRouting.Target)] = [
            (160, .pin(insertIndex: 0)), (178, .moveInto(path: "/a")), (198, .pin(insertIndex: 1)),
            (208, .pin(insertIndex: 1)), (216, .pin(insertIndex: 1)), (238, .moveInto(path: "/b")),
            (258, .pin(insertIndex: 2)), (276, .pin(insertIndex: 2)),
        ]
        for (x, target) in expected {
            XCTAssertEqual(
                StripDropRouting.route(location: CGPoint(x: x, y: 26),
                                       isApplicationDrag: false, isTrashItemDrag: false,
                                       shelfFrame: shelf, trashFrame: nil, folderFrames: frames(paths),
                                       orderedPaths: paths, pinEdgeFraction: edge),
                target, "x=\(x)")
        }
    }

    /// Lays the folders out with the gap already open at `gapIndex`, as the strip renders them
    /// (the gap reports no frame), and returns the gap's own extent.
    private func layout(_ paths: [String], gapIndex: Int, startX: CGFloat = 152)
        -> (frames: [String: CGRect], gap: ClosedRange<CGFloat>) {
        var result: [String: CGRect] = [:]
        var x = startX
        var gap: ClosedRange<CGFloat> = startX...startX
        for index in 0...paths.count {
            if index == gapIndex { gap = x...(x + 52); x += 60 }
            guard index < paths.count else { break }
            result["folder-" + paths[index]] = CGRect(x: x, y: 0, width: 52, height: 52)
            x += 60
        }
        return (result, gap)
    }

    /// **The stability lock**: once the gap is open, a pointer anywhere inside it (and across the
    /// spacing and pin edges on both sides) must keep resolving to that same slot — any other
    /// answer closes the gap, which moves the chips, which reopens it.
    func testPointerInsideTheOpenGapKeepsResolvingToTheSameSlot() {
        let paths = ["/a", "/b"]
        for shelfFrame in [shelf, nil] {
            for gapIndex in 0...paths.count {
                let (folders, gap) = layout(paths, gapIndex: gapIndex)
                let openGap = StripDropRouting.OpenFolderGap(insertIndex: gapIndex, width: 60)
                // 6pt each side: the 8pt spacing short of the neighbour's own edge (the shelf at 144).
                for x in stride(from: gap.lowerBound - 6, through: gap.upperBound + 6, by: 2) {
                    let target = StripDropRouting.route(
                        location: CGPoint(x: x, y: 26), isApplicationDrag: false, isTrashItemDrag: false,
                        shelfFrame: shelfFrame, trashFrame: nil, folderFrames: folders, orderedPaths: paths,
                        pinEdgeFraction: edge, openGap: openGap)
                    XCTAssertEqual(target, .pin(insertIndex: gapIndex),
                                   "gap=\(gapIndex) x=\(x) shelf=\(String(describing: shelfFrame))")
                }
            }
        }
    }

    func testFirstPinGapNextToTheTrashStaysOpen() {
        // No folders yet: the gap opens left of the Trash (already pushed to 300) and is wider
        // than the head slack.
        let trash = CGRect(x: 300, y: 0, width: 40, height: 54)
        let openGap = StripDropRouting.OpenFolderGap(insertIndex: 0, width: 60)
        for x: CGFloat in [234, 260, 299] {
            XCTAssertEqual(
                StripDropRouting.route(location: CGPoint(x: x, y: 26), isApplicationDrag: false, isTrashItemDrag: false,
                                       shelfFrame: shelf, trashFrame: trash, folderFrames: [:], orderedPaths: [],
                                       pinEdgeFraction: edge, openGap: openGap),
                .pin(insertIndex: 0), "x=\(x)")
        }
    }

    /// The shelf lives in the pinned-app zone: its whole width stashes, folder drag or not.
    func testShelfStashesAcrossItsWholeWidthEvenForAFolderDrag() {
        for x in [shelf.minX, shelf.midX, shelf.maxX] {
            XCTAssertEqual(
                StripDropRouting.route(location: CGPoint(x: x, y: 26), isApplicationDrag: false, isTrashItemDrag: false,
                                       shelfFrame: shelf, trashFrame: nil, folderFrames: frames(["/a"], startX: 300),
                                       orderedPaths: ["/a"], pinEdgeFraction: StripDropRouting.folderPinEdgeFraction),
                .stash, "x=\(x)")
        }
    }

    /// A plain file among the folders keeps the old routing for the whole drag: on a chip's edge
    /// the folders would pin and the file would be left behind.
    func testOnlyAFoldersOnlyDragPinsFolders() {
        XCTAssertTrue(StripDropRouting.dragPinsFolders(nonApplicationItemsAreDirectories: [true]))
        XCTAssertTrue(StripDropRouting.dragPinsFolders(nonApplicationItemsAreDirectories: [true, true]))
        XCTAssertFalse(StripDropRouting.dragPinsFolders(nonApplicationItemsAreDirectories: [true, false]))
        XCTAssertFalse(StripDropRouting.dragPinsFolders(nonApplicationItemsAreDirectories: [false]))
        XCTAssertFalse(StripDropRouting.dragPinsFolders(nonApplicationItemsAreDirectories: []))
    }

    func testFolderGhostFollowsPinSticksOverAChipAndClosesElsewhere() {
        XCTAssertEqual(StripDropRouting.folderGhostIndex(current: nil, target: .pin(insertIndex: 1), pinsFolder: true), 1)
        XCTAssertEqual(StripDropRouting.folderGhostIndex(current: 1, target: .pin(insertIndex: 2), pinsFolder: true), 2)
        // Over a chip's centre the gap stays put, and none opens if there was none.
        XCTAssertEqual(StripDropRouting.folderGhostIndex(current: 1, target: .moveInto(path: "/a"), pinsFolder: true), 1)
        XCTAssertNil(StripDropRouting.folderGhostIndex(current: nil, target: .moveInto(path: "/a"), pinsFolder: true))
        for target: StripDropRouting.Target in [.stash, .trash, .none, .keepApp] {
            XCTAssertNil(StripDropRouting.folderGhostIndex(current: 1, target: target, pinsFolder: true), "\(target)")
        }
        // A plain file never opens a gap: it cannot be pinned.
        XCTAssertNil(StripDropRouting.folderGhostIndex(current: nil, target: .pin(insertIndex: 1), pinsFolder: false))
    }

    func testHiddenShelfIgnoresStaleShelfCoordinates() {
        // The view side must pass nil rather than an old frame: this locks that "once nil is passed, the stash is never hit again".
        let paths = ["/a"]
        let onShelfSpot = CGPoint(x: 120, y: 26)
        XCTAssertEqual(
            StripDropRouting.route(location: onShelfSpot,
                                   isApplicationDrag: false, isTrashItemDrag: false,
                                   shelfFrame: shelf, trashFrame: nil, folderFrames: frames(paths), orderedPaths: paths),
            .stash
        )
        XCTAssertEqual(
            StripDropRouting.route(location: onShelfSpot,
                                   isApplicationDrag: false, isTrashItemDrag: false,
                                   shelfFrame: nil, trashFrame: nil, folderFrames: frames(paths), orderedPaths: paths),
            .none
        )
    }

    func testOnlyTheTrashAFolderPinSlotAndAnAppDropTheCursorBadge() {
        for pinsFolder in [true, false] {
            XCTAssertTrue(StripDropRouting.usesGenericOperation(hoveredTarget: .trash, pinsFolder: pinsFolder,
                                                                proposedIsCopy: true, sourceAllowsGeneric: true))
            // An app dragged in: the native Dock shows no badge either.
            XCTAssertTrue(StripDropRouting.usesGenericOperation(hoveredTarget: .keepApp, pinsFolder: pinsFolder,
                                                                proposedIsCopy: true, sourceAllowsGeneric: true))
            let others: [StripDropRouting.Target?] = [nil, .none, .stash, .moveInto(path: "/tmp/a")]
            for target in others {
                XCTAssertFalse(StripDropRouting.usesGenericOperation(hoveredTarget: target, pinsFolder: pinsFolder,
                                                                     proposedIsCopy: true, sourceAllowsGeneric: true),
                               "\(String(describing: target))")
            }
        }
        XCTAssertTrue(StripDropRouting.usesGenericOperation(hoveredTarget: .pin(insertIndex: 0), pinsFolder: true,
                                                            proposedIsCopy: true, sourceAllowsGeneric: true))
        // A plain file over a chip gap pins nothing; its badge is left alone.
        XCTAssertFalse(StripDropRouting.usesGenericOperation(hoveredTarget: .pin(insertIndex: 0), pinsFolder: false,
                                                             proposedIsCopy: true, sourceAllowsGeneric: true))
    }

    func testBadgeAnswerIsKeptWhenGenericIsNotOffered() {
        for target: StripDropRouting.Target in [.trash, .pin(insertIndex: 0), .keepApp] {
            // ⌥ held: the source offers copy only.
            XCTAssertFalse(StripDropRouting.usesGenericOperation(hoveredTarget: target, pinsFolder: true,
                                                                 proposedIsCopy: true, sourceAllowsGeneric: false))
            // A refusal (e.g. Trash items) stays a refusal.
            XCTAssertFalse(StripDropRouting.usesGenericOperation(hoveredTarget: target, pinsFolder: true,
                                                                 proposedIsCopy: false, sourceAllowsGeneric: true))
        }
    }

    private let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
    private let appA = URL(fileURLWithPath: "/Applications/A.app")
    private let appB = URL(fileURLWithPath: "/Applications/B.app")
    private let file = URL(fileURLWithPath: "/Users/tester/Downloads/note.txt")

    func testProvidersStayTheAuthorityWheneverAnyOfThemLoads() {
        // All loaded: the pasteboard is ignored even when it disagrees.
        XCTAssertEqual(StripDropRouting.committedURLs(loaded: [appA, file], pasteboard: [appB], homeDirectory: home),
                       [appA, file])
        // Partly loaded: only what loaded, never topped up from the pasteboard.
        XCTAssertEqual(StripDropRouting.committedURLs(loaded: [nil, file], pasteboard: [appA, file], homeDirectory: home),
                       [file])
    }

    func testInProcessDragFallsBackToThePasteboard() {
        // Our popup's provider cannot coerce to URL: every load is nil.
        XCTAssertEqual(StripDropRouting.committedURLs(loaded: [nil], pasteboard: [appA], homeDirectory: home), [appA])
        XCTAssertEqual(StripDropRouting.committedURLs(loaded: [nil, nil], pasteboard: [], homeDirectory: home), [])
    }

    func testCommittedURLsDropTrashItemsFromEitherSource() {
        let homeTrash = URL(fileURLWithPath: "/Users/tester/.Trash/old.txt")
        let volumeTrash = URL(fileURLWithPath: "/.Trashes/501/old.app")
        XCTAssertEqual(StripDropRouting.committedURLs(loaded: [homeTrash, file, volumeTrash], pasteboard: [], homeDirectory: home),
                       [file])
        XCTAssertEqual(StripDropRouting.committedURLs(loaded: [nil], pasteboard: [homeTrash, appA, volumeTrash], homeDirectory: home),
                       [appA])
        // Loaded but all in the Trash: the selection is not retried against the pasteboard.
        XCTAssertEqual(StripDropRouting.committedURLs(loaded: [homeTrash], pasteboard: [appA], homeDirectory: home), [])
    }

    func testOnlyAnAppDropSuppressesTheSystemDropAnimation() {
        XCTAssertTrue(StripDropRouting.suppressesSystemDropAnimation(hoveredTarget: .keepApp))
        let others: [StripDropRouting.Target?] = [nil, .none, .stash, .trash, .pin(insertIndex: 0),
                                                  .moveInto(path: "/tmp/a")]
        for target in others {
            XCTAssertFalse(StripDropRouting.suppressesSystemDropAnimation(hoveredTarget: target),
                           "\(String(describing: target))")
        }
    }

    func testOnlyAnAppNotYetAnywhereMayWidenTheBarWhileHovering() {
        XCTAssertTrue(StripDropRouting.appDropMayWidenOnHover(isRunning: false, isMessaging: false,
                                                              isFinder: false, hasEntryOnStrip: false))
        let blockers: [(Bool, Bool, Bool, Bool)] = [
            (true, false, false, false),
            (false, true, false, false),
            (false, false, true, false),
            (false, false, false, true),
        ]
        for b in blockers {
            XCTAssertFalse(StripDropRouting.appDropMayWidenOnHover(isRunning: b.0, isMessaging: b.1,
                                                                   isFinder: b.2, hasEntryOnStrip: b.3), "\(b)")
        }
    }
}
