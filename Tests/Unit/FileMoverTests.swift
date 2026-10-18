import Foundation
import XCTest

final class FileMoverTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDownWithError() throws {
        roots.forEach { try? FileManager.default.removeItem(at: $0) }
        roots.removeAll()
        try super.tearDownWithError()
    }

    func testLiveFileSystemMovesSameVolumeItem() throws {
        let root = try makeRoot()
        let source = root.appendingPathComponent("source.txt")
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        try Data("payload".utf8).write(to: source)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let result = FileMover().move([source], into: destination)

        XCTAssertEqual(result.succeeded, [source])
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("source.txt").path))
    }

    func testExistingFinalNameIsConflictAndNeverOverwritten() {
        let fs = FakeFileSystem()
        let source = URL(fileURLWithPath: "/source/x.pdf")
        let destination = URL(fileURLWithPath: "/destination", isDirectory: true)
        fs.existing = [source.path, destination.path, destination.appendingPathComponent("x.pdf").path]

        let result = FileMover(fileSystem: fs).move([source], into: destination)

        XCTAssertEqual(result.conflicts, [source])
        XCTAssertTrue(fs.copyCalls.isEmpty)
        XCTAssertTrue(fs.moveCalls.isEmpty)
    }

    func testDifferentVolumesCopyThenCommitAndPreserveSource() {
        let fs = FakeFileSystem()
        let source = URL(fileURLWithPath: "/source/x.pdf")
        let destination = URL(fileURLWithPath: "/destination", isDirectory: true)
        fs.existing = [source.path, destination.path]
        fs.volumes[source.path] = "source-volume"
        fs.volumes[destination.path] = "destination-volume"

        let result = FileMover(fileSystem: fs, temporaryName: { _ in ".temp" })
            .move([source], into: destination)

        XCTAssertEqual(result.succeeded, [source])
        XCTAssertTrue(fs.existing.contains(source.path))
        XCTAssertTrue(fs.existing.contains(destination.appendingPathComponent("x.pdf").path))
        XCTAssertFalse(fs.existing.contains(destination.appendingPathComponent(".temp").path))
    }

    func testUnknownVolumeFallsBackToCopy() {
        let fs = FakeFileSystem()
        let source = URL(fileURLWithPath: "/source/x.pdf")
        let destination = URL(fileURLWithPath: "/destination", isDirectory: true)
        fs.existing = [source.path, destination.path]

        let result = FileMover(fileSystem: fs, temporaryName: { _ in ".temp" })
            .move([source], into: destination)

        XCTAssertEqual(result.succeeded, [source])
        XCTAssertEqual(fs.copyCalls.count, 1)
        XCTAssertTrue(fs.existing.contains(source.path))
    }

    func testSameVolumeMoveFailureDoesNotFallBackToCopy() {
        let fs = FakeFileSystem()
        let source = URL(fileURLWithPath: "/source/x.pdf")
        let destination = URL(fileURLWithPath: "/destination", isDirectory: true)
        fs.existing = [source.path, destination.path]
        fs.volumes[source.path] = "same-volume"
        fs.volumes[destination.path] = "same-volume"
        fs.failMoveFor = source.path

        let result = FileMover(fileSystem: fs).move([source], into: destination)

        XCTAssertEqual(result.failed, [source])
        XCTAssertTrue(fs.copyCalls.isEmpty)
        XCTAssertTrue(fs.existing.contains(source.path))
    }

    func testCopyFailureCleansTemporaryItem() {
        let fs = FakeFileSystem()
        let source = URL(fileURLWithPath: "/source/x.pdf")
        let destination = URL(fileURLWithPath: "/destination", isDirectory: true)
        fs.existing = [source.path, destination.path]
        fs.failCopyFor = source.path

        let result = FileMover(fileSystem: fs, temporaryName: { _ in ".temp" })
            .move([source], into: destination)

        XCTAssertEqual(result.failed, [source])
        XCTAssertFalse(fs.existing.contains(destination.appendingPathComponent(".temp").path))
    }

    func testCommitRaceIsConflictAndCleansTemporaryItem() {
        let fs = FakeFileSystem()
        let source = URL(fileURLWithPath: "/source/x.pdf")
        let destination = URL(fileURLWithPath: "/destination", isDirectory: true)
        let final = destination.appendingPathComponent("x.pdf")
        fs.existing = [source.path, destination.path]
        fs.createDuringCopy = final.path

        let result = FileMover(fileSystem: fs, temporaryName: { _ in ".temp" })
            .move([source], into: destination)

        XCTAssertEqual(result.conflicts, [source])
        XCTAssertFalse(fs.existing.contains(destination.appendingPathComponent(".temp").path))
    }

    func testFailureDoesNotStopLaterSource() {
        let fs = FakeFileSystem()
        let first = URL(fileURLWithPath: "/source/first.pdf")
        let second = URL(fileURLWithPath: "/source/second.pdf")
        let destination = URL(fileURLWithPath: "/destination", isDirectory: true)
        fs.existing = [first.path, second.path, destination.path]
        fs.failCopyFor = first.path

        var temporaryIndex = 0
        let result = FileMover(fileSystem: fs, temporaryName: { _ in
            defer { temporaryIndex += 1 }
            return ".temp-\(temporaryIndex)"
        }).move([first, second], into: destination)

        XCTAssertEqual(result.failed, [first])
        XCTAssertEqual(result.succeeded, [second])
    }

    private func makeRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileMoverTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        roots.append(url)
        return url
    }
}

private final class FakeFileSystem: FileMovingFileSystem {
    enum Failure: Error { case requested }

    var existing = Set<String>()
    var volumes: [String: String] = [:]
    var failCopyFor: String?
    var failMoveFor: String?
    var createDuringCopy: String?
    var copyCalls: [(URL, URL)] = []
    var moveCalls: [(URL, URL)] = []

    func volumeIdentifier(for url: URL) throws -> String? {
        volumes[url.path]
    }

    func itemExists(at url: URL) -> Bool {
        existing.contains(url.path)
    }

    func moveItem(at source: URL, to destination: URL) throws {
        moveCalls.append((source, destination))
        if failMoveFor == source.path { throw Failure.requested }
        guard existing.contains(source.path), !existing.contains(destination.path) else { throw Failure.requested }
        existing.remove(source.path)
        existing.insert(destination.path)
    }

    func copyItem(at source: URL, to destination: URL) throws {
        copyCalls.append((source, destination))
        existing.insert(destination.path) // simulates failure after the copy has already produced some temporary content.
        if let createDuringCopy { existing.insert(createDuringCopy) }
        if failCopyFor == source.path { throw Failure.requested }
    }

    func removeItemIfPresent(at url: URL) {
        existing.remove(url.path)
    }
}
