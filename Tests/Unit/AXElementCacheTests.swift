import ApplicationServices
import CoreGraphics
import XCTest

/// Storage and invalidation rules for the AX element side cache.
///
/// If this rule is written wrong there are two bad outcomes, in opposite directions, and both are hard to notice:
/// - keeping a stale element pointing at a destroyed window -> after cgWindowID reuse it may operate on **a different window**;
/// - wrongly deleting a window that left `AXWindows` after being minimized -> the cache is empty at exactly the moment it matters most, built for nothing.
final class AXElementCacheTests: XCTestCase {

    // MARK: - Retention decision

    /// Eviction goes only by the **full CG list**: only when it's gone from CG is it really closed.
    func testExpiredIsExactlyWhatLeftTheCGList() {
        let expired = AXElementCacheRetention.expired(
            cachedCGWindowIDs: [1, 2, 3],
            liveCGWindowIDs: [2, 3, 4]
        )
        XCTAssertEqual(expired, [1])
    }

    /// **If it is still in CG it must be kept**, even if AX didn't report it at all this round.
    /// Safari-family windows vanish entirely from `AXWindows` after being minimized (the premise of the ghost-seat self-heal rule),
    /// and that is exactly the moment "clicking a minimized window to bring it back" needs the cache. Deleting on AX absence = the cache fails in the very scenario it should save.
    func testWindowStillInCGListSurvivesEvenWhenAXNoLongerReportsIt() {
        let expired = AXElementCacheRetention.expired(
            cachedCGWindowIDs: [7],
            liveCGWindowIDs: [7]
        )
        XCTAssertTrue(expired.isEmpty)
    }

    func testEmptyCacheExpiresNothing() {
        XCTAssertTrue(
            AXElementCacheRetention.expired(cachedCGWindowIDs: [], liveCGWindowIDs: [1, 2]).isEmpty
        )
    }

    /// When the CG full list reads empty (an extreme case), the whole cache is invalidated, in line with the existing rule "a seat is kept only if present in CG".
    func testEmptyLiveListExpiresEverything() {
        XCTAssertEqual(
            AXElementCacheRetention.expired(cachedCGWindowIDs: [1, 2], liveCGWindowIDs: []),
            [1, 2]
        )
    }

    // MARK: - Storage

    func testStoreAndLookupIsKeyedByPidAndWindow() {
        let cache = AXElementCache()
        let element = AXUIElementCreateApplication(getpid())

        cache.store(pid: 42, cgWindowID: 7, element: element)

        XCTAssertNotNil(cache.element(pid: 42, cgWindowID: 7))
        XCTAssertNil(cache.element(pid: 42, cgWindowID: 8), "同 pid 不同窗口不能串")
        XCTAssertNil(cache.element(pid: 43, cgWindowID: 7), "同窗口号不同 pid 不能串")
    }

    /// `pid <= 0` and `cgWindowID == 0` are both not valid identities; writing them in is planting a mine for yourself.
    func testInvalidIdentitiesAreRejectedOnStoreAndLookup() {
        let cache = AXElementCache()
        let element = AXUIElementCreateApplication(getpid())

        cache.store(pid: 0, cgWindowID: 7, element: element)
        cache.store(pid: -1, cgWindowID: 7, element: element)
        cache.store(pid: 42, cgWindowID: 0, element: element)

        XCTAssertEqual(cache.countForTesting, 0)
        XCTAssertNil(cache.element(pid: 0, cgWindowID: 7))
        XCTAssertNil(cache.element(pid: 42, cgWindowID: 0))
    }

    func testRemoveAllDropsOnlyThatProcess() {
        let cache = AXElementCache()
        let element = AXUIElementCreateApplication(getpid())
        cache.store(pid: 42, cgWindowID: 1, element: element)
        cache.store(pid: 42, cgWindowID: 2, element: element)
        cache.store(pid: 99, cgWindowID: 3, element: element)

        cache.removeAll(pid: 42)

        XCTAssertFalse(cache.containsForTesting(pid: 42, cgWindowID: 1))
        XCTAssertFalse(cache.containsForTesting(pid: 42, cgWindowID: 2))
        XCTAssertTrue(cache.containsForTesting(pid: 99, cgWindowID: 3))
    }

    /// `retain` takes effect per pid: another process's entries must not be cleaned out in passing by this round's reconciliation
    /// (each reconciliation round gets only the current pid's context).
    func testRetainOnlyPrunesTheGivenProcess() {
        let cache = AXElementCache()
        let element = AXUIElementCreateApplication(getpid())
        cache.store(pid: 42, cgWindowID: 1, element: element)
        cache.store(pid: 42, cgWindowID: 2, element: element)
        cache.store(pid: 99, cgWindowID: 1, element: element)

        cache.retain(pid: 42, liveCGWindowIDs: [2])

        XCTAssertFalse(cache.containsForTesting(pid: 42, cgWindowID: 1), "CG 里没有了，出列")
        XCTAssertTrue(cache.containsForTesting(pid: 42, cgWindowID: 2), "CG 里还在，留着")
        XCTAssertTrue(cache.containsForTesting(pid: 99, cgWindowID: 1), "别的进程不受影响")
    }

    func testRemoveDropsExactlyOneEntry() {
        let cache = AXElementCache()
        let element = AXUIElementCreateApplication(getpid())
        cache.store(pid: 42, cgWindowID: 1, element: element)
        cache.store(pid: 42, cgWindowID: 2, element: element)

        cache.remove(pid: 42, cgWindowID: 1)

        XCTAssertFalse(cache.containsForTesting(pid: 42, cgWindowID: 1))
        XCTAssertTrue(cache.containsForTesting(pid: 42, cgWindowID: 2))
    }
}
