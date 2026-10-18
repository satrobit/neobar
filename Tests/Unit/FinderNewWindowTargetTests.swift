import XCTest

final class FinderNewWindowTargetTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)

    private func resolve(_ target: String?, _ path: String? = nil) -> FinderNewWindowTarget {
        FinderNewWindowTarget.resolve(target: target, path: path, home: home)
    }

    func testFolderCodes() {
        XCTAssertEqual(resolve("PfHm"), .home)
        XCTAssertEqual(resolve("PfDe"), .folder(URL(fileURLWithPath: "/Users/tester/Desktop", isDirectory: true)))
        XCTAssertEqual(resolve("PfDo"), .folder(URL(fileURLWithPath: "/Users/tester/Documents", isDirectory: true)))
    }

    func testNonFolderMissingAndUnknownCodesGoHome() {
        for code in ["PfAF", "PfCm", "PfID", "PfXX", "", nil] as [String?] {
            XCTAssertEqual(resolve(code, "file:///Users/tester/Work/"), .home, "code \(String(describing: code))")
        }
    }

    func testOtherFolderPathForms() {
        let work = URL(fileURLWithPath: "/Users/tester/工作 文件", isDirectory: true)
        XCTAssertEqual(resolve("PfLo", "file:///Users/tester/%E5%B7%A5%E4%BD%9C%20%E6%96%87%E4%BB%B6/"), .folder(work))
        XCTAssertEqual(resolve("PfLo", "file:///Users/tester/工作 文件/"), .folder(work))
        XCTAssertEqual(resolve("PfLo", "file://localhost/Users/tester/工作 文件/"), .folder(work))
        XCTAssertEqual(resolve("PfLo", "/Users/tester/工作 文件"), .folder(work))
    }

    func testUnusableOtherFolderPathGoesHome() {
        for path in [nil, "", "https://example.com/x", "file://server/share", "file:///bad%zzpath", "relative/path"] as [String?] {
            XCTAssertEqual(resolve("PfLo", path), .home, "path \(String(describing: path))")
        }
    }

    func testVolumeUsesPathElseRoot() {
        XCTAssertEqual(resolve("PfVo", "file:///Volumes/Data/"), .folder(URL(fileURLWithPath: "/Volumes/Data", isDirectory: true)))
        XCTAssertEqual(resolve("PfVo"), .folder(URL(fileURLWithPath: "/", isDirectory: true)))
    }

    func testReopenReplyParsing() {
        XCTAssertEqual(FinderReopenOutcome.parse(sendError: nil, replyError: nil), .delivered)
        XCTAssertEqual(FinderReopenOutcome.parse(sendError: nil, replyError: 0), .delivered)
        XCTAssertEqual(FinderReopenOutcome.parse(sendError: 0, replyError: nil), .delivered)
        XCTAssertEqual(FinderReopenOutcome.parse(sendError: -1744, replyError: nil), .failed(-1744))
        XCTAssertEqual(FinderReopenOutcome.parse(sendError: nil, replyError: -10000), .failed(-10000))
        XCTAssertEqual(FinderReopenOutcome.parse(sendError: -1712, replyError: nil), .timedOut)
        XCTAssertEqual(FinderReopenOutcome.parse(sendError: nil, replyError: -1712), .timedOut)
    }

    func testReopenGate() {
        XCTAssertTrue(FinderReopenEventGate.isEnabled(osMajorVersion: 27, killSwitchOn: true))
        XCTAssertTrue(FinderReopenEventGate.isEnabled(osMajorVersion: 28, killSwitchOn: true))
        XCTAssertFalse(FinderReopenEventGate.isEnabled(osMajorVersion: 26, killSwitchOn: true))
        XCTAssertFalse(FinderReopenEventGate.isEnabled(osMajorVersion: 12, killSwitchOn: true))
        XCTAssertFalse(FinderReopenEventGate.isEnabled(osMajorVersion: 27, killSwitchOn: false))
    }

    func testDirectoryProbeAnswers() {
        let dir = BoundedDirectoryProbe(timeout: 1, isDirectory: { _ in true })
        XCTAssertEqual(dir.check(home), .directory)
        let file = BoundedDirectoryProbe(timeout: 1, isDirectory: { _ in false })
        XCTAssertEqual(file.check(home), .notDirectory)
    }

    func testDirectoryProbeKeepsAtMostOneHungCheck() {
        let release = DispatchSemaphore(value: 0)
        let calls = Counter()
        let probe = BoundedDirectoryProbe(timeout: 0.05) { _ in
            calls.increment()
            release.wait()
            return true
        }
        XCTAssertEqual(probe.check(home), .unknown)   // hung past the timeout
        XCTAssertEqual(probe.check(home), .unknown)   // slot still held: answered at once
        XCTAssertEqual(probe.check(home), .unknown)
        XCTAssertEqual(calls.value, 1)

        release.signal()                              // the hung check finally returns
        let freed = expectation(description: "slot freed")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { freed.fulfill() }
        wait(for: [freed], timeout: 1)
        release.signal()                              // let the next check through immediately
        XCTAssertEqual(probe.check(home), .directory)
        XCTAssertEqual(calls.value, 2)
    }

    func testRealFileSystemCheck() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("工作")
        try Data().write(to: file)
        XCTAssertTrue(BoundedDirectoryProbe.fileSystemIsDirectory(dir))
        XCTAssertFalse(BoundedDirectoryProbe.fileSystemIsDirectory(file))
        XCTAssertFalse(BoundedDirectoryProbe.fileSystemIsDirectory(dir.appendingPathComponent("missing")))
    }

    private final class Counter {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
        func increment() { lock.lock(); count += 1; lock.unlock() }
    }
}
