import XCTest
@testable import NeoBar

/// Pure decision logic for the landing flight after release. What is pinned here is mainly the **coordinate conversion**: the screen has a bottom-left origin and the carrier panel a top-left origin,
/// and if the two get mixed up the icon flies toward the other end of the screen, an error that in eyeball acceptance would only be described as "the animation feels off".
final class DragLandingPlanTests: XCTestCase {
    /// Main screen 1512x982; the carrier panel always covers the whole screen.
    private let carrier = CGRect(x: 0, y: 0, width: 1512, height: 982)

    func testAnchorCentreConvertsToCarrierPanelCoordinates() {
        // A 40x54 card on the taskbar, with the visible area's bottom edge at y=8 (screen bottom-left origin).
        let slot = CGRect(x: 700, y: 8, width: 40, height: 54)
        let flight = DragLandingPlan.flight(from: CGPoint(x: 900, y: 400),
                                            fromScale: DragLandingPlan.carriedScale,
                                            anchorScreenRect: slot,
                                            carrierScreenFrame: carrier)
        // Center x = 720; y has to be flipped: 982 - 35 = 947 (top-left origin inside the panel).
        XCTAssertEqual(flight?.to.x, 720)
        XCTAssertEqual(flight?.to.y, 947)
    }

    /// When the carrier panel isn't at the main screen's origin (an external display), the conversion must subtract the panel's own origin.
    func testCarrierOriginIsSubtracted() {
        let external = CGRect(x: -504, y: 982, width: 2560, height: 1440)
        let slot = CGRect(x: 0, y: 1000, width: 40, height: 54)
        let flight = DragLandingPlan.flight(from: .zero,
                                            fromScale: 1,
                                            anchorScreenRect: slot,
                                            carrierScreenFrame: external)
        XCTAssertEqual(flight?.to.x, 20 - (-504))
        XCTAssertEqual(flight?.to.y, (982 + 1440) - 1027)
    }

    /// The start point and starting scale are carried through as is: the carrier is shrunk inside the drop zone (0.82), and the flight must begin from that size,
    /// otherwise at the moment of release it would first jump bigger and then fly.
    func testStartStateIsCarriedThrough() {
        let flight = DragLandingPlan.flight(from: CGPoint(x: 123, y: 456),
                                            fromScale: DragLandingPlan.dropZoneScale,
                                            anchorScreenRect: CGRect(x: 0, y: 0, width: 40, height: 40),
                                            carrierScreenFrame: carrier)
        XCTAssertEqual(flight?.from, CGPoint(x: 123, y: 456))
        XCTAssertEqual(flight?.fromScale, DragLandingPlan.dropZoneScale)
    }

    /// The end scale is always 1: at the moment of landing it must be pixel-identical in size to the card on the strip, or the carrier would flash when torn down.
    func testAlwaysLandsAtNativeScale() {
        for start in [DragLandingPlan.carriedScale, DragLandingPlan.dropZoneScale] {
            let flight = DragLandingPlan.flight(from: .zero, fromScale: start,
                                                anchorScreenRect: CGRect(x: 0, y: 0, width: 40, height: 40),
                                                carrierScreenFrame: carrier)
            XCTAssertEqual(flight?.toScale, 1.0)
        }
    }

    // MARK: - Cases with no flight (always fall back to the pre-rework instant finish, zero risk)

    /// No landing point available -> no flight. The branch that promotes into the taskbar is exactly this case: release unfreezes the strip width and re-centers the whole strip,
    /// and the landing point still drifts during the flight; better not to fly than to fly crooked.
    func testNoAnchorMeansNoFlight() {
        XCTAssertNil(DragLandingPlan.flight(from: .zero, fromScale: 1,
                                            anchorScreenRect: nil, carrierScreenFrame: carrier))
    }

    /// A frame not yet measured (`.zero` / zero width or height) can't serve as a landing point; it would make the icon fly to the screen's bottom-left corner.
    func testUnmeasuredAnchorIsRejected() {
        XCTAssertNil(DragLandingPlan.flight(from: .zero, fromScale: 1,
                                            anchorScreenRect: .zero, carrierScreenFrame: carrier))
        XCTAssertNil(DragLandingPlan.flight(from: .zero, fromScale: 1,
                                            anchorScreenRect: CGRect(x: 10, y: 10, width: 0, height: 54),
                                            carrierScreenFrame: carrier))
    }

    /// Same when the carrier panel hasn't been built yet (frame is empty).
    func testEmptyCarrierFrameIsRejected() {
        XCTAssertNil(DragLandingPlan.flight(from: .zero, fromScale: 1,
                                            anchorScreenRect: CGRect(x: 0, y: 0, width: 40, height: 40),
                                            carrierScreenFrame: .zero))
    }

    // MARK: - Duration depends on distance (owner 2026-08-18: "no native animation feels this graceful and unhurried")

    /// A fixed duration makes short distances feel hurried and long distances rushed. The farther the distance, the longer the flight, but both ends are clamped.
    func testDurationGrowsWithDistanceAndIsClampedAtBothEnds() {
        XCTAssertEqual(DragLandingPlan.duration(travel: 0), DragLandingPlan.minimumDuration)
        XCTAssertEqual(DragLandingPlan.duration(travel: DragLandingPlan.referenceTravel),
                       DragLandingPlan.maximumFlightDuration, accuracy: 0.0001)
        // Adds nothing beyond this distance, otherwise ultra-long cross-screen distances would drag.
        XCTAssertEqual(DragLandingPlan.duration(travel: 5000),
                       DragLandingPlan.maximumFlightDuration, accuracy: 0.0001)
        // A negative value (shouldn't occur) must also not pass below the lower bound.
        XCTAssertEqual(DragLandingPlan.duration(travel: -10), DragLandingPlan.minimumDuration)
    }

    /// Square root rather than linear: **short distances must be more generous than linear**, otherwise a small snap flashes by unseen.
    func testShortTravelIsMoreGenerousThanLinear() {
        let quarter = DragLandingPlan.referenceTravel / 4
        let linear = DragLandingPlan.minimumDuration
            + (DragLandingPlan.maximumFlightDuration - DragLandingPlan.minimumDuration) * 0.25
        XCTAssertGreaterThan(DragLandingPlan.duration(travel: quarter), linear)
    }

    /// Every flight carries its own duration; the view and the timer read the same value, and computing them separately would make them drift.
    func testFlightCarriesItsOwnDuration() {
        let near = DragLandingPlan.flight(from: CGPoint(x: 100, y: 100), fromScale: 1,
                                          anchorScreenRect: CGRect(x: 90, y: 870, width: 40, height: 54),
                                          carrierScreenFrame: carrier)
        let far = DragLandingPlan.flight(from: CGPoint(x: 100, y: 100), fromScale: 1,
                                         anchorScreenRect: CGRect(x: 1200, y: 8, width: 40, height: 54),
                                         carrierScreenFrame: carrier)
        XCTAssertNotNil(near?.duration)
        XCTAssertLessThan(near!.duration, far!.duration)
    }

    /// **Only sub-pixel landing points don't fly.** After the bitmap carrier, even a 5pt "click hand shake" still flies: the copy is opaque,
    /// pixel-for-pixel equal to the slot, and flying back only looks better than jumping; the old 12pt gate turned more than half of in-strip landings
    /// into instant jumps (owner 2026-08-19: "the short-distance flight animation is too fast").
    func testOnlySubPixelTravelSkipsTheFlight() {
        let slot = CGRect(x: 700, y: 8, width: 40, height: 54)
        let centre = CGPoint(x: 720, y: 982 - 35)
        let subPixel = CGPoint(x: centre.x + 0.3, y: centre.y + 0.2)
        XCTAssertNil(DragLandingPlan.flight(from: subPixel, fromScale: 1,
                                            anchorScreenRect: slot, carrierScreenFrame: carrier))
        let jitter = CGPoint(x: centre.x + 4, y: centre.y + 3)
        XCTAssertNotNil(DragLandingPlan.flight(from: jitter, fromScale: 1,
                                               anchorScreenRect: slot, carrierScreenFrame: carrier))
    }

    /// A real drag still flies, no exceptions.
    func testTravelBeyondTheThresholdStillFlies() {
        let slot = CGRect(x: 700, y: 8, width: 40, height: 54)
        let away = CGPoint(x: 720 + DragLandingPlan.minimumTravel + 6, y: 982 - 35)
        XCTAssertNotNil(DragLandingPlan.flight(from: away, fromScale: 1,
                                               anchorScreenRect: slot, carrierScreenFrame: carrier))
    }

    /// The threshold must be **smaller than** the drag-start threshold of 8pt: every real drag start (>= 8pt) must get a landing flight on release, and it must not be lifted back to double digits
    /// for "click hand shake", which was exactly the source of the instant jump on short-distance landings. It can't be 0 either (don't fly for sub-pixel moves).
    func testThresholdOnlyBlocksSubPixelTravel() {
        XCTAssertGreaterThan(DragLandingPlan.minimumTravel, 0)
        XCTAssertLessThan(DragLandingPlan.minimumTravel, 8)
    }

    // MARK: - Curve depends on distance (owner 2026-08-19: "the short-distance flight animation is too fast")

    /// Both ends are locked: short trip = `shortCurve`, long trip = the original (0.2, 0.9, 0.3, 1.0), with the literal hard-coded;
    /// nobody should casually change the long-trip feel the owner approved.
    func testCurveEndsAreFrozen() {
        XCTAssertEqual(DragLandingPlan.curve(travel: 0), DragLandingPlan.shortCurve)
        let long = DragLandingCurve(c0x: 0.2, c0y: 0.9, c1x: 0.3, c1y: 1.0)
        XCTAssertEqual(DragLandingPlan.curve(travel: DragLandingPlan.referenceTravel), long)
        XCTAssertEqual(DragLandingPlan.curve(travel: 5000), long)
        XCTAssertEqual(DragLandingPlan.curve, long)
    }

    /// Nearer is gentler: the short-trip curve's y control points are all lower than the long trip's (the long trip covers 61% in 17% of the time; the short trip can't be that aggressive).
    func testShortCurveIsGentlerThanTheLongOne() {
        XCTAssertLessThan(DragLandingPlan.shortCurve.c0y, DragLandingPlan.curve.c0y)
        XCTAssertLessThanOrEqual(DragLandingPlan.shortCurve.c1y, DragLandingPlan.curve.c1y)
    }

    /// Continuous transition in the middle: every control point lies between the two ends, using the same progress number as the duration.
    func testCurveInterpolatesBetweenTheEnds() {
        let mid = DragLandingPlan.curve(travel: DragLandingPlan.referenceTravel / 4)
        let f = DragLandingPlan.travelFactor(DragLandingPlan.referenceTravel / 4)
        XCTAssertEqual(f, 0.5, accuracy: 0.0001)
        func between(_ v: Double, _ a: Double, _ b: Double) -> Bool { v >= min(a, b) && v <= max(a, b) }
        XCTAssertTrue(between(mid.c0x, DragLandingPlan.shortCurve.c0x, DragLandingPlan.curve.c0x))
        XCTAssertTrue(between(mid.c0y, DragLandingPlan.shortCurve.c0y, DragLandingPlan.curve.c0y))
        XCTAssertTrue(between(mid.c1x, DragLandingPlan.shortCurve.c1x, DragLandingPlan.curve.c1x))
        XCTAssertTrue(between(mid.c1y, DragLandingPlan.shortCurve.c1y, DragLandingPlan.curve.c1y))
        XCTAssertEqual(mid.c0y, DragLandingPlan.shortCurve.c0y
                       + (DragLandingPlan.curve.c0y - DragLandingPlan.shortCurve.c0y) * f, accuracy: 0.0001)
    }

    /// Curve evaluation (to compute where the icon is on re-grab): 0 / 1 at the ends, monotonic, matching the hand-computed shape
    /// (long trip covers about 61% at 17% of the time; short trip about 77% at 50% of the time).
    func testCurveProgressMatchesTheBezier() {
        let long = DragLandingPlan.curve, short = DragLandingPlan.shortCurve
        XCTAssertEqual(long.progress(at: 0), 0)
        XCTAssertEqual(long.progress(at: 1), 1)
        XCTAssertEqual(long.progress(at: -1), 0)
        XCTAssertEqual(long.progress(at: 2), 1)
        XCTAssertEqual(long.progress(at: 0.17), 0.61, accuracy: 0.03)
        XCTAssertEqual(short.progress(at: 0.5), 0.77, accuracy: 0.02)
        var previous = 0.0
        for i in 1...100 {
            let v = long.progress(at: Double(i) / 100)
            XCTAssertGreaterThanOrEqual(v, previous - 1e-9)
            previous = v
        }
        XCTAssertGreaterThan(long.progress(at: 0.3), short.progress(at: 0.3), "长途更抢")
    }

    /// Every flight carries its own curve, like `duration`; the controller must read the same value.
    func testFlightCarriesItsOwnCurve() {
        let near = DragLandingPlan.flight(from: CGPoint(x: 100, y: 100), fromScale: 1,
                                          anchorScreenRect: CGRect(x: 90, y: 870, width: 40, height: 54),
                                          carrierScreenFrame: carrier)!
        let travel = hypot(near.to.x - near.from.x, near.to.y - near.from.y)
        XCTAssertEqual(near.curve, DragLandingPlan.curve(travel: travel))
        XCTAssertNotEqual(near.curve, DragLandingPlan.curve)   // a short trip is not the long-trip curve
    }

    // MARK: - Absorbed into the capsule (owner 2026-08-19: after stashing, the icon drifted toward the taskbar's end and then vanished)

    /// Releasing on the capsule to stash: endpoint = capsule center, shrink to 0.3, fade to 0, fixed duration; not flying back to the slot.
    func testStashFlightShrinksAndFadesIntoTheTarget() {
        let capsule = CGRect(x: 1400, y: 8, width: 44, height: 54)
        let flight = DragLandingPlan.stashFlight(from: CGPoint(x: 1300, y: 900), fromScale: 0.82,
                                                 targetScreenRect: capsule, carrierScreenFrame: carrier)!
        XCTAssertEqual(flight.to, CGPoint(x: 1422, y: 982 - 35))
        XCTAssertEqual(flight.fromScale, 0.82)
        XCTAssertEqual(flight.toScale, DragLandingPlan.stashScale)
        XCTAssertEqual(flight.toOpacity, 0)
        XCTAssertEqual(flight.duration, DragLandingPlan.stashDuration)
        XCTAssertLessThan(DragLandingPlan.stashScale, 0.5, "得看出来是被吸进去")
        // Capsule location unknown -> no flight (finish instantly); it must never fall back to "fly back to the slot".
        XCTAssertNil(DragLandingPlan.stashFlight(from: .zero, fromScale: 1, targetScreenRect: nil,
                                                 carrierScreenFrame: carrier))
    }

    /// A regular landing flight is opaque on landing.
    func testReturnFlightLandsOpaque() {
        let flight = DragLandingPlan.flight(from: CGPoint(x: 100, y: 100), fromScale: 1,
                                            anchorScreenRect: CGRect(x: 90, y: 870, width: 40, height: 54),
                                            carrierScreenFrame: carrier)!
        XCTAssertEqual(flight.toOpacity, 1)
    }

    // MARK: - Time gate for mid-flight correction (owner 2026-08-18: landing sometimes jitters)

    /// Near the cap, correction is **not allowed** any more: re-launching a leg then would inevitably be truncated by the cap,
    /// producing exactly the jump we are trying to cure.
    func testRetargetIsRefusedNearTheDeadline() {
        XCTAssertFalse(DragLandingPlan.allowsRetarget(remainingBeforeDeadline: 0))
        XCTAssertFalse(DragLandingPlan.allowsRetarget(
            remainingBeforeDeadline: DragLandingPlan.duration))
        XCTAssertFalse(DragLandingPlan.allowsRetarget(remainingBeforeDeadline: -1))
    }

    /// Allow it while there's enough time: correction itself is the remedy for "the slot is still moving and the endpoint drifts", and can't be cut off wholesale.
    func testRetargetIsAllowedWhileThereIsRoomForAWholeFlight() {
        XCTAssertTrue(DragLandingPlan.allowsRetarget(
            remainingBeforeDeadline: DragLandingPlan.maximumDuration))
    }

    /// The cap must accommodate at least one full correction re-flight, otherwise that gate is forever closed and correction is nominal.
    func testDeadlineLeavesRoomForAtLeastOneRetarget() {
        XCTAssertGreaterThan(DragLandingPlan.maximumDuration,
                             2 * (DragLandingPlan.duration + DragLandingPlan.settleMargin))
    }

    /// Post-takeoff correction slides only the endpoint: duration, curve, start, opacity are all kept. If recomputed from the new distance,
    /// each correction would restart from this moment and ease to a stop, which when the anchor drifts frame by frame is the "stutter" (2026-09-03).
    func testSlidingARetargetKeepsTheTimelineAndOnlyMovesTheDestination() {
        let carrier = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let flight = DragLandingPlan.flight(from: CGPoint(x: 500, y: 100), fromScale: 1,
                                            anchorScreenRect: CGRect(x: 90, y: 870, width: 40, height: 54),
                                            carrierScreenFrame: carrier)!
        let slid = flight.sliding(to: CGPoint(x: 480, y: 120), toScale: 0.5)
        XCTAssertEqual(slid.to, CGPoint(x: 480, y: 120))
        XCTAssertEqual(slid.toScale, 0.5)
        XCTAssertEqual(slid.from, flight.from)
        XCTAssertEqual(slid.fromScale, flight.fromScale)
        XCTAssertEqual(slid.duration, flight.duration)
        XCTAssertEqual(slid.curve, flight.curve)
        XCTAssertEqual(slid.toOpacity, flight.toOpacity)
    }

    /// No anchor at release -> hold-in-place flight: start = end, normal size on landing; it is a placeholder for "waiting for the anchor",
    /// and if it is still this at takeoff it should settle directly (`isStationary`); a real flight is never stationary.
    func testHoldingFlightIsStationaryAndARealFlightIsNot() {
        let held = DragLandingPlan.holdingFlight(at: CGPoint(x: 500, y: 100), scale: 1)
        XCTAssertTrue(held.isStationary)
        XCTAssertEqual(held.from, held.to)
        XCTAssertEqual(held.toScale, DragLandingPlan.landedScale)
        XCTAssertEqual(held.toOpacity, 1)
        let carrier = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let real = DragLandingPlan.flight(from: CGPoint(x: 500, y: 100), fromScale: 1,
                                          anchorScreenRect: CGRect(x: 90, y: 870, width: 40, height: 54),
                                          carrierScreenFrame: carrier)!
        XCTAssertFalse(real.isStationary)
        // After correction replaces the hold with a real flight it likewise is no longer stationary; conversely, sliding back to the origin counts as holding again
        XCTAssertFalse(held.sliding(to: real.to, toScale: real.toScale).isStationary)
    }


    /// The lift (sliding from the slot to under the pointer) must be noticeably shorter than the landing flight: it is the **handover** action of drag start,
    /// and if it were long it would become "drag start has to wait a moment", exactly the kind of lag we're trying to cure.
    ///
    /// The gate used to be `/ 3`; after landing was reduced from 0.60 to 0.32 on 2026-08-19 it was relaxed to `/ 2`. **The intent hasn't changed**
    /// (lift clearly shorter than landing); what changed is landing itself. If it's tightened again, re-decide the lift together with it, don't change just this number.
    func testLiftIsMuchShorterThanTheReturnFlight() {
        XCTAssertLessThan(DragLandingPlan.liftDuration, DragLandingPlan.minimumDuration / 2)
        XCTAssertGreaterThan(DragLandingPlan.liftDuration, 0)
    }

    // MARK: - Speed knob (owner 2026-08-19: "can the landing flight be made a bit faster")

    /// The duration table itself should be at the "native order of magnitude": the shortest segment shouldn't be so long that it reads as dragging, nor so short that the animation is invisible.
    func testDurationTableStaysInTheNativeBallpark() {
        XCTAssertGreaterThan(DragLandingPlan.minimumDuration, 0.15)
        XCTAssertLessThan(DragLandingPlan.minimumDuration, 0.45)
        XCTAssertGreaterThan(DragLandingPlan.maximumFlightDuration, DragLandingPlan.minimumDuration)
        XCTAssertLessThan(DragLandingPlan.maximumFlightDuration, 0.70)
    }

    /// `DOCK_DRAG_FLIGHT_MS` accepts only "two positive numbers with min <= max"; anything else is treated as unset.
    /// **Half-applied is worse than not applied** (if only the lower bound were changed, the two ends of the curve would be reversed).
    func testFlightDurationOverrideRejectsAnythingMalformed() {
        for bad in ["", "320", "320,", ",500", "abc,500", "320,abc", "0,500", "-320,500", "500,320", "320,500,700"] {
            XCTAssertNil(DragLandingPlan.parseFlightDurations(bad), "「\(bad)」不该被接受")
        }
        let good = DragLandingPlan.parseFlightDurations("320,500")
        XCTAssertEqual(good?.minimum ?? 0, 0.32, accuracy: 0.0001)
        XCTAssertEqual(good?.maximum ?? 0, 0.50, accuracy: 0.0001)
        // Equal ends are valid (a fixed-duration flight), and spaces must be tolerated
        XCTAssertNotNil(DragLandingPlan.parseFlightDurations(" 400 , 400 "))
    }
}
