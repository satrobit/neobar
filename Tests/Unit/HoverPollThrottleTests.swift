import XCTest

final class HoverPollThrottleTests: XCTestCase {
    func testFirstEventRunsImmediately() {
        var t = HoverPollThrottle(minInterval: 1.0 / 30.0)
        XCTAssertEqual(t.eventArrived(now: 100), .run)
    }

    func testEventInsideWindowSchedulesOneTrailing() {
        var t = HoverPollThrottle(minInterval: 0.033)
        _ = t.eventArrived(now: 100)
        guard case .scheduleTrailing(let after) = t.eventArrived(now: 100.010) else {
            return XCTFail("应挂收尾")
        }
        XCTAssertEqual(after, 0.023, accuracy: 0.0001)
        // The trailing event is already scheduled; all later events in the window are dropped.
        XCTAssertEqual(t.eventArrived(now: 100.015), .drop)
        XCTAssertEqual(t.eventArrived(now: 100.020), .drop)
    }

    func testTrailingFiredResetsWindowFromFireTime() {
        var t = HoverPollThrottle(minInterval: 0.033)
        _ = t.eventArrived(now: 100)
        _ = t.eventArrived(now: 100.010)
        t.trailingFired(now: 100.033)
        // A new window after the trailing event: events arriving immediately are still throttled; released once the window fills.
        XCTAssertNotEqual(t.eventArrived(now: 100.040), .run)
        XCTAssertEqual(t.eventArrived(now: 100.070), .run)
    }

    func testQuietGapRunsImmediately() {
        var t = HoverPollThrottle(minInterval: 0.033)
        _ = t.eventArrived(now: 100)
        XCTAssertEqual(t.eventArrived(now: 105), .run)
    }

    func testResetClearsPendingTrailing() {
        var t = HoverPollThrottle(minInterval: 0.033)
        _ = t.eventArrived(now: 100)
        _ = t.eventArrived(now: 100.010)   // trailing scheduled
        t.reset()
        XCTAssertEqual(t.eventArrived(now: 100.011), .run)
    }
}
