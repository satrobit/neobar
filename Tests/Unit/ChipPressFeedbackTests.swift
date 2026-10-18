import CoreGraphics
import XCTest

/// Pure decision for press feedback.
///
/// Background (owner reported 2026-08-11 "pressing feels sticky"): the old implementation hung the rebound on `.onTapGesture`,
/// and SwiftUI's TapGesture fires on **mouse-up** -- the whole "press" happens after the click has already ended.
/// It is now driven at the instant of press by `DragGesture(minimumDistance: 0)`, and wraps up on release by the rules below.
final class ChipPressFeedbackTests: XCTestCase {

    // MARK: - Minimum hold

    /// If a very fast click (only a few milliseconds from press to release) bounced back immediately, that 0.93 scale would never be visible.
    /// That is the intent of the old implementation's 90ms timer, and it must be kept as is after switching to press-driven.
    func testVeryFastClickIsHeldUpToTheMinimum() {
        let hold = ChipPressDecision.holdAfterRelease(pressedAt: 100.0, releasedAt: 100.005)
        XCTAssertEqual(hold, ChipPressDecision.minimumHold - 0.005, accuracy: 1e-9)
    }

    /// The press has already exceeded the minimum hold duration: on release it should bounce back immediately without dragging time out any further -- dragging more is new stickiness.
    func testSlowClickReleasesImmediately() {
        XCTAssertEqual(
            ChipPressDecision.holdAfterRelease(pressedAt: 100.0, releasedAt: 100.5),
            0
        )
    }

    func testExactlyAtMinimumReleasesImmediately() {
        XCTAssertEqual(
            ChipPressDecision.holdAfterRelease(
                pressedAt: 100.0,
                releasedAt: 100.0 + ChipPressDecision.minimumHold
            ),
            0
        )
    }

    /// No press time was recorded (force touch / middle-click preview paths that have only a pulse and no mouse-down): fill out the whole span,
    /// otherwise that tier of feedback would not show for a single frame.
    func testMissingPressTimestampHoldsFullMinimum() {
        XCTAssertEqual(
            ChipPressDecision.holdAfterRelease(pressedAt: nil, releasedAt: 100.0),
            ChipPressDecision.minimumHold
        )
    }

    /// Release earlier than press (clock anomaly / out-of-order state) must never yield a negative number -- a negative delay would make scheduling fire immediately,
    /// which quietly turns off the minimum-hold rule.
    func testReleaseBeforePressNeverReturnsNegative() {
        let hold = ChipPressDecision.holdAfterRelease(pressedAt: 100.0, releasedAt: 99.0)
        XCTAssertEqual(hold, ChipPressDecision.minimumHold)
        XCTAssertGreaterThanOrEqual(hold, 0)
    }

    // MARK: - Constant bounds

    /// The watchdog must be clearly longer than the minimum hold: it guards against "`onEnded` never coming" (SwiftUI cancels the gesture
    /// when a reflow moves the chip), not normal clicks. Once the two get close, a normal long press would be mistaken for stuck and bounce back early.
    func testWatchdogIsWellAboveMinimumHold() {
        XCTAssertGreaterThan(ChipPressDecision.maximumHold, ChipPressDecision.minimumHold * 5)
    }

    /// The scale values are the literal values from before the change, deliberately untouched (a look the owner already signed off on).
    func testPressedScaleMatchesPreviousLiteral() {
        XCTAssertEqual(ChipPressDecision.pressedScale, 0.93)
    }

    /// The minimum hold keeps the old 90ms.
    func testMinimumHoldMatchesPreviousTimer() {
        XCTAssertEqual(ChipPressDecision.minimumHold, 0.09, accuracy: 1e-9)
    }
}
