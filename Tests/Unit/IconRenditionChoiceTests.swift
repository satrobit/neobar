import XCTest

/// Which stored rendition feeds a chip's exact-pixel bitmap, and the stand-in used mid-drag.
final class IconRenditionChoiceTests: XCTestCase {
    private typealias Rendition = IconRenditionChoice.Rendition

    /// The system app-icon set after `AppIconResolver` drops the plated small @1x renditions.
    private let appIcon: [Rendition] = [
        .init(points: 16, pixels: 32), .init(points: 18, pixels: 36), .init(points: 24, pixels: 48),
        .init(points: 32, pixels: 64),
        .init(points: 128, pixels: 128), .init(points: 128, pixels: 256),
        .init(points: 256, pixels: 256), .init(points: 256, pixels: 512),
        .init(points: 512, pixels: 512), .init(points: 512, pixels: 1024),
        .init(points: 1024, pixels: 1024), .init(points: 1024, pixels: 2048),
    ]

    private func chosen(points: CGFloat, scale: CGFloat, in set: [Rendition]? = nil) -> Rendition? {
        let set = set ?? appIcon
        return IconRenditionChoice.sourceIndex(in: set, points: points, displayScale: scale).map { set[$0] }
    }

    func testPixelsRoundsTheTargetEdge() {
        XCTAssertEqual(IconRenditionChoice.pixels(points: 40 * 120 / 54, displayScale: 2), 178)
        XCTAssertEqual(IconRenditionChoice.pixels(points: 40 * 71 / 54, displayScale: 1), 53)
        XCTAssertEqual(IconRenditionChoice.pixels(points: 0, displayScale: 2), 1)
    }

    func testRetinaNativeSlotUsesThe128ptArtworkAt2x() {
        XCTAssertEqual(chosen(points: 40, scale: 2), Rendition(points: 128, pixels: 256))
    }

    func testRetinaTallestBarStillCoversInPixels() {
        // 88.89pt → 178px: 128pt@2x (256px) covers; 128pt@1x would be an upscale.
        XCTAssertEqual(chosen(points: 40 * 120 / 54, scale: 2), Rendition(points: 128, pixels: 256))
    }

    func testOneXDisplayUsesThe128ptArtworkAt1xNotTheSmallArtworkAt2x() {
        // The "blurry" case: 53px used to come from the 64px 32pt@2x rendition.
        XCTAssertEqual(chosen(points: 40 * 71 / 54, scale: 1), Rendition(points: 128, pixels: 128))
        XCTAssertEqual(chosen(points: 40 * 110 / 54, scale: 1), Rendition(points: 128, pixels: 128))
    }

    func testSmallTargetTakesTheSmallestCoveringArtworkEvenAtAnotherScale() {
        // Drawer capsule preview: the small @1x renditions are gone (plated), so the 18pt artwork
        // comes from its @2x rendition on a 1x display too.
        XCTAssertEqual(chosen(points: 18, scale: 1), Rendition(points: 18, pixels: 36))
        XCTAssertEqual(chosen(points: 18, scale: 2), Rendition(points: 18, pixels: 36))
        // 24pt on 1x: the 24pt@2x rendition, not the 32pt one.
        XCTAssertEqual(chosen(points: 24, scale: 1), Rendition(points: 24, pixels: 48))
    }

    func testNothingCoversFallsBackToTheLargestRendition() {
        XCTAssertEqual(chosen(points: 2000, scale: 2), Rendition(points: 1024, pixels: 2048))
        XCTAssertEqual(chosen(points: 40, scale: 2, in: [.init(points: 32, pixels: 32)]), Rendition(points: 32, pixels: 32))
    }

    func testEmptyListHasNoSource() {
        XCTAssertNil(IconRenditionChoice.sourceIndex(in: [], points: 40, displayScale: 2))
    }

    func testStandInPrefersTheSmallestRenderedSizeThatCovers() {
        XCTAssertEqual(IconRenditionChoice.standInPixels(rendered: [80, 105, 178], target: 150), 178)
        XCTAssertEqual(IconRenditionChoice.standInPixels(rendered: [80, 105, 178], target: 90), 105)
        XCTAssertEqual(IconRenditionChoice.standInPixels(rendered: [80, 105, 178], target: 200), 178)
        XCTAssertNil(IconRenditionChoice.standInPixels(rendered: [], target: 90))
    }
}
