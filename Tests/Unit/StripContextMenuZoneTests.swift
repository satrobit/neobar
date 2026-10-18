import XCTest
@testable import NeoBar

final class StripContextMenuZoneTests: XCTestCase {
    /// A typical taskbar at the medium-level baseline: inset 20pt, chips 40 wide, spacing 2pt,
    /// with a divider between the 2nd and 3rd chips (taking 9pt more, gap width 13pt).
    ///
    /// The numbers are taken from the real layout (`ChipPillMetrics.cardWidth` / `Style.chipSpacing`),
    /// but **deliberately written as literals here**: this fixture is input fed to a pure function, and if written as references it would change along with the implementation,
    /// which amounts to not testing. When changing layout constants, sync here by hand;
    /// `testThresholdSeparatesBothGapsAtEveryTier` will tell you if anything was missed.
    private let bounds = CGRect(x: 0, y: 0, width: 300, height: 54)
    private let chips: [CGRect] = [
        CGRect(x: 20, y: 0, width: 40, height: 54),    // 20...60
        CGRect(x: 62, y: 0, width: 40, height: 54),    // 62...102 (2pt gap from the previous one)
        CGRect(x: 115, y: 0, width: 40, height: 54),   // 115...155 (13pt gap from the previous one: the divider)
    ]
    private let gap = StripContextMenuZone.defaultMinimumGapWidth

    private func claims(x: CGFloat) -> Bool {
        StripContextMenuZone.claims(
            point: CGPoint(x: x, y: 26),
            chipFrames: chips,
            bounds: bounds,
            minimumGapWidth: gap
        )
    }

    func testLeftInsetClaims() {
        XCTAssertTrue(claims(x: 10))
    }

    func testRightInsetClaims() {
        XCTAssertTrue(claims(x: 250))
    }

    func testDividerGapClaims() {
        // The gap is 102...115, center 108.5.
        XCTAssertTrue(claims(x: 108))
    }

    /// This one is the **purpose** of this change: when aiming at an icon but missing by a few pt and landing in the narrow gap, better to do nothing
    /// than to pop up the NeoBar menu and displace that app's own menu.
    func testPlainChipGapDoesNotClaim() {
        // The gap is 60...62, only 2pt.
        XCTAssertFalse(claims(x: 61))
    }

    func testPointOnAChipDoesNotClaim() {
        XCTAssertFalse(claims(x: 40))
        XCTAssertFalse(claims(x: 82))
    }

    func testPointOutsideBoundsDoesNotClaim() {
        XCTAssertFalse(claims(x: -5))
        XCTAssertFalse(StripContextMenuZone.claims(
            point: CGPoint(x: 100, y: 999),
            chipFrames: chips,
            bounds: bounds,
            minimumGapWidth: gap
        ))
    }

    /// When no chip has been measured yet in the first frame, don't recognize it: at that moment we can't tell whether the click is on an icon,
    /// and stealing that app's menu is worse than missing one popup.
    func testEmptyFramesDoNotClaim() {
        XCTAssertFalse(StripContextMenuZone.claims(
            point: CGPoint(x: 10, y: 26),
            chipFrames: [],
            bounds: bounds,
            minimumGapWidth: gap
        ))
    }

    /// Both kinds of gap must be distinguishable at all four levels: the threshold and the geometry scale together.
    ///
    /// **This is the guard for `Style.chipSpacing`.** When on 2026-08-16 icon spacing was aligned to native
    /// (center spacing 52->42pt, chipSpacing 8->2), the divider gap shrank from 21pt to 9pt,
    /// while the threshold was still 12pt, which would make even the divider gap unrecognizable and break right-click on the whole taskbar.
    /// This very test caught it.
    func testThresholdSeparatesBothGapsAtEveryTier() {
        for scale in [40, 54, 80].map({ DockPanelHeight(clamping: $0).scale }) {
            let plainGap: CGFloat = 2 * scale
            let dividerGap: CGFloat = StripContextMenuZone.dividerGapWidth * scale
            let threshold: CGFloat = StripContextMenuZone.defaultMinimumGapWidth * scale
            XCTAssertLessThan(plainGap, threshold, "普通缝在 scale=\(scale) 下不该被认")
            XCTAssertGreaterThan(dividerGap, threshold, "分割线缝在 scale=\(scale) 下必须被认")
        }
    }

    /// Overlapping frames (frames expanded in the messaging area, temporary positions during a drag) must not be counted as a gap.
    func testOverlappingFramesDoNotSynthesizeAGap() {
        let overlapping = [
            CGRect(x: 20, y: 0, width: 40, height: 54),   // 20...60
            CGRect(x: 52, y: 0, width: 40, height: 54),   // 52...92, overlaps the previous one
            CGRect(x: 84, y: 0, width: 40, height: 54),   // 84...124, overlaps the previous one
        ]
        for x in stride(from: CGFloat(21), to: 123, by: 3) {
            XCTAssertFalse(
                StripContextMenuZone.claims(
                    point: CGPoint(x: x, y: 26),
                    chipFrames: overlapping,
                    bounds: bounds,
                    minimumGapWidth: gap
                ),
                "x=\(x) 落在连续覆盖区里，不该被当成缝"
            )
        }
    }
    /// The fixtures above hard-code the 13pt divider gap; this fails when the layout constant
    /// moves without them.
    func testDividerGapWidthMatchesTheFixtures() {
        XCTAssertEqual(StripContextMenuZone.dividerGapWidth, 13)
        XCTAssertEqual(chips[2].minX - chips[1].maxX, StripContextMenuZone.dividerGapWidth)
    }

    // MARK: - Drag-to-resize grip

    private func gripClaims(x: CGFloat, scale: CGFloat = 1) -> Bool {
        StripContextMenuZone.gripClaims(
            point: CGPoint(x: x, y: 26),
            chipFrames: chips,
            bounds: bounds,
            minimumGapWidth: gap * scale,
            chipClearance: StripContextMenuZone.defaultGripChipClearance * scale
        )
    }

    /// The divider gap is 102...115; the grip keeps 2.5pt off each chip, leaving 104.5...112.5.
    func testGripClaimsOnlyTheMiddleOfTheDividerGap() {
        XCTAssertTrue(gripClaims(x: 108.5))
        XCTAssertTrue(gripClaims(x: 105))
        XCTAssertTrue(gripClaims(x: 112))
        XCTAssertFalse(gripClaims(x: 103), "next to the left icon")
        XCTAssertFalse(gripClaims(x: 114), "next to the right icon")
        XCTAssertTrue(claims(x: 103), "right-click keeps the full gap")
        XCTAssertTrue(claims(x: 114), "right-click keeps the full gap")
    }

    /// With a divider on the bar the grip lives in its gap alone; right-click keeps the ends.
    func testGripLeavesTheEndInsetsWhenADividerExists() {
        XCTAssertFalse(gripClaims(x: 10))
        XCTAssertFalse(gripClaims(x: 250))
        XCTAssertTrue(claims(x: 10))
        XCTAssertTrue(claims(x: 250))
    }

    /// A single-zone bar has no divider, so the end insets are the only grip — still kept clear
    /// of the end icons.
    func testGripFallsBackToTheEndInsetsWithoutADivider() {
        let singleZone = Array(chips.prefix(2))   // 20...60, 62...102
        func grip(_ x: CGFloat) -> Bool {
            StripContextMenuZone.gripClaims(
                point: CGPoint(x: x, y: 26),
                chipFrames: singleZone,
                bounds: bounds,
                minimumGapWidth: gap,
                chipClearance: StripContextMenuZone.defaultGripChipClearance
            )
        }
        XCTAssertTrue(grip(10))
        XCTAssertFalse(grip(18), "next to the first icon")
        XCTAssertTrue(grip(250))
        XCTAssertFalse(grip(104), "next to the last icon")
        XCTAssertFalse(grip(61), "plain chip gap")
    }

    func testHasDividerGapIgnoresPlainGapsAndOverlaps() {
        XCTAssertTrue(StripContextMenuZone.hasDividerGap(chipFrames: chips, minimumGapWidth: gap))
        XCTAssertFalse(StripContextMenuZone.hasDividerGap(chipFrames: Array(chips.prefix(2)), minimumGapWidth: gap))
        XCTAssertFalse(StripContextMenuZone.hasDividerGap(chipFrames: [], minimumGapWidth: gap))
        let overlapping = [
            CGRect(x: 20, y: 0, width: 80, height: 54),   // 20...100
            CGRect(x: 30, y: 0, width: 40, height: 54),   // 30...70, inside the first
            CGRect(x: 102, y: 0, width: 40, height: 54),  // 2pt after the first, 32pt after the second
        ]
        XCTAssertFalse(StripContextMenuZone.hasDividerGap(chipFrames: overlapping, minimumGapWidth: gap))
    }

    func testGripNeverClaimsWhatRightClickRejects() {
        for x in stride(from: CGFloat(-5), to: 305, by: 0.5) {
            if gripClaims(x: x) { XCTAssertTrue(claims(x: x), "x=\(x)") }
        }
    }

    /// The ▲▼ cursor (9pt, unscaled) at the band's edge must not reach the neighbouring icon's
    /// artwork (~9.75% transparent margin inside the 40pt card), and the band must stay
    /// non-empty, at every height.
    func testGripBandLeavesTheGlyphClearOfIconsAtEveryTier() {
        for scale in [40, 54, 80].map({ DockPanelHeight(clamping: $0).scale }) {
            let dividerGap: CGFloat = StripContextMenuZone.dividerGapWidth * scale
            let clearance = StripContextMenuZone.defaultGripChipClearance * scale
            let bandHalfWidth = dividerGap / 2 - clearance
            XCTAssertGreaterThan(bandHalfWidth, 1, "grip band vanishes at scale=\(scale)")
            let iconArtworkEdge = dividerGap / 2 + 40 * scale * 0.0975
            XCTAssertLessThanOrEqual(bandHalfWidth + 4.5, iconArtworkEdge, "glyph overlaps icons at scale=\(scale)")
        }
    }
}
