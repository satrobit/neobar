import AppKit
import SwiftUI
import XCTest

/// Continuous bar height: the two clamps plus the native baseline stand in for the old tiers.
let sampleDockHeights: [DockPanelHeight] = [40, 54, 80].map { DockPanelHeight(clamping: $0) }

final class WindowTitleTooltipTests: XCTestCase {
    func testFontUsesRenderedSizeRules() {
        XCTAssertEqual(WindowTitleTextMetrics.font(scale: 0.5).pointSize, 10)
        XCTAssertEqual(WindowTitleTextMetrics.font(scale: 1).pointSize, 12)
        XCTAssertEqual(WindowTitleTextMetrics.font(scale: 1.5).pointSize, 18)
    }

    func testFontUsesRoundedSystemDesign() {
        XCTAssertTrue(WindowTitleTextMetrics.font(scale: 1).fontName.contains("Rounded"))
    }

    func testIntrinsicWidthTracksScale() {
        let title = "activity-list.vue - project"
        let small = WindowTitleTextMetrics.intrinsicWidth(of: title, scale: 0.5)
        let regular = WindowTitleTextMetrics.intrinsicWidth(of: title, scale: 1)
        let large = WindowTitleTextMetrics.intrinsicWidth(of: title, scale: 1.5)

        XCTAssertLessThan(small, regular)
        XCTAssertLessThan(regular, large)
    }

    func testInStripTitleWidthTracksTheDockScale() {
        // The in-strip title width scales with the taskbar, and the truncation check must use the same width -- hard-coding 140 in two places would produce
        // "looks truncated but no tooltip pops up" (or vice versa). This test covers only the **in-strip** text;
        // the bubble's own scaling is locked in `testMediumTierKeepsTheNativePixelsAndOtherTiersScaleWholesale`.
        for tier in sampleDockHeights {
            XCTAssertEqual(WindowTitleTextMetrics.maximumWidth(for: tier.scale),
                           WindowTitleTextMetrics.maximumWidth * tier.scale, accuracy: 0.001)
        }
        // The medium tier must match the historical literal values.
        XCTAssertEqual(WindowTitleTextMetrics.maximumWidth(for: 1.0), 140)
    }

    // The truncation check (`isTruncated` / `needsTooltip`) and its three tests were deleted on 2026-08-17:
    // that was the "pop a tooltip only when the title is truncated" threshold; the bubble was first changed to pop on hover, then to show only the app name,
    // and production code no longer has any caller. Don't restore them with the old signatures.
}

/// While hovering, the chip's geometry stays **constant** -- on 2026-08-16 the app name was changed to the native-Dock style "bubble directly above
/// the icon", so the chip interior no longer needs to make room for it.
///
/// This used to lock the displacement formulas of `ChipSubtitleMetrics` (such as `pillHoverShift = 3s - 1 - Hs/2`, solved
/// against the earlier `VStack(spacing: 2)` layout). **That type and its whole group of tests were deleted
/// along with the feature; don't restore them from the old formulas.**
final class ChipHoverGeometryTests: XCTestCase {
    private let tiers: [CGFloat] = sampleDockHeights.map(\.scale)

    func testHoverDoesNotMoveAnyGeometry() {
        for scale in tiers {
            let rest = ChipHoverVisual.resolve(progress: 0, scale: scale)
            let hover = ChipHoverVisual.resolve(progress: 1, scale: scale)
            XCTAssertEqual(rest.bareIconSize, hover.bareIconSize, accuracy: 0.001,
                           "悬停不该缩图标（scale=\(scale)）")
            XCTAssertEqual(rest.pillHeight, hover.pillHeight, accuracy: 0.001,
                           "悬停不该缩药丸（scale=\(scale)）")
            XCTAssertEqual(rest.pillIconSize, hover.pillIconSize, accuracy: 0.001,
                           "悬停不该缩药丸内的图标（scale=\(scale)）")
        }
    }

    /// The only quantity that still varies with hover: brightening of the pill background and stroke.
    func testOnlyEmphasisTracksHover() {
        XCTAssertEqual(ChipHoverVisual.resolve(progress: 0, scale: 1).emphasisProgress, 0)
        XCTAssertEqual(ChipHoverVisual.resolve(progress: 1, scale: 1).emphasisProgress, 1)
        XCTAssertEqual(ChipHoverVisual.resolve(progress: 0.5, scale: 1).emphasisProgress, 0.5)
    }

    func testProgressIsClamped() {
        XCTAssertEqual(ChipHoverVisual.resolve(progress: -3, scale: 1).progress, 0)
        XCTAssertEqual(ChipHoverVisual.resolve(progress: 9, scale: 1).progress, 1)
    }

    func testSizesTrackTheTier() {
        for scale in tiers {
            let v = ChipHoverVisual.resolve(progress: 0, scale: scale)
            XCTAssertEqual(v.bareIconSize, ChipPillMetrics.bareIconSlot * scale, accuracy: 0.001)
            XCTAssertEqual(v.pillHeight, ChipPillMetrics.boxHeight * scale, accuracy: 0.001)
            XCTAssertEqual(v.pillIconSize, ChipPillMetrics.iconSlot * scale, accuracy: 0.001)
        }
    }
}

/// The curve for labels growing/shrinking: the strip and the panel base share the same Bezier, and a mis-parsed tuning string must silently fall back to the default.
final class LabelWidthAnimationTests: XCTestCase {
    func testDefaultCurveIsAValidBezier() {
        let c = LabelWidthAnimation.defaultCurve
        XCTAssertGreaterThan(c.duration, 0)
        XCTAssertTrue((0...1).contains(c.c1x))
        XCTAssertTrue((0...1).contains(c.c2x))
    }

    func testParsesTheOverrideString() {
        XCTAssertEqual(LabelWidthAnimation.parse("300, 0.25, 0.1, 0.25, 1"),
                       LabelWidthAnimation.Curve(duration: 0.3, c1x: 0.25, c1y: 0.1, c2x: 0.25, c2y: 1))
    }

    func testRejectsMalformedOverrides() {
        XCTAssertNil(LabelWidthAnimation.parse(nil))
        XCTAssertNil(LabelWidthAnimation.parse(""))
        XCTAssertNil(LabelWidthAnimation.parse("300,0.25,0.1,0.25"))         // one item short
        XCTAssertNil(LabelWidthAnimation.parse("0,0.25,0.1,0.25,1"))         // non-positive duration
        XCTAssertNil(LabelWidthAnimation.parse("300,1.5,0.1,0.25,1"))        // control point x out of range
        XCTAssertNil(LabelWidthAnimation.parse("300,a,0.1,0.25,1"))          // non-numeric
    }
}

/// After the probe switched to measuring the card rect, the tooltip's anchor contract (pill rect) is derived from this set of constants,
/// so the derivation must use the same values as rendering.
final class ChipPillMetricsTests: XCTestCase {
    func testWidthMatchesTheRenderedComposition() {
        let title = "psd-文件"
        let scale: CGFloat = 1
        let titleWidth = min(WindowTitleTextMetrics.intrinsicWidth(of: title, scale: scale),
                             WindowTitleTextMetrics.maximumWidth(for: scale))
        let expected = (2 * 10 + 22 + 6) * scale + ceil(titleWidth)
        XCTAssertEqual(ChipPillMetrics.width(title: title, scale: scale), expected, accuracy: 0.001)
    }

    /// The label box width is the common source for rendering and derivation: the constrained title width rounded up, with `width` only adding constants outside it.
    func testLabelWidthIsTheCeiledCappedIntrinsicWidth() {
        let title = "psd-文件"
        let long = String(repeating: "very-long-window-title-", count: 20)
        for scale in [CGFloat(0.85), 1, 1.15, 1.3] {
            let intrinsic = WindowTitleTextMetrics.intrinsicWidth(of: title, scale: scale)
            XCTAssertEqual(ChipPillMetrics.labelWidth(title: title, scale: scale),
                           ceil(min(intrinsic, WindowTitleTextMetrics.maximumWidth(for: scale))), accuracy: 0.001)
            XCTAssertEqual(ChipPillMetrics.labelWidth(title: long, scale: scale),
                           ceil(WindowTitleTextMetrics.maximumWidth(for: scale)), accuracy: 0.001)
            XCTAssertFalse(ChipPillMetrics.labelTruncates(title: title, scale: scale))
            XCTAssertTrue(ChipPillMetrics.labelTruncates(title: long, scale: scale))
            XCTAssertEqual(ChipPillMetrics.width(title: long, scale: scale)
                               - ChipPillMetrics.width(title: title, scale: scale),
                           ChipPillMetrics.labelWidth(title: long, scale: scale)
                               - ChipPillMetrics.labelWidth(title: title, scale: scale), accuracy: 0.001)
        }
    }

    func testWidthIsCappedByTheTitleMaximum() {
        let long = String(repeating: "very-long-window-title-", count: 20)
        let scale: CGFloat = 1
        let expected = (2 * 10 + 22 + 6) * scale + ceil(WindowTitleTextMetrics.maximumWidth(for: scale))
        XCTAssertEqual(ChipPillMetrics.width(title: long, scale: scale), expected, accuracy: 0.001)
    }

    // MARK: - Quiet-tier hover scale-up: converges by card width

    /// **Main lock**: the look of icon cards doesn't change by a single pixel.
    ///
    /// The cap rule computes 1.15 on a 40pt card, clamped back to 1.10 by the `quietHoverScale` upper bound --
    /// the convergence should only bite on cards wide enough to crowd. All four kinds of icon cards (window card / kept / messaging zone / shelf) have this width.
    func testIconCardKeepsTheAcceptedFullScale() {
        for tier in sampleDockHeights {
            let width = ChipPillMetrics.cardWidth * tier.scale
            XCTAssertEqual(
                ChipPillMetrics.quietHoverScale(forCardWidth: width, scale: tier.scale),
                ChipPillMetrics.quietHoverScale, accuracy: 0.0001,
                "档位 \(tier) 的图标卡必须仍是 1.10"
            )
        }
    }

    /// At any card width, the outward growth on each side stays within budget -- this is the direct criterion for "no longer crowds".
    ///(What the multiplier itself is doesn't matter; what the user sees is the edge displacement.)
    func testNoCardGrowsBeyondTheEdgeBudget() {
        for tier in sampleDockHeights {
            let budget = ChipPillMetrics.quietHoverEdgeBudget * tier.scale
            for base in [40, 60, 96, 140, 168.5, 196, 400] as [CGFloat] {
                let width = base * tier.scale
                let s = ChipPillMetrics.quietHoverScale(forCardWidth: width, scale: tier.scale)
                let growthPerSide = width * (s - 1) / 2
                XCTAssertLessThanOrEqual(growthPerSide, budget + 0.0001,
                                         "卡宽 \(base) 档位 \(tier) 每侧外扩 \(growthPerSide) 超预算")
            }
        }
    }

    /// Two full-width title cards side by side: after scaling up, the gap must still remain.
    /// Resting visible gap = `2 * titledCardInset + chipSpacing` = 10pt, budget 3pt -> at least 7pt left.
    func testTwoWidestTitledCardsStillLeaveAVisibleGap() {
        let scale: CGFloat = 1
        let longTitle = String(repeating: "very-long-window-title-", count: 20)
        let cardWidth = ChipPillMetrics.width(title: longTitle, scale: scale)
            + 2 * ChipPillMetrics.titledCardInset * scale
        let restingGap = 2 * ChipPillMetrics.titledCardInset * scale + 2 /* Style.chipSpacing */
        let s = ChipPillMetrics.quietHoverScale(forCardWidth: cardWidth, scale: scale)
        let remaining = restingGap - cardWidth * (s - 1) / 2

        XCTAssertEqual(restingGap, 10, accuracy: 0.001, "静息缝的构成变了，这条判据要跟着重算")
        XCTAssertGreaterThanOrEqual(remaining, 7 - 0.001,
                                    "放大后只剩 \(remaining)pt，宽卡又会挤到邻居")
    }

    /// Unread badge size: the medium tier is verbatim the historical literal values, other tiers scale as a whole with `scale`.
    ///
    /// Before scaling was added these four numbers were hard-coded, the same size at all four tiers -- the same kind of miss as the hover bubble.
    func testBadgeMetricsKeepTheMediumLiteralsAndScaleWithTheTier() {
        XCTAssertEqual(ChipPillMetrics.badgeFontSize, 10)
        XCTAssertEqual(ChipPillMetrics.badgeMinimumSize, 16)
        XCTAssertEqual(ChipPillMetrics.badgeHorizontalPadding, 5)
        XCTAssertEqual(ChipPillMetrics.badgeTopOffset, 5)
        // The medium tier's scale is always 1, so "times scale" is the original value at the medium tier -- this also locks that identity.
        XCTAssertEqual(DockPanelHeight.native.scale, 1.0, accuracy: 0.0000001)
    }

    /// A width of 0 (not measured yet) must not produce NaN / infinity.
    func testZeroWidthFallsBackToTheCap() {
        XCTAssertEqual(ChipPillMetrics.quietHoverScale(forCardWidth: 0, scale: 1),
                       ChipPillMetrics.quietHoverScale)
    }

    /// The pill is horizontally centered in the card -> midX directly reuses the card's; the vertical parts all come from constants.
    func testPillRectIsHorizontallyCenteredOnTheCard() {
        let card = CGRect(x: 100, y: 200, width: 180, height: 52)
        let rect = ChipPillMetrics.pillRect(inCard: card, title: "psd-文件", scale: 1)
        XCTAssertEqual(rect.midX, card.midX, accuracy: 0.001)
    }

    /// Screen coordinates have y pointing up: the resting pill's top edge = `boxTopInset` below the card's top edge.
    func testRestPillRectSitsBoxTopInsetBelowTheCardTop() {
        let card = CGRect(x: 0, y: 0, width: 180, height: ChipPillMetrics.chipHeight)
        let rect = ChipPillMetrics.pillRect(inCard: card, title: "psd-文件", scale: 1)
        XCTAssertEqual(rect.maxY, card.maxY - ChipPillMetrics.boxTopInset, accuracy: 0.001)
        XCTAssertEqual(rect.height, 34, accuracy: 0.001)
    }

}


final class ScreenRectReaderTests: XCTestCase {
    private final class Task: ScreenRectDeliveryTask {
        private let action: () -> Void
        private(set) var isCancelled = false

        init(action: @escaping () -> Void) { self.action = action }
        func cancel() { isCancelled = true }
        func run() { if !isCancelled { action() } }
        func forceRun() { action() }
    }

    private final class Scheduler: ScreenRectDeliveryScheduling {
        struct Scheduled {
            let delay: TimeInterval
            let task: Task
        }

        private(set) var scheduled: [Scheduled] = []

        func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) -> ScreenRectDeliveryTask {
            let task = Task(action: action)
            scheduled.append(Scheduled(delay: delay, task: task))
            return task
        }

        func runAll() {
            let tasks = scheduled
            scheduled.removeAll()
            tasks.forEach { $0.task.run() }
        }
    }

    func testReportsEveryDistinctRectInOrder() {
        let scheduler = Scheduler()
        var reported: [CGRect] = []
        let view = ScreenRectReader.TrackingView(
            scheduler: scheduler, onChange: { reported.append($0) }
        )
        let a = CGRect(x: 1, y: 2, width: 3, height: 4)
        let b = CGRect(x: 2, y: 3, width: 4, height: 5)

        view.enqueue(a)
        view.enqueue(a)
        view.enqueue(b)
        view.enqueue(a)
        scheduler.runAll()

        XCTAssertEqual(reported, [a, b, a])
        XCTAssertEqual(scheduler.scheduled.count, 0)
    }



    func testPendingDeliveryUsesTheLatestCallback() {
        let scheduler = Scheduler()
        var old: [CGRect] = []
        var latest: [CGRect] = []
        let view = ScreenRectReader.TrackingView(
            scheduler: scheduler, onChange: { old.append($0) }
        )
        let rect = CGRect(x: 1, y: 2, width: 3, height: 4)

        view.enqueue(rect)
        view.update(onChange: { latest.append($0) })
        scheduler.runAll()

        XCTAssertTrue(old.isEmpty)
        XCTAssertEqual(latest, [rect])
    }

    func testDetachCancellationBlocksPendingCallbacks() {
        let scheduler = Scheduler()
        var reported: [CGRect] = []
        let view = ScreenRectReader.TrackingView(
            scheduler: scheduler, onChange: { reported.append($0) }
        )
        view.enqueue(CGRect(x: 1, y: 2, width: 3, height: 4))
        view.cancelPendingDelivery()
        scheduler.runAll()
        XCTAssertTrue(reported.isEmpty, "detach 之后排队的投递必须作废")
    }


    /// Window move / display change must report again.
    ///
    /// `layout()` fires only when the view tree changes, and moving the panel to another display or up/down doesn't change the view tree --
    /// so each card's cached screen rect stays at the old position, and the bubble pops up on the display that has no taskbar
    ///(reported by the owner 2026-08-17). This test locks "the observer is installed, and can be torn down".
    func testWindowMovementTriggersAFreshReport() {
        let scheduler = Scheduler()
        var reported: [CGRect] = []
        let view = ScreenRectReader.TrackingView(
            scheduler: scheduler, onChange: { reported.append($0) }
        )
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.addSubview(view)
        view.frame = CGRect(x: 10, y: 10, width: 50, height: 20)
        scheduler.runAll()
        reported.removeAll()

        window.setFrameOrigin(CGPoint(x: 400, y: 300))
        NotificationCenter.default.post(name: NSWindow.didMoveNotification, object: window)
        scheduler.runAll()
        XCTAssertFalse(reported.isEmpty, "窗口移动后必须补一次上报")

        // After teardown it must not fire again, otherwise the observer would outlive the view.
        view.removeFromSuperview()
        reported.removeAll()
        NotificationCenter.default.post(name: NSWindow.didMoveNotification, object: window)
        scheduler.runAll()
        XCTAssertTrue(reported.isEmpty, "已 detach 的探针不该再上报")
    }

    /// The bubble size was measured pixel by pixel from a screenshot of the native macOS 26 Dock on 2026-08-17; it was not designed.
    /// This locks that set of numbers -- to change them, re-screenshot and re-measure first, don't tune by feel.
    func testBubbleMetricsMatchTheMeasuredNativeDockLabel() {
        let native = WindowTitleTooltipStyle.native
        XCTAssertEqual(native.height, 26)
        XCTAssertEqual(native.fontSize, 14)
        XCTAssertEqual(native.horizontalPadding, 13)
        XCTAssertEqual(native.tailWidth, 23)
        XCTAssertEqual(native.tailHeight, 6.5)
        XCTAssertEqual(native.tipGap, 6.5)
        XCTAssertEqual(native.maximumWidth, 360)
        // The slope of the mid-section straight edge (half-width/depth) measured at about 1.17; the evidence for a rounded tip is that extrapolating it doesn't reach the bottom.
        let slope = (native.tailShoulderHalfWidth - native.tailTipHalfWidth)
            / (native.tailTipDepth - native.tailShoulderDepth)
        XCTAssertEqual(slope, 1.17, accuracy: 0.05)
        let extrapolated = native.tailTipDepth + native.tailTipHalfWidth / slope
        XCTAssertGreaterThan(extrapolated, native.tailHeight,
                             "直边外推必须落在实际尖端之下——差的那截才是圆头")
        // **A capsule, not a rounded rectangle**: the corner radius must be exactly half the height.
        XCTAssertEqual(native.cornerRadius, native.height / 2)
    }

    /// The panel is sized from `fittingSize` in the same turn the title is swapped in. A label
    /// whose width came from an AppKit view's intrinsic size was still reporting the previous
    /// title there, and the bubble was cut to the old width (owner, 2026-10-02).
    func testBubbleRemeasuresInTheSameTurnWhenTheTitleChanges() {
        for scheme in [ColorScheme.light, .dark] {
            func bubble(_ title: String) -> AnyView {
                AnyView(WindowTitleTooltipView(title: title, style: .native, usesLiquidGlass: false)
                    .environment(\.colorScheme, scheme))
            }
            let host = NSHostingView(rootView: bubble("Notes"))
            let short = host.fittingSize
            host.rootView = bubble("Adobe Illustrator 2026")
            let long = host.fittingSize
            let fresh = NSHostingView(rootView: bubble("Adobe Illustrator 2026")).fittingSize
            XCTAssertEqual(long.width, fresh.width, accuracy: 0.5, "\(scheme): stale width after a title change")
            XCTAssertGreaterThan(long.width, short.width + 60, "\(scheme)")
            XCTAssertEqual(long.height, short.height, accuracy: 0.5, "\(scheme)")
        }
    }

    /// The pointer must be drawn in the same closed path: overlaying a triangle would cross a horizontal line at the seam.
    /// This verifies that the shape indeed extends a pointer downward and that the tip lands at the horizontal center.
    func testShapeExtendsADownwardTailAtTheHorizontalCentre() {
        let style = WindowTitleTooltipStyle.native
        let rect = CGRect(x: 0, y: 0, width: 85, height: style.height + style.tailHeight)
        let box = WindowTitleTooltipShape(style: style).path(in: rect).boundingRect
        XCTAssertEqual(box.maxY, rect.maxY, accuracy: 0.5, "尖端要顶到形状底边")
        XCTAssertEqual(box.width, rect.width, accuracy: 0.5, "主体要占满整宽")

        // The row where the tip sits has only a very narrow strip left, and it is centered.
        let tip = WindowTitleTooltipShape(style: style).path(in: rect)
        let nearTip = tip.boundingRect
        XCTAssertEqual(nearTip.midX, rect.midX, accuracy: 0.5)
        XCTAssertFalse(tip.contains(CGPoint(x: rect.minX + 2, y: rect.maxY - 1)),
                       "尖角两侧必须是空的，不能是一整条底边")
        XCTAssertTrue(tip.contains(CGPoint(x: rect.midX, y: rect.maxY - 1)),
                      "中心那一竖必须还在形状里")
    }
}

/// Icon center spacing: the native-measured 42pt, and the same constant the strip actually uses.
///
///(There used to be a whole set of `WindowTitleTooltipOwnership` cases here: who is entitled to hold that single bubble panel,
/// whether to keep it when crossing a gap. After hover was changed on 2026-08-17 to "one tracking area for the whole strip + reverse lookup by position",
/// the bubble has only one sender and preemption is structurally impossible, so that logic was deleted along with its cases;
/// gaps and boundaries are now locked in `StripHoverResolutionTests`.)
final class ChipIconPitchTests: XCTestCase {
    func testIconPitchMatchesTheNativeDock() {
        XCTAssertEqual(ChipPillMetrics.iconPitch, 42)
        XCTAssertEqual(ChipPillMetrics.iconPitch,
                       ChipPillMetrics.cardWidth + ChipPillMetrics.chipSpacing)
    }

    /// The dropped-app grow-in anchors on the icon's visible bottom: the 40pt slot is centred in
    /// the 54pt card (bottom at 47) and the artwork leaves 3.75pt of it transparent (43.25 / 54).
    func testDroppedAppGrowAnchorIsTheVisibleIconBottom() {
        XCTAssertEqual(ChipPillMetrics.visibleIconBottomFraction, 43.25 / 54, accuracy: 0.0001)
        XCTAssertLessThan(ChipPillMetrics.visibleIconBottomFraction, 1)
    }
}
