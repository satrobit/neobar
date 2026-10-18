import XCTest

/// Pure functions for relay shelf list operations (ShelfStore's static logic, not touching UserDefaults/the file system).
final class ShelfLogicTests: XCTestCase {
    func testStashingPrependsNewestFirst() {
        let result = ShelfStore.stashing(["/old"], adding: ["/new1", "/new2"])
        XCTAssertEqual(result, ["/new1", "/new2", "/old"])
    }

    func testStashingDedupesIncomingAndDropsEmpty() {
        let result = ShelfStore.stashing([], adding: ["/a", "/a", "", "/b"])
        XCTAssertEqual(result, ["/a", "/b"])
    }

    func testStashingMovesExistingToFront() {
        let result = ShelfStore.stashing(["/a", "/b", "/c"], adding: ["/c"])
        XCTAssertEqual(result, ["/c", "/a", "/b"])
    }

    func testStashingNothingReturnsCurrent() {
        let result = ShelfStore.stashing(["/a"], adding: [""])
        XCTAssertEqual(result, ["/a"])
    }

    func testPrunedKeepsOnlyExisting() {
        let result = ShelfStore.pruned(["/keep", "/gone", "/keep2"]) { $0 != "/gone" }
        XCTAssertEqual(result, ["/keep", "/keep2"])
    }

    func testNormalizedStripsTrailingSlashAndStandardizes() {
        XCTAssertEqual(ShelfStore.normalized("/tmp/dir/"), "/tmp/dir")
        XCTAssertEqual(ShelfStore.normalized("/tmp/a/../b"), "/tmp/b")
        XCTAssertEqual(ShelfStore.normalized("/"), "/")
    }
}
