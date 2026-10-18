import XCTest
@testable import NeoBar

/// Coordinate conversion for the carrier layer.
///
/// Three coordinate systems are involved at once (screen bottom-left origin / bottom-left origin inside the carrier panel / the `"strip"` space with top-left origin and y pointing down),
/// and mixing them up makes the icon fly toward the other end of the screen, an error that visual acceptance would only describe as "the animation feels off",
/// and nobody can tell at a glance whether y was flipped the wrong way or the origin was not subtracted. So pin it down.
final class DragCarrierGeometryTests: XCTestCase {
    /// Main screen 1512x982, origin at (0,0).
    private let main = CGRect(x: 0, y: 0, width: 1512, height: 982)

    // MARK: - The carrier panel covers only one screen at a time

    /// Two screens: the secondary screen is directly above the main one. The panel covers whichever screen the pointer is on, **not the union**:
    /// under "Displays have separate Spaces" a window belongs to a single screen and the out-of-bounds part is not drawn (the cause of the built-in screen "disappearing" on 2026-08-19).
    func testPanelFollowsTheScreenContainingThePoint() {
        let external = CGRect(x: -504, y: 982, width: 2560, height: 1440)
        XCTAssertEqual(DragCarrierGeometry.screenFrame(containing: CGPoint(x: 100, y: 100),
                                                       in: [main, external]), main)
        XCTAssertEqual(DragCarrierGeometry.screenFrame(containing: CGPoint(x: 100, y: 1500),
                                                       in: [main, external]), external)
    }

    /// A point on no screen (the edge at the instant of a screen switch) -> fall back to the first one, never `.zero`.
    func testPointOutsideEveryScreenFallsBackToTheFirst() {
        XCTAssertEqual(DragCarrierGeometry.screenFrame(containing: CGPoint(x: -9999, y: -9999),
                                                       in: [main]), main)
    }

    /// No screens (the panel is not built yet) -> `.zero`; callers treat it as "do not position, do not fly".
    func testNoScreensIsZero() {
        XCTAssertEqual(DragCarrierGeometry.screenFrame(containing: .zero, in: []), .zero)
    }

    // MARK: - Pixel alignment (the landing frame must not be blurry)

    /// 2x screen: a 52pt-wide layer with center 100.3 -> left edge 74.3pt = 148.6px -> rounded to 149px = 74.5pt -> center 100.5.
    func testPixelAlignedSnapsTheOriginToDevicePixels() {
        let center = DragCarrierGeometry.pixelAligned(center: CGPoint(x: 100.3, y: 40.2),
                                                      size: CGSize(width: 52, height: 66),
                                                      scale: 2)
        XCTAssertEqual(center.x, 100.5, accuracy: 0.0001)
        XCTAssertEqual(center.y, 40, accuracy: 0.0001)     // 7.2pt = 14.4px -> 14px = 7pt -> center 40
    }

    /// An already-aligned point is returned as is; scale <= 0 does nothing.
    func testPixelAlignedIsIdempotent() {
        let aligned = DragCarrierGeometry.pixelAligned(center: CGPoint(x: 100.5, y: 40),
                                                       size: CGSize(width: 52, height: 66), scale: 2)
        XCTAssertEqual(aligned, CGPoint(x: 100.5, y: 40))
        XCTAssertEqual(DragCarrierGeometry.pixelAligned(center: CGPoint(x: 1.234, y: 5.678),
                                                        size: CGSize(width: 10, height: 10), scale: 0),
                       CGPoint(x: 1.234, y: 5.678))
    }

    // MARK: - Screen -> inside the panel (both are bottom-left origin, differing only by a translation)

    func testScreenPointSubtractsThePanelOrigin() {
        let panel = CGRect(x: -504, y: 0, width: 2016, height: 982)
        let point = DragCarrierGeometry.panelPoint(screen: CGPoint(x: 100, y: 200), panelFrame: panel)
        XCTAssertEqual(point, CGPoint(x: 604, y: 200))
    }

    /// At drag start the carrier sits at the slot center. For a 40x54 card on the task strip, the visible bottom edge is at y=8.
    func testSlotCentreIsWhereTheCarrierStarts() {
        let slot = CGRect(x: 700, y: 8, width: 40, height: 54)
        let centre = DragCarrierGeometry.panelCenter(ofScreenRect: slot, panelFrame: main)
        XCTAssertEqual(centre, CGPoint(x: 720, y: 35))
    }

    // MARK: - Vertical sign flip of the grab offset (the easiest place to get wrong)

    /// `grabOffset` is measured in a **y-down** space such as `"strip"` / `"drawer"`
    /// (`frame.midY - startLocation.y`), whereas layer coordinates have y pointing up, so the vertical sign must be flipped.
    /// If flipped wrongly, pressing on the upper half of the card makes the copy jump below the cursor instead of above it.
    func testGrabOffsetVerticalIsInverted() {
        // Pressed 10pt above the card center -> in the y-down space grab.height = +10.
        let grab = CGSize(width: 6, height: 10)
        let centre = DragCarrierGeometry.carriedCenter(pointer: CGPoint(x: 400, y: 300),
                                                       grabOffset: grab, panelFrame: main)
        XCTAssertEqual(centre.x, 406)
        XCTAssertEqual(centre.y, 290)   // not 310
    }

    func testCarriedCentreAlsoSubtractsThePanelOrigin() {
        let panel = CGRect(x: -504, y: 982, width: 2560, height: 1440)
        let centre = DragCarrierGeometry.carriedCenter(pointer: CGPoint(x: 0, y: 1000),
                                                       grabOffset: .zero, panelFrame: panel)
        XCTAssertEqual(centre, CGPoint(x: 504, y: 18))
    }

    /// Re-grab: back out the grab offset from the carrier's current center, then feed it back to `carriedCenter`, which must return to the same point
    ///(pressing and dragging the icon mid-flight, the icon must not jump). Must also close with a negative origin on an external screen.
    func testGrabOffsetIsTheInverseOfCarriedCenter() {
        for panel in [main, CGRect(x: -504, y: 982, width: 2560, height: 1440)] {
            let pointer = CGPoint(x: 123.4, y: 1000.6)
            let centre = CGPoint(x: 700.25, y: 40.5)   // inside the panel
            let grab = DragCarrierGeometry.grabOffset(pointer: pointer, carriedCenter: centre, panelFrame: panel)
            let back = DragCarrierGeometry.carriedCenter(pointer: pointer, grabOffset: grab, panelFrame: panel)
            XCTAssertEqual(back.x, centre.x, accuracy: 0.0001)
            XCTAssertEqual(back.y, centre.y, accuracy: 0.0001)
        }
        // Direction: pointer is 6/10pt below-right of the icon center -> the same numbers as `testGrabOffsetVerticalIsInverted`.
        let grab = DragCarrierGeometry.grabOffset(pointer: CGPoint(x: 400, y: 300),
                                                  carriedCenter: CGPoint(x: 406, y: 290), panelFrame: main)
        XCTAssertEqual(grab, CGSize(width: 6, height: 10))
    }

    // MARK: - Seam with DragLandingPlan (top-left origin y-down <-> bottom-left origin y-up)

    /// The endpoint of `DragLandingPlan.flight` is "top-left origin inside the panel, y-down", and positioning has to flip it back.
    func testTopLeftPointFlipsIntoLayerCoordinates() {
        let flipped = DragCarrierGeometry.panelPoint(fromTopLeft: CGPoint(x: 720, y: 947),
                                                     panelFrame: main)
        XCTAssertEqual(flipped, CGPoint(x: 720, y: 35))
    }

    /// **The round trip must close**: slot center -> top-left-origin system (fed to `DragLandingPlan`) -> flipped back to layer coordinates,
    /// must return to the same point. These two steps are written in two separate places, and if the seam does not line up it is the kind of jitter where the landing is off by a few pt.
    func testRoundTripThroughTheLandingPlanCoordinateSystemIsClosed() {
        let slot = CGRect(x: 700, y: 8, width: 40, height: 54)
        let layerCentre = DragCarrierGeometry.panelCenter(ofScreenRect: slot, panelFrame: main)
        // DragLandingPlan uses exactly this conversion to compute the endpoint.
        let topLeft = CGPoint(x: slot.midX - main.minX, y: main.maxY - slot.midY)
        XCTAssertEqual(DragCarrierGeometry.panelPoint(fromTopLeft: topLeft, panelFrame: main),
                       layerCentre)
    }

    /// The flight **start point** likewise goes through the top-left-origin system, and must be the same physical point as the position while following the hand.
    func testFlightStartMatchesTheLiveCarriedPosition() {
        let pointer = CGPoint(x: 400, y: 300)
        let grab = CGSize(width: 6, height: 10)
        let live = DragCarrierGeometry.carriedCenter(pointer: pointer, grabOffset: grab, panelFrame: main)
        let start = DragCarrierGeometry.topLeftCarriedCenter(pointer: pointer, grabOffset: grab,
                                                             panelFrame: main)
        XCTAssertEqual(DragCarrierGeometry.panelPoint(fromTopLeft: start, panelFrame: main), live)
    }

    /// The one above must also hold on an external screen (panel origin negative): not subtracting the origin is the other half of this kind of bug.
    func testFlightStartMatchesTheLiveCarriedPositionOnAnExternalScreen() {
        let panel = CGRect(x: -504, y: 0, width: 2560, height: 1440)
        let pointer = CGPoint(x: -100, y: 900)
        let grab = CGSize(width: -4, height: 7)
        let live = DragCarrierGeometry.carriedCenter(pointer: pointer, grabOffset: grab, panelFrame: panel)
        let start = DragCarrierGeometry.topLeftCarriedCenter(pointer: pointer, grabOffset: grab,
                                                             panelFrame: panel)
        XCTAssertEqual(DragCarrierGeometry.panelPoint(fromTopLeft: start, panelFrame: panel), live)
    }

    // MARK: - Drag-start pose (composition of hover x press)

    /// A 54pt-tall medium-tier card, quiet-tier hover 1.10 (bottom anchor) + press 0.93 (center): overall 1.023, center of mass shifts up 2.51pt.
    /// These numbers are the real shape of the slot when the owner reported "up-and-down ghosting" on 2026-08-19; if the carrier is not positioned by them it will not line up.
    func testPickUpPoseCombinesBottomAnchoredHoverWithCentredPress() {
        let pose = DragCarrierGeometry.pickUpPose(chipHeight: 54, pressedScale: 0.93, hoverScale: 1.10)
        XCTAssertEqual(pose.scale, 1.023, accuracy: 0.0005)
        XCTAssertEqual(pose.dy, 2.511, accuracy: 0.001)
    }

    /// Press only, no hover (standard tier): pure center scaling, no upward shift.
    func testPickUpPosePressOnlyDoesNotShift() {
        let pose = DragCarrierGeometry.pickUpPose(chipHeight: 54, pressedScale: 0.93, hoverScale: nil)
        XCTAssertEqual(pose.scale, 0.93, accuracy: 0.0005)
        XCTAssertEqual(pose.dy, 0)
    }

    /// Hover only, no press (folder chip: 1.12 bottom-anchored enlargement, no press feedback).
    func testPickUpPoseHoverOnlyLiftsHalfTheGrowth() {
        let pose = DragCarrierGeometry.pickUpPose(chipHeight: 54, pressedScale: nil, hoverScale: 1.12)
        XCTAssertEqual(pose.scale, 1.12, accuracy: 0.0005)
        XCTAssertEqual(pose.dy, 0.12 * 54 / 2, accuracy: 0.001)
    }

    /// Nothing at all = resting.
    func testPickUpPoseRestingIsIdentity() {
        XCTAssertEqual(DragCarrierGeometry.pickUpPose(chipHeight: 54, pressedScale: nil, hoverScale: nil),
                       .resting)
    }
}
