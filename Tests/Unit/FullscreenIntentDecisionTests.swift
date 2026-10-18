import CoreGraphics
import XCTest

final class FullscreenIntentDecisionTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)

    func testGreenButtonAcceptsExactHitAndIgnoresNonModifierFlags() {
        let snapshot = makeSnapshot()
        let request = FullscreenIntentDecision.greenButtonRequest(
            location: CGPoint(x: 120, y: 110),
            flags: [.maskAlphaShift, .maskNonCoalesced],
            snapshot: snapshot
        )
        XCTAssertEqual(request?.source, .greenButton)
        XCTAssertEqual(request?.focusedWindowID, snapshot.focusedWindowID)
    }

    func testGreenButtonRejectsModifiersCapabilityAndContextMismatches() {
        let point = CGPoint(x: 120, y: 110)
        for modifier: CGEventFlags in [
            .maskControl, .maskCommand, .maskAlternate, .maskShift,
            .maskSecondaryFn, .maskHelp, .maskNumericPad
        ] {
            XCTAssertNil(FullscreenIntentDecision.greenButtonRequest(
                location: point, flags: modifier, snapshot: makeSnapshot()
            ))
        }
        XCTAssertNil(FullscreenIntentDecision.greenButtonRequest(
            location: CGPoint(x: 200, y: 200), flags: [], snapshot: makeSnapshot()
        ))
        XCTAssertNil(FullscreenIntentDecision.greenButtonRequest(
            location: point, flags: [], snapshot: makeSnapshot(buttonEnabled: false)
        ))
        XCTAssertNil(FullscreenIntentDecision.greenButtonRequest(
            location: point, flags: [], snapshot: makeSnapshot(isFullscreen: true)
        ))
        XCTAssertNil(FullscreenIntentDecision.greenButtonRequest(
            location: point, flags: [], snapshot: makeSnapshot(panelScreens: [])
        ))
        XCTAssertNil(FullscreenIntentDecision.greenButtonRequest(
            location: point,
            flags: [],
            snapshot: makeSnapshot(panelScreens: [CGRect(x: 1512, y: 0, width: 1920, height: 1080)])
        ))
        XCTAssertNil(FullscreenIntentDecision.greenButtonRequest(
            location: point, flags: [], snapshot: nil
        ))
    }

    func testShortcutAcceptsExactControlCommandAndCapsLock() {
        let request = FullscreenIntentDecision.shortcutRequest(
            keyCode: FullscreenIntentDecision.ansiFKeyCode,
            flags: [.maskControl, .maskCommand, .maskAlphaShift, .maskNonCoalesced],
            isRepeat: false,
            snapshot: makeSnapshot()
        )
        XCTAssertEqual(request?.source, .keyboardShortcut)
    }

    func testShortcutRejectsExtraModifiersRepeatWrongKeyAndMissingCapability() {
        for flags: CGEventFlags in [
            [.maskControl, .maskCommand, .maskAlternate],
            [.maskControl, .maskCommand, .maskShift],
            [.maskControl, .maskCommand, .maskSecondaryFn],
            [.maskControl, .maskCommand, .maskHelp],
            [.maskControl, .maskCommand, .maskNumericPad],
            [.maskCommand]
        ] {
            XCTAssertNil(FullscreenIntentDecision.shortcutRequest(
                keyCode: FullscreenIntentDecision.ansiFKeyCode,
                flags: flags,
                isRepeat: false,
                snapshot: makeSnapshot()
            ))
        }
        XCTAssertNil(FullscreenIntentDecision.shortcutRequest(
            keyCode: FullscreenIntentDecision.ansiFKeyCode,
            flags: [.maskControl, .maskCommand],
            isRepeat: true,
            snapshot: makeSnapshot()
        ))
        XCTAssertNil(FullscreenIntentDecision.shortcutRequest(
            keyCode: 4,
            flags: [.maskControl, .maskCommand],
            isRepeat: false,
            snapshot: makeSnapshot()
        ))
        XCTAssertNil(FullscreenIntentDecision.shortcutRequest(
            keyCode: FullscreenIntentDecision.ansiFKeyCode,
            flags: [.maskControl, .maskCommand],
            isRepeat: false,
            snapshot: makeSnapshot(buttonEnabled: false)
        ))
    }

    func testSettingAndEnvironmentMustBothEnableMonitor() {
        XCTAssertTrue(FullscreenIntentDecision.isEnabled(settingEnabled: true, environment: [:]))
        XCTAssertFalse(FullscreenIntentDecision.isEnabled(
            settingEnabled: true,
            environment: ["DOCK_FULLSCREEN_INTENT": "0"]
        ))
        XCTAssertFalse(FullscreenIntentDecision.isEnabled(settingEnabled: false, environment: [:]))
    }

    func testStaleAXRefreshAndForegroundPIDSwitchCannotReplaceCache() {
        XCTAssertTrue(FullscreenIntentCacheDecision.shouldApplyRefresh(
            started: true,
            expectedObservation: 4,
            currentObservation: 4,
            expectedCache: 7,
            currentCache: 7,
            requestedPID: 123,
            activePID: 123
        ))
        XCTAssertFalse(FullscreenIntentCacheDecision.shouldApplyRefresh(
            started: true,
            expectedObservation: 4,
            currentObservation: 5,
            expectedCache: 7,
            currentCache: 7,
            requestedPID: 123,
            activePID: 123
        ))
        XCTAssertFalse(FullscreenIntentCacheDecision.shouldApplyRefresh(
            started: true,
            expectedObservation: 4,
            currentObservation: 4,
            expectedCache: 7,
            currentCache: 8,
            requestedPID: 123,
            activePID: 123
        ))
        XCTAssertFalse(FullscreenIntentCacheDecision.shouldApplyRefresh(
            started: true,
            expectedObservation: 4,
            currentObservation: 4,
            expectedCache: 7,
            currentCache: 7,
            requestedPID: 123,
            activePID: 124
        ))
    }

    func testRequestMustMatchCurrentPIDWindowScreenAndCacheGeneration() {
        let snapshot = makeSnapshot()
        let request = FullscreenIntentDecision.shortcutRequest(
            keyCode: FullscreenIntentDecision.ansiFKeyCode,
            flags: [.maskControl, .maskCommand],
            isRepeat: false,
            snapshot: snapshot
        )!
        XCTAssertTrue(FullscreenIntentCacheDecision.isCurrentRequest(
            request,
            snapshot: snapshot,
            activePID: snapshot.pid,
            started: true
        ))
        XCTAssertFalse(FullscreenIntentCacheDecision.isCurrentRequest(
            request,
            snapshot: makeSnapshot(generation: 10),
            activePID: snapshot.pid,
            started: true
        ))
        XCTAssertFalse(FullscreenIntentCacheDecision.isCurrentRequest(
            request,
            snapshot: makeSnapshot(focusedWindowID: 999),
            activePID: snapshot.pid,
            started: true
        ))
        XCTAssertFalse(FullscreenIntentCacheDecision.isCurrentRequest(
            request,
            snapshot: snapshot,
            activePID: 124,
            started: true
        ))
    }

    func testRefreshCoalescerCollapsesBurstIntoOneTrailingRefresh() {
        var coalescer = FullscreenIntentRefreshCoalescer()
        let first = coalescer.request()!
        XCTAssertNil(coalescer.request())
        XCTAssertNil(coalescer.request())
        XCTAssertTrue(coalescer.needsTrailingRefresh)

        guard case let .start(second) = coalescer.complete(token: first) else {
            return XCTFail("burst must schedule exactly one trailing refresh")
        }
        XCTAssertNotEqual(first, second)
        XCTAssertFalse(coalescer.needsTrailingRefresh)
        XCTAssertEqual(coalescer.complete(token: first), .ignored)
        XCTAssertEqual(coalescer.complete(token: second), .idle)
        XCTAssertNil(coalescer.activeToken)
    }

    func testRefreshCoalescerResetInvalidatesOldCompletion() {
        var coalescer = FullscreenIntentRefreshCoalescer()
        let old = coalescer.request()!
        coalescer.reset()
        let current = coalescer.request()!

        XCTAssertEqual(coalescer.complete(token: old), .ignored)
        XCTAssertEqual(coalescer.activeToken, current)
        XCTAssertEqual(coalescer.complete(token: current), .idle)
    }

    func testTapRecoveryFusesOnFourthDisableWithinWindow() {
        var policy = FullscreenEventTapRecoveryPolicy()
        XCTAssertTrue(policy.recordDisable(at: 0))
        XCTAssertTrue(policy.recordDisable(at: 1))
        XCTAssertTrue(policy.recordDisable(at: 2))
        XCTAssertFalse(policy.recordDisable(at: 3))
        XCTAssertTrue(policy.isFused)
        XCTAssertFalse(policy.recordDisable(at: 64))
    }

    func testTapRecoveryDropsOldEpisodesOutsideWindow() {
        var policy = FullscreenEventTapRecoveryPolicy()
        XCTAssertTrue(policy.recordDisable(at: 0))
        XCTAssertTrue(policy.recordDisable(at: 1))
        XCTAssertTrue(policy.recordDisable(at: 61))
        XCTAssertTrue(policy.recordDisable(at: 62))
        XCTAssertFalse(policy.isFused)
    }

    func testLateHandoffCannotBeginAfterCancellation() {
        let gate = FullscreenIntentHandoffGate()
        XCTAssertTrue(gate.cancelIfPending())
        XCTAssertFalse(gate.beginExecution())
        XCTAssertEqual(gate.currentState, .cancelled)
    }

    func testExecutingHandoffCompletesAndCannotBeCancelled() {
        let gate = FullscreenIntentHandoffGate()
        XCTAssertTrue(gate.beginExecution())
        XCTAssertFalse(gate.cancelIfPending())
        gate.complete()
        XCTAssertEqual(gate.currentState, .completed)
    }

    // MARK: - Control+←/→ space-switch experiment

    /// This is the easiest place in the whole experiment to go wrong: **physical arrow keys inherently carry Fn + numeric keypad + nonCoalesced**,
    /// even when the user presses no additional key. Comparing the way `FullscreenIntentDecision.normalizedModifiers`
    /// does would never match, producing a "nothing triggers" false negative, which is very easily misread as
    /// "the 548ms lead time is not enough, this approach cannot work".
    func testPhysicalArrowIntrinsicFlagsDoNotBlockTheMatch() {
        let physicalControlLeft: CGEventFlags = [
            .maskControl, .maskSecondaryFn, .maskNumericPad, .maskNonCoalesced
        ]
        XCTAssertTrue(FullscreenSpaceSwitchDecision.isSpaceSwitchArrow(
            keyCode: FullscreenSpaceSwitchDecision.leftArrowKeyCode,
            flags: physicalControlLeft,
            isRepeat: false
        ))
        XCTAssertTrue(FullscreenSpaceSwitchDecision.isSpaceSwitchArrow(
            keyCode: FullscreenSpaceSwitchDecision.rightArrowKeyCode,
            flags: physicalControlLeft,
            isRepeat: false
        ))
    }

    func testSpaceSwitchArrowRejectsEveryOtherShape() {
        let intrinsic: CGEventFlags = [.maskSecondaryFn, .maskNumericPad, .maskNonCoalesced]
        // Control not pressed
        XCTAssertFalse(FullscreenSpaceSwitchDecision.isSpaceSwitchArrow(
            keyCode: FullscreenSpaceSwitchDecision.leftArrowKeyCode,
            flags: intrinsic,
            isRepeat: false
        ))
        // Extra modifier keys present
        for extra: CGEventFlags in [.maskCommand, .maskAlternate, .maskShift, .maskHelp] {
            XCTAssertFalse(FullscreenSpaceSwitchDecision.isSpaceSwitchArrow(
                keyCode: FullscreenSpaceSwitchDecision.leftArrowKeyCode,
                flags: intrinsic.union([.maskControl]).union(extra),
                isRepeat: false
            ), "\(extra) 不该放行")
        }
        // Up/down arrow keys do not switch spaces
        for keyCode in [CGKeyCode(125), CGKeyCode(126)] {
            XCTAssertFalse(FullscreenSpaceSwitchDecision.isSpaceSwitchArrow(
                keyCode: keyCode,
                flags: intrinsic.union([.maskControl]),
                isRepeat: false
            ))
        }
        // Held-key repeats no longer trigger
        XCTAssertFalse(FullscreenSpaceSwitchDecision.isSpaceSwitchArrow(
            keyCode: FullscreenSpaceSwitchDecision.rightArrowKeyCode,
            flags: intrinsic.union([.maskControl]),
            isRepeat: true
        ))
    }

    func testArrowDirectionMapsKeyCodes() {
        let physical: CGEventFlags = [.maskControl, .maskSecondaryFn, .maskNumericPad, .maskNonCoalesced]
        XCTAssertEqual(
            FullscreenSpaceSwitchDecision.arrowDirection(
                keyCode: FullscreenSpaceSwitchDecision.leftArrowKeyCode,
                flags: physical, isRepeat: false
            ),
            .left
        )
        XCTAssertEqual(
            FullscreenSpaceSwitchDecision.arrowDirection(
                keyCode: FullscreenSpaceSwitchDecision.rightArrowKeyCode,
                flags: physical, isRepeat: false
            ),
            .right
        )
    }

    // MARK: - Adjacent-space gate

    private func layout(current: Int, fullscreen: Set<Int> = [3]) -> SpaceLayoutSnapshot {
        SpaceLayoutSnapshot(
            orderedSpaceIDs: [1, 2, 3, 4],
            fullscreenSpaceIDs: fullscreen,
            currentSpaceID: current
        )
    }

    func testNeighborGateOnlyOpensTowardAFullscreenSpace() {
        // Space 3 is fullscreen; only standing on 2 going right, or on 4 going left, should open it
        XCTAssertTrue(layout(current: 2).neighborIsFullscreen(.right))
        XCTAssertFalse(layout(current: 2).neighborIsFullscreen(.left))
        XCTAssertTrue(layout(current: 4).neighborIsFullscreen(.left))
        XCTAssertFalse(layout(current: 4).neighborIsFullscreen(.right))
        // Between two ordinary desktops: neither side opens — otherwise the bar would be hidden briefly in places that were fine to begin with
        XCTAssertFalse(layout(current: 1, fullscreen: []).hasAnyFullscreenNeighbor)
    }

    func testNeighborGateHandlesEdgesAndUnknownCurrentSpace() {
        XCTAssertFalse(layout(current: 1).neighborIsFullscreen(.left))   // No left neighbor at the far left
        XCTAssertFalse(layout(current: 4).neighborIsFullscreen(.right))  // No right neighbor at the far right
        XCTAssertFalse(layout(current: 99).hasAnyFullscreenNeighbor)     // The current space is not in the list
    }

    // Added 2026-08-31: the gate only belongs to "someone standing on a desktop". When already in a fullscreen space, do not predict —
    // the bar is hidden already, so there is nothing to hide; fullscreen→fullscreen is left to the existing hold mechanism.
    // (Reverse prediction "fullscreen→desktop, show the bar early" was done and then reverted, for reasons in the SpaceLayoutSnapshot comments —
    // stability first, the owner's call; do not add it back by merely deleting this test.)
    func testGateNeverOpensWhileStandingInAFullscreenSpace() {
        // Standing on fullscreen space 3: both sides are desktops, and the gate still does not open
        XCTAssertFalse(layout(current: 3).neighborIsFullscreen(.left))
        XCTAssertFalse(layout(current: 3).neighborIsFullscreen(.right))
        XCTAssertFalse(layout(current: 3).hasAnyFullscreenNeighbor)
        // Fullscreen next to fullscreen (3 and 4 are both fullscreen): going right from 3 likewise does not open
        XCTAssertFalse(layout(current: 3, fullscreen: [3, 4]).neighborIsFullscreen(.right))
        // Standing on desktop 2 going right opens as usual (existing behavior unaffected)
        XCTAssertTrue(layout(current: 2).neighborIsFullscreen(.right))
    }

    // MARK: - Three-finger horizontal swipe

    /// Measured mapping (14/14 consistent): with natural scrolling, **swiping the fingers left goes to the space on the right**.
    func testSwipeDirectionFollowsNaturalScrollingSetting() {
        var tracker = SpaceSwipeTracker()
        XCTAssertNil(tracker.consume(touches: 3, x: 0.5, y: 0.5, at: 0, naturalScrolling: true))
        XCTAssertEqual(
            tracker.consume(touches: 3, x: 0.3, y: 0.5, at: 0, naturalScrolling: true), .right
        )
        tracker.reset()
        XCTAssertNil(tracker.consume(touches: 3, x: 0.5, y: 0.5, at: 0, naturalScrolling: false))
        XCTAssertEqual(
            tracker.consume(touches: 3, x: 0.3, y: 0.5, at: 0, naturalScrolling: false), .left
        )
    }

    /// Three-finger **vertical** swipes (Mission Control): in 10 measured runs, 1 drifted horizontally past the threshold;
    /// the rule "horizontal displacement must dominate vertical displacement" excludes all 10/10. Delete it and the taskbar gets wrongly hidden.
    func testVerticalThreeFingerSwipeNeverFires() {
        var tracker = SpaceSwipeTracker()
        _ = tracker.consume(touches: 3, x: 0.50, y: 0.50, at: 0, naturalScrolling: true)
        // Worst measured sample: horizontal 0.055, vertical 0.267
        XCTAssertNil(tracker.consume(touches: 3, x: 0.555, y: 0.767, at: 0, naturalScrolling: true))
    }

    func testSwipeNeedsThreeFingersAndResetsWhenFingersLift() {
        var tracker = SpaceSwipeTracker()
        // Two-finger scrolling: no matter how large the horizontal displacement, it does not trigger
        _ = tracker.consume(touches: 2, x: 0.5, y: 0.5, at: 0, naturalScrolling: true)
        XCTAssertNil(tracker.consume(touches: 2, x: 0.1, y: 0.5, at: 0, naturalScrolling: true))
        // When fingers lift (fewer than three contacts) the anchor is re-set, and displacement across streaks does not accumulate
        _ = tracker.consume(touches: 3, x: 0.5, y: 0.5, at: 0, naturalScrolling: true)
        _ = tracker.consume(touches: 0, x: 0.0, y: 0.0, at: 0, naturalScrolling: true)
        XCTAssertNil(tracker.consume(touches: 3, x: 0.1, y: 0.5, at: 0, naturalScrolling: true))
    }

    func testSwipeFiresOnlyOncePerBurst() {
        var tracker = SpaceSwipeTracker()
        _ = tracker.consume(touches: 3, x: 0.6, y: 0.5, at: 0, naturalScrolling: true)
        XCTAssertEqual(tracker.consume(touches: 3, x: 0.4, y: 0.5, at: 0, naturalScrolling: true), .right)
        XCTAssertNil(tracker.consume(touches: 3, x: 0.2, y: 0.5, at: 0, naturalScrolling: true))
        XCTAssertNil(tracker.consume(touches: 3, x: 0.9, y: 0.5, at: 0, naturalScrolling: true))
    }

    private func makeSnapshot(
        generation: UInt64 = 9,
        focusedWindowID: CGWindowID = 456,
        buttonEnabled: Bool = true,
        isFullscreen: Bool = false,
        panelScreens: [CGRect] = [CGRect(x: 0, y: 0, width: 1512, height: 982)]
    ) -> FullscreenIntentSnapshot {
        FullscreenIntentSnapshot(
            generation: generation,
            pid: 123,
            focusedWindowID: focusedWindowID,
            buttonFrame: CGRect(x: 100, y: 100, width: 40, height: 20),
            windowFrame: CGRect(x: 80, y: 80, width: 900, height: 700),
            screenCGFrame: screen,
            panelScreenCGFrames: panelScreens,
            isFullscreen: isFullscreen,
            buttonEnabled: buttonEnabled
        )
    }


    // MARK: - Multi-display (2026-09-02)

    /// ③ With multiple displays all having bars: a request is sent as long as the display of the focused window is in the set.
    func testGreenButtonRequestFiresWhenScreenIsAnyPanelScreen() {
        let other = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
        let request = FullscreenIntentDecision.greenButtonRequest(
            location: CGPoint(x: 110, y: 110),
            flags: [],
            snapshot: makeSnapshot(panelScreens: [other, screen])
        )
        XCTAssertNotNil(request)
    }

    private func layout(current: Int, ordered: [Int], fullscreen: Set<Int>) -> SpaceLayoutSnapshot {
        SpaceLayoutSnapshot(orderedSpaceIDs: ordered, fullscreenSpaceIDs: fullscreen, currentSpaceID: current)
    }

    func testSpaceLayoutDirectoryLocatesDisplayUnderPointAndArrowTarget() {
        let a = SpaceLayoutDirectory.Entry(
            displayUUID: "A",
            appKitFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            layout: layout(current: 1, ordered: [1, 2], fullscreen: [])
        )
        let b = SpaceLayoutDirectory.Entry(
            displayUUID: "B",
            appKitFrame: CGRect(x: 1512, y: 0, width: 1920, height: 1080),
            layout: layout(current: 3, ordered: [3, 4], fullscreen: [4])
        )
        let directory = SpaceLayoutDirectory(entries: [a, b])
        XCTAssertTrue(directory.hasAnyFullscreenNeighbor)
        XCTAssertEqual(directory.entry(containing: CGPoint(x: 100, y: 100))?.displayUUID, "A")
        XCTAssertEqual(directory.entry(containing: CGPoint(x: 2000, y: 100))?.displayUUID, "B")
        XCTAssertNil(directory.entry(containing: CGPoint(x: -5, y: 5)))
        XCTAssertEqual(directory.displays(withFullscreenNeighbor: .right).map(\.displayUUID), ["B"])
        // Single candidate: the mouse is on A and still lands on B.
        XCTAssertEqual(directory.arrowTarget(.right, mouseLocation: CGPoint(x: 100, y: 100))?.displayUUID, "B")
        XCTAssertNil(directory.arrowTarget(.left, mouseLocation: CGPoint(x: 100, y: 100)))
    }

    func testSpaceLayoutDirectoryArrowTargetPrefersMouseDisplayAmongCandidates() {
        let a = SpaceLayoutDirectory.Entry(
            displayUUID: "A",
            appKitFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            layout: layout(current: 1, ordered: [1, 2], fullscreen: [2])
        )
        let b = SpaceLayoutDirectory.Entry(
            displayUUID: "B",
            appKitFrame: CGRect(x: 1512, y: 0, width: 1920, height: 1080),
            layout: layout(current: 3, ordered: [3, 4], fullscreen: [4])
        )
        let directory = SpaceLayoutDirectory(entries: [a, b])
        XCTAssertEqual(directory.arrowTarget(.right, mouseLocation: CGPoint(x: 2000, y: 50))?.displayUUID, "B")
        XCTAssertEqual(directory.arrowTarget(.right, mouseLocation: CGPoint(x: 10, y: 50))?.displayUUID, "A")
        // The mouse is on no candidate → the first display.
        XCTAssertEqual(directory.arrowTarget(.right, mouseLocation: CGPoint(x: -100, y: -100))?.displayUUID, "A")
    }
}
