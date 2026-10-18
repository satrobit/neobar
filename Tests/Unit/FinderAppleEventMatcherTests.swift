import CoreGraphics
import Foundation
import XCTest

/// Unit tests for the **pure logic** of Finder window path reverse lookup: AppleScript output parsing + unique matching by "title + position".
/// Covers only `FinderAppleEventMatcher` (pure, no AX dependency); the I/O layer `FinderWindowContentsReader` isn't tested here.
/// Behavior was already verified on real hardware by spike#2; these cases lock it in against regressions.
final class FinderAppleEventMatcherTests: XCTestCase {
    private var tempRoots: [URL] = []

    override func tearDownWithError() throws {
        for url in tempRoots {
            try? FileManager.default.removeItem(at: url)
        }
        tempRoots.removeAll()
        try super.tearDownWithError()
    }

    func testAppleEventOutputParsesFileURLTargets() throws {
        let root = try makeTempDirectory()
        let output = aeLine(name: "Project", target: root.absoluteString)

        let result = FinderAppleEventMatcher.parseAppleEventWindowOutput(output)

        XCTAssertEqual(result.rawLineCount, 1)
        XCTAssertEqual(result.validURLCount, 1)
        XCTAssertNil(result.firstErrorSummary)
        XCTAssertEqual(result.windows.first?.name, "Project")
        XCTAssertEqual(result.windows.first?.url.standardizedFileURL, root.standardizedFileURL)
    }

    func testAppleEventOutputParsesPOSIXPathTargets() throws {
        let root = try makeTempDirectory()
        let output = aeLine(name: "Project", target: root.path)

        let result = FinderAppleEventMatcher.parseAppleEventWindowOutput(output)

        XCTAssertEqual(result.rawLineCount, 1)
        XCTAssertEqual(result.validURLCount, 1)
        XCTAssertEqual(result.windows.first?.url.standardizedFileURL, root.standardizedFileURL)
    }

    func testAppleEventOutputFiltersTrashAndNonFileTargets() throws {
        let trash = aeLine(name: "Trash", target: "trash://")
        let remote = aeLine(name: "Server", target: "smb://example.local/Share")

        let result = FinderAppleEventMatcher.parseAppleEventWindowOutput(trash + remote)

        XCTAssertEqual(result.rawLineCount, 2)
        XCTAssertEqual(result.validURLCount, 0)
        XCTAssertTrue(result.windows.isEmpty)
        XCTAssertEqual(result.firstErrorSummary, "invalid-target-url")
    }

    func testAppleEventOutputKeepsFieldErrorSummary() throws {
        let root = try makeTempDirectory()
        let output = aeLine(name: "Project", target: root.path, error: "url:-1728;")

        let result = FinderAppleEventMatcher.parseAppleEventWindowOutput(output)

        XCTAssertEqual(result.validURLCount, 1)
        XCTAssertEqual(result.windows.count, 1)
        XCTAssertEqual(result.firstErrorSummary, "url:-1728;")
    }

    func testAppleEventOutputUsesAXComparableFrameCoordinates() throws {
        let root = try makeTempDirectory()
        let output = aeLine(name: "hosts_backups", left: 0, top: 33, right: 1103, bottom: 600, target: root.path)

        let result = FinderAppleEventMatcher.parseAppleEventWindowOutput(output)

        XCTAssertEqual(result.windows.first?.cocoaFrame, CGRect(x: 0, y: 33, width: 1103, height: 567))
    }

    func testAppleEventMatchingAcceptsUniqueTitleAndNearbyFrame() throws {
        let root = try makeTempDirectory()
        let candidates = [
            AEFinderWindow(name: "hosts_backups", cocoaFrame: CGRect(x: 0, y: 33, width: 1103, height: 567), url: root),
            AEFinderWindow(name: "dev", cocoaFrame: CGRect(x: 29, y: 62, width: 1103, height: 567), url: root)
        ]

        let matched = FinderAppleEventMatcher.matchAppleEventWindow(
            target: FinderWindowAppleEventsTarget(
                title: "hosts_backups",
                cocoaFrame: CGRect(x: 4, y: 37, width: 1100, height: 566)
            ),
            candidates: candidates
        )

        XCTAssertEqual(matched?.name, "hosts_backups")
    }

    func testAppleEventMatchingRejectsSameTitleWhenFrameDiffers() throws {
        let root = try makeTempDirectory()
        let candidates = [
            AEFinderWindow(name: "Project", cocoaFrame: CGRect(x: 0, y: 33, width: 1103, height: 567), url: root)
        ]

        let matched = FinderAppleEventMatcher.matchAppleEventWindow(
            target: FinderWindowAppleEventsTarget(title: "Project", cocoaFrame: CGRect(x: 120, y: 180, width: 1103, height: 567)),
            candidates: candidates
        )

        XCTAssertNil(matched)
    }

    func testAppleEventMatchingRejectsAmbiguousTitleAndFrame() throws {
        let root = try makeTempDirectory()
        let frame = CGRect(x: 10, y: 20, width: 300, height: 200)
        let candidates = [
            AEFinderWindow(name: "Project", cocoaFrame: frame, url: root),
            AEFinderWindow(name: "Project", cocoaFrame: frame.offsetBy(dx: 2, dy: -2), url: root)
        ]

        let matched = FinderAppleEventMatcher.matchAppleEventWindow(
            target: FinderWindowAppleEventsTarget(title: "Project", cocoaFrame: frame),
            candidates: candidates
        )

        XCTAssertNil(matched)
    }

    func testAppleEventScriptGetsFinderWindowsBeforeEnumerating() {
        let script = FinderAppleEventMatcher.appleEventWindowListingScript()

        XCTAssertTrue(script.contains("set finderWindows to (get Finder windows)"))
        XCTAssertTrue(script.contains("repeat with w in finderWindows"))
        XCTAssertFalse(script.contains("repeat with w in Finder windows"))
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FinderAppleEventMatcherTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        tempRoots.append(url)
        return url
    }

    private func aeLine(
        name: String,
        left: Int = 10,
        top: Int = 20,
        right: Int = 310,
        bottom: Int = 220,
        target: String,
        error: String = ""
    ) -> String {
        "\(name)\t\(left)\t\(top)\t\(right)\t\(bottom)\t\(target)\t\(error)\n"
    }
}
