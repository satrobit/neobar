import Foundation
import XCTest

final class FolderDropPlanTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDownWithError() throws {
        roots.forEach { try? FileManager.default.removeItem(at: $0) }
        roots.removeAll()
        try super.tearDownWithError()
    }

    func testFiltersSourceThatIsDestination() throws {
        let root = try makeRoot()
        XCTAssertTrue(FolderDropPlan.eligibleSources([root], destination: root).isEmpty)
    }

    func testFiltersItemAlreadyInsideDestination() throws {
        let root = try makeRoot()
        let destination = try directory("destination", in: root)
        let file = destination.appendingPathComponent("inside.txt")
        try Data().write(to: file)

        XCTAssertTrue(FolderDropPlan.eligibleSources([file], destination: destination).isEmpty)
    }

    func testFiltersDestinationInsideSourceDirectory() throws {
        let root = try makeRoot()
        let source = try directory("source", in: root)
        let destination = try directory("child", in: source)

        XCTAssertTrue(FolderDropPlan.eligibleSources([source], destination: destination).isEmpty)
    }

    func testParentSelectionSuppressesSelectedChild() throws {
        let root = try makeRoot()
        let source = try directory("source", in: root)
        let child = source.appendingPathComponent("child.txt")
        try Data().write(to: child)
        let destination = try directory("destination", in: root)

        let eligible = FolderDropPlan.eligibleSources([child, source], destination: destination)

        XCTAssertEqual(eligible, [source.standardizedFileURL])
    }

    func testDuplicateSourceAppearsOnce() throws {
        let root = try makeRoot()
        let source = root.appendingPathComponent("source.txt")
        try Data().write(to: source)
        let destination = try directory("destination", in: root)

        XCTAssertEqual(FolderDropPlan.eligibleSources([source, source], destination: destination),
                       [source.standardizedFileURL])
    }

    func testPathPrefixIsNotTreatedAsDescendant() throws {
        let root = try makeRoot()
        let source = try directory("a", in: root)
        let similarlyNamed = try directory("abc", in: root)
        let destination = try directory("destination", in: similarlyNamed)

        XCTAssertEqual(FolderDropPlan.eligibleSources([source], destination: destination),
                       [source.standardizedFileURL])
    }

    func testSymbolicLinkIsMovedAsLeafNotTreatedAsTargetDirectory() throws {
        let root = try makeRoot()
        let destination = try directory("destination", in: root)
        let link = root.appendingPathComponent("destination-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination)

        XCTAssertEqual(FolderDropPlan.eligibleSources([link], destination: destination),
                       [link.standardizedFileURL])
    }

    func testStandardizedParentDetectsAlreadyInsideDestination() throws {
        let root = try makeRoot()
        let destination = try directory("destination", in: root)
        let file = destination.appendingPathComponent("inside.txt")
        try Data().write(to: file)
        let nonstandard = destination.appendingPathComponent("sub/../inside.txt")

        XCTAssertTrue(FolderDropPlan.eligibleSources([nonstandard], destination: destination).isEmpty)
    }

    private func makeRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FolderDropPlanTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        roots.append(url)
        return url
    }

    private func directory(_ name: String, in parent: URL) throws -> URL {
        let url = parent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
