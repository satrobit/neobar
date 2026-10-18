import XCTest

/// The list view's rows: 501 cut with a disabled "...", subfolder detection, the time-out level.
final class FolderListMenuPlanTests: XCTestCase {
    private func entry(_ name: String, directory: Bool = false, package: Bool = false,
                       alias: Bool = false) -> FolderContentsLoader.Entry {
        FolderContentsLoader.Entry(url: URL(fileURLWithPath: "/tmp/\(name)"), name: name, isDirectory: directory,
                                   dateAdded: nil, dateModified: nil, isPackage: package, isAlias: alias)
    }

    func testCutsAt501WithMore() {
        let entries = (0..<600).map { entry("f\($0)") }
        guard case let .rows(rows) = FolderListMenuPlan.listing(entries: entries, isSubfolder: { _ in false }) else {
            return XCTFail("expected rows")
        }
        XCTAssertEqual(rows.count, 502)
        XCTAssertEqual(rows.last, .more)
        XCTAssertEqual(rows[500], .file(entries[500]))
    }

    func testExactly501HasNoMore() {
        let entries = (0..<501).map { entry("f\($0)") }
        guard case let .rows(rows) = FolderListMenuPlan.listing(entries: entries, isSubfolder: { _ in false }) else {
            return XCTFail("expected rows")
        }
        XCTAssertEqual(rows.count, 501)
        XCTAssertFalse(rows.contains(.more))
    }

    func testTimedOutLevel() {
        XCTAssertEqual(FolderListMenuPlan.listing(entries: nil, isSubfolder: { _ in false }), .timedOut)
    }

    func testSubfolderDetection() {
        let neverFolder: (URL) -> Bool = { _ in false }
        let alwaysFolder: (URL) -> Bool = { _ in true }
        XCTAssertTrue(FolderListMenuPlan.isSubfolder(entry("dir", directory: true), aliasTargetIsFolder: neverFolder))
        XCTAssertFalse(FolderListMenuPlan.isSubfolder(entry("App.app", directory: true, package: true),
                                                      aliasTargetIsFolder: alwaysFolder))
        XCTAssertFalse(FolderListMenuPlan.isSubfolder(entry("file.txt"), aliasTargetIsFolder: alwaysFolder))
        XCTAssertTrue(FolderListMenuPlan.isSubfolder(entry("link", alias: true), aliasTargetIsFolder: alwaysFolder))
        XCTAssertFalse(FolderListMenuPlan.isSubfolder(entry("link", alias: true), aliasTargetIsFolder: neverFolder))
    }

    func testFilesAndSubfoldersKeepTheSortOrder() {
        let entries = [entry("b"), entry("a", directory: true), entry("c")]
        XCTAssertEqual(FolderListMenuPlan.listing(entries: entries, isSubfolder: { $0.isDirectory }),
                       .rows([.file(entries[0]), .subfolder(entries[1]), .file(entries[2])]))
    }
}
