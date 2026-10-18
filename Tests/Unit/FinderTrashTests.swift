import XCTest

final class FinderTrashTests: XCTestCase {
    func testPermissionAndPromptMatrix() {
        let mappings: [(Int32, FinderAutomationStatus)] = [(0, .granted), (-1743, .denied),
                                                         (-1744, .notDetermined), (-600, .unavailable)]
        for (code, status) in mappings {
            XCTAssertEqual(FinderAutomationStatus(osStatus: code), status)
            for trigger in TrashPermissionTrigger.allCases {
                XCTAssertEqual(trigger.shouldAskUser(status: status),
                               status == .notDetermined
                                   && (trigger == .ownDrop || trigger == .emptyCommand || trigger == .panelOpened))
            }
        }
    }

    /// A directory without a readable date still counts by path, so mounting or unmounting a
    /// volume changes the stamp even when its trash cannot be read.
    func testChangeStampKeepsUnreadableDirectoriesByPath() {
        let home = URL(fileURLWithPath: "/Users/x/.Trash")
        let volume = URL(fileURLWithPath: "/Volumes/v/.Trashes/501")
        let dates: [String: Date] = [home.path: Date(timeIntervalSince1970: 10)]
        let stamp = TrashChangeStamp.build(directories: [home, volume]) { dates[$0.path] }
        XCTAssertEqual(stamp.marks.count, 2)
        XCTAssertEqual(stamp.marks[home.path], Date(timeIntervalSince1970: 10))
        XCTAssertEqual(stamp.marks[volume.path], .some(nil))
        XCTAssertEqual(stamp, TrashChangeStamp.build(directories: [home, volume]) { dates[$0.path] })
        XCTAssertNotEqual(stamp, TrashChangeStamp.build(directories: [home]) { dates[$0.path] })
        XCTAssertNotEqual(stamp, TrashChangeStamp.build(directories: [home, volume]) { _ in Date(timeIntervalSince1970: 11) })
    }

    func testAllEventsWaitAndNeverPromptForConsent() {
        for options in [FinderTrashEvent.countOptions, FinderTrashEvent.emptyOptions,
                        FinderTrashEvent.emptyInteractiveOptions] {
            XCTAssertTrue(options.contains(.waitForReply))
            XCTAssertNotEqual(options.rawValue & FinderTrashEvent.noConsentPrompt, 0)
        }
        XCTAssertEqual(FinderTrashEvent.count, 0x636e7465)
        XCTAssertEqual(FinderTrashEvent.empty, 0x656d7074)
    }

    func testReplyErrorsAndMissingValuesAreNotSuccess() {
        let errors: [(Int, FinderTrashOutcome)] = [(-128, .cancelled), (-1712, .timedOut),
            (-1713, .needsInteraction), (-1743, .denied), (-1744, .wouldPrompt),
            (-600, .finderUnavailable), (-10000, .failed(-10000))]
        for (code, outcome) in errors {
            XCTAssertEqual(FinderTrashReply.parse(isCount: false, sendError: code, replyError: nil,
                                                  integer: nil, hasReply: false), outcome)
            XCTAssertEqual(FinderTrashReply.parse(isCount: false, sendError: nil, replyError: code,
                                                  integer: nil, hasReply: true), outcome)
        }
        XCTAssertEqual(FinderTrashReply.parse(isCount: false, sendError: nil, replyError: 0,
                                              integer: nil, hasReply: true), .succeeded)
        XCTAssertEqual(FinderTrashReply.parse(isCount: true, sendError: nil, replyError: nil,
                                              integer: nil, hasReply: true), .failed(-1700))
        XCTAssertEqual(FinderTrashReply.parse(isCount: false, sendError: nil, replyError: nil,
                                              integer: nil, hasReply: false), .failed(-1708))
        XCTAssertEqual(FinderTrashReply.parse(isCount: true, sendError: nil, replyError: 0,
                                              integer: 5, hasReply: true), .count(5))
    }

    func testStaleReadsCannotChangeFullnessOrPermission() {
        var state = TrashStateReducer()
        state.setPermission(.granted)
        let epoch = state.epoch
        let op = state.mutationBegan()
        _ = state.mutationEnded(op, successfulDirection: true)
        state.readReturned(epoch: epoch, source: .external, status: .granted, outcome: .count(0))
        XCTAssertTrue(state.isFull)
        state.setPermission(.denied)
        state.readReturned(epoch: epoch, source: .external, status: .granted, outcome: .count(5))
        XCTAssertEqual(state.status, .denied)
        XCTAssertFalse(state.isFull)
    }

    func testIsolatedSuccessProtectsOnlyImmediateRead() {
        var state = TrashStateReducer()
        state.setPermission(.granted)
        let op = state.mutationBegan()
        let source = state.mutationEnded(op, successfulDirection: true)!
        state.readReturned(epoch: state.epoch, source: source, status: .granted, outcome: .count(0))
        XCTAssertTrue(state.isFull)
        XCTAssertTrue(state.needsAuthoritativeRead)
        state.readReturned(epoch: state.epoch, source: .external, status: .granted, outcome: .count(0))
        XCTAssertFalse(state.isFull)
    }

    func testOverlappingOperationsUseTruthInEitherCompletionOrder() {
        for emptyFirst in [true, false] {
            var state = TrashStateReducer()
            state.setPermission(.granted)
            let drop = state.mutationBegan()
            let empty = state.mutationBegan()
            XCTAssertNil(state.mutationEnded(emptyFirst ? empty : drop, successfulDirection: !emptyFirst))
            let source = state.mutationEnded(emptyFirst ? drop : empty, successfulDirection: emptyFirst)
            XCTAssertEqual(source, .external)
            state.readReturned(epoch: state.epoch, source: source!, status: .granted, outcome: .count(0))
            XCTAssertFalse(state.isFull)
            XCTAssertFalse(state.needsAuthoritativeRead)
        }
    }

    func testFailureAndDisableNeverApplyDirectionOrLateResults() {
        var state = TrashStateReducer()
        state.setPermission(.granted)
        let op = state.mutationBegan()
        XCTAssertEqual(state.mutationEnded(op, successfulDirection: nil), .external)
        state.readReturned(epoch: state.epoch, source: .external, status: .granted, outcome: .count(3))
        let epoch = state.epoch
        state.disabled()
        state.readReturned(epoch: epoch, source: .external, status: .denied, outcome: .denied)
        XCTAssertTrue(state.isFull)
        XCTAssertEqual(state.status, .granted)
    }

    func testClickTargetsTheExistingTrashWindowInsteadOfOpeningAnother() {
        func entry(_ id: String, _ title: String, _ marker: WindowMenuEntry.Marker) -> WindowMenuEntry {
            WindowMenuEntry(actionWindowID: id, title: title, marker: marker)
        }
        let known = TrashWindowLookup.titles(localizedName: nil)
        XCTAssertNil(TrashWindowLookup.actionWindowID(
            finderWindows: [entry("docs", "Documents", .front)], titles: known))
        // The front Trash window wins.
        XCTAssertEqual(TrashWindowLookup.actionWindowID(
            finderWindows: [entry("min", "废纸篓", .minimized), entry("vis", "Trash", .none),
                            entry("front", "废纸篓", .front)], titles: known), "front")
        XCTAssertEqual(TrashWindowLookup.actionWindowID(
            finderWindows: [entry("min", "Trash", .minimized), entry("vis", "Trash", .none)],
            titles: known), "vis")
        // A minimized one is restored rather than opening a new window.
        XCTAssertEqual(TrashWindowLookup.actionWindowID(
            finderWindows: [entry("min", "Corbeille", .minimized)],
            titles: TrashWindowLookup.titles(localizedName: "Corbeille")), "min")
    }

    func testListingParsesFinderURLsSortsAndTruncates() {
        let listing = TrashListingPlan.build(urlStrings: [
            "file:///Users/me/.Trash/b%20doc.pdf", "file:///Users/me/.Trash/Folder/",
            "not a url", "file:///Users/me/.Trash/a.png"
        ], limit: 2)
        guard case let .loaded(items, hidden) = listing else { return XCTFail("\(listing)") }
        XCTAssertEqual(items.map(\.name), ["a.png", "b doc.pdf"])
        XCTAssertEqual(hidden, 1)
        XCTAssertFalse(items[0].isDirectory)
        XCTAssertEqual(TrashListingPlan.build(urlStrings: ["file:///Users/me/.Trash/Folder/"]),
                       .loaded(items: [TrashItem(url: URL(string: "file:///Users/me/.Trash/Folder/")!,
                                                 name: "Folder", isDirectory: true)], hiddenCount: 0))
        XCTAssertEqual(TrashListingPlan.build(urlStrings: []), .loaded(items: [], hiddenCount: 0))
    }

    func testTrashPathsMatchWholeComponentsOnlyInsideATrash() {
        let home = URL(fileURLWithPath: "/Users/me", isDirectory: true)
        let inside = ["/Users/me/.Trash/a.txt", "/Users/me/.Trash/Folder/", "/Users/me/.Trash/App.app",
                      "/.Trashes/501/a.txt", "/Volumes/Disk/.Trashes/501/a.txt"]
        let outside = ["/Users/me/.Trash", "/Users/me/.Trash/", "/Users/me/.TrashCan/a.txt", "/Users/me/Desktop/.Trash/a.txt",
                       "/Users/other/.Trash/a.txt", "/Volumes/Disk/.Trashes/501", "/Volumes/Disk/Folder/.Trashes/501/a.txt",
                       "/Users/me/Desktop/a.txt"]
        for path in inside { XCTAssertTrue(TrashPath.isInsideTrash(URL(fileURLWithPath: path), homeDirectory: home), path) }
        for path in outside { XCTAssertFalse(TrashPath.isInsideTrash(URL(fileURLWithPath: path), homeDirectory: home), path) }
        XCTAssertFalse(TrashPath.isInsideTrash(URL(string: "https://example.com/.Trash/a")!, homeDirectory: home))
    }

    func testTrashItemDragsAreRefusedEverywhereOnTheBar() {
        let shelf = CGRect(x: 100, y: 0, width: 44, height: 52)
        let trash = CGRect(x: 400, y: 0, width: 40, height: 52)
        let folders = ["folder-/a": CGRect(x: 152, y: 0, width: 52, height: 52)]
        for x: CGFloat in [10, 120, 170, 300, 420] {
            for isApp in [false, true] {
                XCTAssertEqual(StripDropRouting.route(location: CGPoint(x: x, y: 20), isApplicationDrag: isApp,
                                                      isTrashItemDrag: true, shelfFrame: shelf, trashFrame: trash,
                                                      folderFrames: folders, orderedPaths: ["/a"]), .none)
            }
        }
    }

    func testUnreadableIsNeverMissing() {
        XCTAssertEqual(FileReachability.classify(result: 0, errorNumber: 0), .exists)
        XCTAssertEqual(FileReachability.classify(result: -1, errorNumber: ENOENT), .missing)
        XCTAssertEqual(FileReachability.classify(result: -1, errorNumber: ENOTDIR), .missing)
        for code in [EPERM, EACCES, EIO] {
            XCTAssertEqual(FileReachability.classify(result: -1, errorNumber: code), .inaccessible)
        }
        XCTAssertEqual(FileReachability.of(path: "/tmp/neobar-definitely-missing-\(UUID().uuidString)"), .missing)
    }

    private func finderRecord(_ id: String, _ title: String, group: String? = nil,
                              bundle: String = "com.apple.finder") -> WindowRecord {
        WindowRecord(id: WindowID(rawValue: id), appID: AppID(rawValue: bundle), pid: 100,
                     bundleIdentifier: bundle, title: title, bounds: nil, status: .inactive,
                     cgWindowID: 1, groupID: group ?? id)
    }

    private func snapshot(_ records: [WindowRecord]) -> DockSnapshot {
        DockSnapshot(windows: Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) }),
                     orderedWindowIDs: records.map(\.id))
    }

    func testTrashWindowCardIsAbsorbedOnlyWhileFinderKeepsAnotherCard() {
        let titles = TrashWindowLookup.titles(localizedName: nil)
        let trash = finderRecord("cgw-1", "废纸篓")
        let docs = finderRecord("cgw-2", "归档")
        let withOther = snapshot([docs, trash])
        XCTAssertEqual(TrashWindowAbsorption.absorbedWindowIDs(in: withOther, trashTitles: titles),
                       [trash.id])
        // The remaining Finder card counts alone again, so it renders as the bare icon.
        let items = StripItem.items(from: TrashWindowAbsorption.removing([trash.id], from: withOther))
        XCTAssertEqual(items.map(\.id), [docs.id.rawValue])
        XCTAssertFalse(items[0].showsTitle)
        // A lone Trash window is the only Finder card: absorbing it would take Finder off the bar.
        XCTAssertTrue(TrashWindowAbsorption.absorbedWindowIDs(in: snapshot([trash]), trashTitles: titles).isEmpty)
        // A tab group showing the Trash tab keeps its card.
        let tabbed = snapshot([docs, finderRecord("cgw-3", "废纸篓", group: "tabgrp-1"),
                               finderRecord("cgw-4", "下载", group: "tabgrp-1")])
        XCTAssertTrue(TrashWindowAbsorption.absorbedWindowIDs(in: tabbed, trashTitles: titles).isEmpty)
        // Another app's window titled "Trash" is not Finder's.
        let other = snapshot([docs, finderRecord("cgw-5", "Trash", bundle: "com.example.mail")])
        XCTAssertTrue(TrashWindowAbsorption.absorbedWindowIDs(in: other, trashTitles: titles).isEmpty)
    }

    func testMenusDoNotDependOnCachedFullness() {
        XCTAssertEqual(TrashMenuPlan.items(status: .denied, isEmptying: false), [.open])
        XCTAssertEqual(TrashMenuPlan.items(status: .notDetermined, isEmptying: false), [.open, .empty(enabled: true)])
        XCTAssertEqual(TrashMenuPlan.items(status: .granted, isEmptying: true), [.open, .empty(enabled: false)])
    }
}
