import XCTest

final class FolderContentsLoaderTests: XCTestCase {
    private func entry(
        _ name: String,
        isDirectory: Bool = false,
        added: TimeInterval? = nil,
        modified: TimeInterval? = nil
    ) -> FolderContentsLoader.Entry {
        FolderContentsLoader.Entry(
            url: URL(fileURLWithPath: "/tmp/\(name)"),
            name: name,
            isDirectory: isDirectory,
            dateAdded: added.map { Date(timeIntervalSince1970: $0) },
            dateModified: modified.map { Date(timeIntervalSince1970: $0) }
        )
    }

    func testSortedByDateAddedNewestFirst() {
        let sorted = FolderContentsLoader.sortedByDateAdded([
            entry("old", added: 100),
            entry("new", added: 300),
            entry("mid", added: 200),
        ])
        XCTAssertEqual(sorted.map(\.name), ["new", "mid", "old"])
    }

    func testMissingDateAddedFallsBackToModificationDate() {
        let sorted = FolderContentsLoader.sortedByDateAdded([
            entry("added-early", added: 100),
            entry("network-volume", added: nil, modified: 500),
        ])
        XCTAssertEqual(sorted.map(\.name), ["network-volume", "added-early"])
    }

    func testEqualDatesTieBreakByLocalizedName() {
        let sorted = FolderContentsLoader.sortedByDateAdded([
            entry("b.txt", added: 100),
            entry("a.txt", added: 100),
            entry("file10.txt", added: 100),
            entry("file2.txt", added: 100),
        ])
        // localizedStandardCompare: numbers sort by numeric value (file2 < file10).
        XCTAssertEqual(sorted.map(\.name), ["a.txt", "b.txt", "file2.txt", "file10.txt"])
    }

    func testEntriesWithNoDatesSortStablyByName() {
        let sorted = FolderContentsLoader.sortedByDateAdded([
            entry("zeta"),
            entry("alpha"),
        ])
        XCTAssertEqual(sorted.map(\.name), ["alpha", "zeta"])
    }
}
