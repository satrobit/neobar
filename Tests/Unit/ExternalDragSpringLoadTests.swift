import XCTest
@testable import NeoBar

final class ExternalDragSpringLoadTests: XCTestCase {
    typealias Spring = ExternalDragSpringLoad

    func testRestingOnTheClosedCapsuleArmsThenOpens() {
        var state = Spring.State()
        XCTAssertEqual(Spring.reduce(&state, .hover(.capsule, true), drawerOpen: false), [.armOpenTimer])
        XCTAssertEqual(Spring.reduce(&state, .openTimerFired, drawerOpen: false), [.openDrawer])
        XCTAssertFalse(state.openArmed)
    }

    func testLeavingTheCapsuleBeforeTheDelayCancelsTheOpen() {
        var state = Spring.State()
        _ = Spring.reduce(&state, .hover(.capsule, true), drawerOpen: false)
        XCTAssertEqual(Spring.reduce(&state, .hover(.capsule, false), drawerOpen: false), [.cancelOpenTimer])
        // A timer that still fires after the cancel does nothing.
        XCTAssertEqual(Spring.reduce(&state, .openTimerFired, drawerOpen: false), [])
    }

    func testAnOpenDrawerDoesNotArmAgain() {
        var state = Spring.State()
        XCTAssertEqual(Spring.reduce(&state, .hover(.capsule, true), drawerOpen: true), [])
    }

    func testRepeatedHoverReportsAreNoOps() {
        var state = Spring.State()
        _ = Spring.reduce(&state, .hover(.capsule, true), drawerOpen: false)
        XCTAssertEqual(Spring.reduce(&state, .hover(.capsule, true), drawerOpen: false), [])
        XCTAssertEqual(Spring.reduce(&state, .hover(.drawer, false), drawerOpen: false), [])
    }

    func testLeavingBothSurfacesClosesAfterTheGrace() {
        var state = Spring.State()
        _ = Spring.reduce(&state, .hover(.capsule, true), drawerOpen: false)
        _ = Spring.reduce(&state, .openTimerFired, drawerOpen: false)
        // Capsule → drawer: the capsule's exit arms a close, the drawer's enter cancels it.
        XCTAssertEqual(Spring.reduce(&state, .hover(.capsule, false), drawerOpen: true), [.armCloseTimer])
        XCTAssertEqual(Spring.reduce(&state, .hover(.drawer, true), drawerOpen: true), [.cancelCloseTimer])
        XCTAssertEqual(Spring.reduce(&state, .hover(.drawer, false), drawerOpen: true), [.armCloseTimer])
        XCTAssertEqual(Spring.reduce(&state, .closeTimerFired, drawerOpen: true), [.closeDrawer])
    }

    func testReturningBeforeTheGraceKeepsItOpen() {
        var state = Spring.State(closeArmed: true)
        XCTAssertEqual(Spring.reduce(&state, .hover(.capsule, true), drawerOpen: true), [.cancelCloseTimer])
        XCTAssertEqual(Spring.reduce(&state, .closeTimerFired, drawerOpen: true), [])
    }

    func testCloseTimerFiringWhileOverDoesNothing() {
        // The drawer re-entered without the cancel landing first (events can race the timer).
        var state = Spring.State(overDrawer: true, closeArmed: true)
        XCTAssertEqual(Spring.reduce(&state, .closeTimerFired, drawerOpen: true), [])
    }

    func testADropLeavesTheDrawerAsItIs() {
        var state = Spring.State()
        _ = Spring.reduce(&state, .hover(.capsule, true), drawerOpen: false)
        _ = Spring.reduce(&state, .openTimerFired, drawerOpen: false)
        XCTAssertEqual(Spring.reduce(&state, .hover(.capsule, false), drawerOpen: true), [.armCloseTimer])
        XCTAssertEqual(Spring.reduce(&state, .hover(.drawer, true), drawerOpen: true), [.cancelCloseTimer])
        // The receiver reports its exit before the drop lands.
        XCTAssertEqual(Spring.reduce(&state, .hover(.drawer, false), drawerOpen: true), [.armCloseTimer])
        XCTAssertEqual(Spring.reduce(&state, .dropped, drawerOpen: true), [.cancelCloseTimer])
        XCTAssertEqual(state, Spring.State())
    }

    func testADropOnTheCapsuleBeforeTheOpenCancelsIt() {
        var state = Spring.State()
        _ = Spring.reduce(&state, .hover(.capsule, true), drawerOpen: false)
        _ = Spring.reduce(&state, .hover(.capsule, false), drawerOpen: false)
        XCTAssertEqual(Spring.reduce(&state, .dropped, drawerOpen: false), [])
        XCTAssertEqual(state, Spring.State())
    }

    func testOpenTimerFiringAfterTheDrawerOpenedByOtherMeansIsIgnored() {
        var state = Spring.State(overCapsule: true, openArmed: true)
        XCTAssertEqual(Spring.reduce(&state, .openTimerFired, drawerOpen: true), [])
    }
}
