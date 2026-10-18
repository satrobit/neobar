import Foundation
import UniformTypeIdentifiers
import XCTest

final class FileDragItemProviderTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDownWithError() throws {
        roots.forEach { try? FileManager.default.removeItem(at: $0) }
        roots.removeAll()
        try super.tearDownWithError()
    }

    func testZipArchiveRegistersFileURLOnlyAndKeepsItsName() throws {
        let root = try makeRoot()
        try assertDragsAsFileURL(try file("测试 原名 v1.2.zip", in: root))
    }

    func testPlainTextRegistersFileURLOnlyAndKeepsItsName() throws {
        let root = try makeRoot()
        try assertDragsAsFileURL(try file("中文 名字 说明.txt", in: root))
    }

    func testFolderRegistersFileURLOnlyAndKeepsItsName() throws {
        let root = try makeRoot()
        let folder = root.appendingPathComponent("子文件夹 甲", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try assertDragsAsFileURL(folder)
    }

    /// The content-type representation is what made receivers name the drop after its type.
    private func assertDragsAsFileURL(_ url: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let provider = FileDragItemProvider.make(for: url)
        let contentType = try XCTUnwrap(url.resourceValues(forKeys: [.contentTypeKey]).contentType,
                                        file: file, line: line)

        // A suggested name makes SwiftUI drag a cache copy instead of the file itself.
        XCTAssertNil(provider.suggestedName, file: file, line: line)
        XCTAssertTrue(provider.registeredTypeIdentifiers.contains(UTType.fileURL.identifier),
                      file: file, line: line)
        XCTAssertFalse(provider.registeredTypeIdentifiers.contains(contentType.identifier),
                       "\(contentType.identifier) registered", file: file, line: line)

        let loaded = expectation(description: "load URL")
        var loadedURL: URL?
        _ = provider.loadObject(ofClass: URL.self) { value, _ in
            loadedURL = value
            loaded.fulfill()
        }
        wait(for: [loaded], timeout: 2)
        XCTAssertEqual(loadedURL?.path, url.path, file: file, line: line)
    }

    private func makeRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileDragItemProviderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        roots.append(url)
        return url
    }

    private func file(_ name: String, in parent: URL) throws -> URL {
        let url = parent.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        return url
    }
}
