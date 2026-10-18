import AppKit
import os
import SwiftUI

/// Metrics for the **window title line inside the pill** on the strip. It only serves the pill's
/// layout: how wide it is and how wide it can get at most.
///
/// On 2026-08-17 we removed `isTruncated` / `needsTooltip` / `truncationTolerance`. They were the
/// threshold for "show a tooltip only when the title is truncated", but the bubble was first changed
/// to "show on hover" and later to "show only the app name", so truncation no longer affects any
/// behavior and no production caller is left. To find the full window title, look at `.help(fullTitle)`
/// on both branches of `ChipView` (the system tooltip fallback).
///
/// Correction on 2026-09-04: before that, this said `.help(displayTitle)` and only `bareIconChip`
/// actually attached it, so a titled card that got truncated showed its full title nowhere (issue #41).
/// Now both branches attach it, and it carries the full title **without the app-name suffix stripped**.
enum WindowTitleTextMetrics {
    /// Maximum width of the in-strip title (default tier baseline). After the strip is scaled, always
    /// go through `maximumWidth(for:)`; don't write a second literal at the call site. Having the two
    /// sides each go their own way once made the pill and the hit test disagree.
    static let maximumWidth: CGFloat = 140

    static func maximumWidth(for scale: CGFloat) -> CGFloat { maximumWidth * scale }

    static func font(scale: CGFloat) -> NSFont {
        let size = max(10, 12 * scale)
        let base = NSFont.systemFont(ofSize: size, weight: .medium)
        guard let descriptor = base.fontDescriptor.withDesign(.rounded),
              let rounded = NSFont(descriptor: descriptor, size: size) else {
            return base
        }
        return rounded
    }

    static func intrinsicWidth(of title: String, scale: CGFloat) -> CGFloat {
        (title as NSString).size(withAttributes: [.font: font(scale: scale)]).width
    }

}

/// The curve for when a label gets longer or shorter. It only drives the in-strip
/// `LabelBoxWidthDriver`; the panel backplate does not run its own animation. Instead, during the
/// follow window of `PanelCoordinator.beginLabelWidthFollow` it measures the content width every
/// frame and sets the frame directly (sync is guaranteed by construction).
///
/// Default: gentle start, long finish (the owner asked for "soft" on 2026-09-12).
/// `DOCK_LABEL_ANIM="ms,c1x,c1y,c2x,c2y"` lets you try other sets without reinstalling; it is read
/// once at process launch. Once one is chosen, change `defaultCurve`. The follow window's duration
/// follows `curve.duration`.
enum LabelWidthAnimation {
    struct Curve: Equatable {
        let duration: TimeInterval
        let c1x: Double, c1y: Double, c2x: Double, c2y: Double
    }

    static let defaultCurve = Curve(duration: 0.60, c1x: 0.5, c1y: 0, c2x: 0.15, c2y: 1)   // owner 2026-09-13: slow start, long overall
    static let curve: Curve = parse(DebugSwitch.labelAnim.value()) ?? defaultCurve

    static var swiftUI: Animation {
        .timingCurve(curve.c1x, curve.c1y, curve.c2x, curve.c2y, duration: curve.duration)
    }


    /// "ms,c1x,c1y,c2x,c2y" → curve; wrong format, non-positive duration, or control-point x out of range (Bezier requires 0…1) → nil, use the default.
    static func parse(_ raw: String?) -> Curve? {
        guard let raw else { return nil }
        let parts = raw.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 5, let ms = parts[0], let c1x = parts[1], let c1y = parts[2],
              let c2x = parts[3], let c2y = parts[4], ms > 0,
              (0...1).contains(c1x), (0...1).contains(c2x) else { return nil }
        return Curve(duration: ms / 1000, c1x: c1x, c1y: c1y, c2x: c2x, c2y: c2y)
    }
}

/// Layout constants for the titled window card's "pill". **Rendering and derivation must share
/// them.** The tooltip's anchor contract is the pill rect (see
/// `PanelGeometry.windowTitleTooltipTargetFrame`), while the screen-coordinate probe measures the
/// whole card's rect to avoid the press-scale; the pill rect can only be derived from these
/// constants. Writing a copy in each place would sooner or later drift apart, for the same reason
/// as `WindowTitleTextMetrics`.
enum ChipPillMetrics {
    /// Total card height (= panel content height, baseline of `DockPanelHeight.native`).
    /// **Must equal `DockPanelHeight.native.points`**: the card fills the strip height with no gap above
    /// or below, and the hit test for right-clicking the empty area of the strip is built on "no
    /// vertical gap". Changed on 2026-08-16 together with the default tier 52→54.
    static let chipHeight: CGFloat = 54
    /// Layout box height of the pill. **No longer changes on hover** (2026-08-16: the app name moved
    /// into the bubble above the icon, so the pill no longer needs to make room).
    static let boxHeight: CGFloat = 34
    static let horizontalPadding: CGFloat = 10
    /// Extra room left on both sides of the pill for a titled window card.
    ///
    /// Icon cards get a visible gap from the transparent margin built into the icon asset. The pill has
    /// a solid background and cannot produce that itself, so after `Style.chipSpacing` was reduced from
    /// 8 to 2 (matching native icon spacing), two titled cards ended up touching (owner, 2026-08-16:
    /// "make the gap between multi-window labels larger").
    /// The visible gap between two titled cards = `2 * titledCardInset + Style.chipSpacing` = 10pt,
    /// which matches the visible gap between icons (measured 10pt).
    ///
    /// It is added on the **whole card** rather than inside the pill: the pill size is an approved look,
    /// and `pillRect(inCard:)` derives the tooltip anchor by assuming "the pill is horizontally centered
    /// in the card"; symmetric insets don't affect that contract.
    static let titledCardInset: CGFloat = 4
    /// The icon's **layout** slot (the visual size 22→18 only shrinks inside the slot; the slot stays, so the width doesn't change on hover).
    static let iconSlot: CGFloat = 22
    static let iconSpacing: CGFloat = 6

    /// Icon size for an untitled (icon-only) card: at rest = the native Dock's tilesize; on hover it
    /// shrinks to make room for the app name.
    ///
    /// **`bareIconSlot` is also the height of the layout slot.** The `ZStack` in `ChipView` is
    /// `.top`-aligned, so a slot smaller than the resting icon makes the whole icon overflow downward
    /// (2026-08-16: the icon went from 36 to 40 while the slot stayed hardcoded at 36; measured, the icon
    /// sat 4pt lower in the card and the top/bottom whitespace became 12.5 / 8.0). The two must be the
    /// same constant.
    static let bareIconSlot: CGFloat = 40
    /// How large the **square actually drawn** inside the icon slot is.
    ///
    /// Apple's icon assets carry about 18% transparent margin (measured 2026-08-16: in a 40pt slot the
    /// visible square is 32.5pt); that is where the visible gap between icons on the strip comes from.
    /// So **any graphic we draw ourselves without a transparent margin** (the one in the transit cell)
    /// must be drawn at this size, otherwise it looks noticeably larger than its neighbors. Half of the
    /// owner's "too abrupt" complaint was about size, not just color.
    static let bareIconVisibleSlot: CGFloat = 32.5

    /// The running dot under an icon card, at the native 54pt bar; every strip site multiplies by
    /// `scale` (size-tiers rule), so dot, bar and gap keep their proportion to the icon. The same
    /// capsule stretches to `frontWindowBarWidth` on the card whose window is in front
    /// (`FrontWindowIndicatorDecision`); titled cards draw no resting dot and grow the bar from
    /// nothing. The bar is thinner than the dot and shares its bottom edge. The drawer's stack
    /// cells do not scale and keep their own literals.
    static let runningDotSize: CGFloat = 4
    static let runningDotBottomPadding: CGFloat = 4
    static let frontWindowBarWidth: CGFloat = 12
    static let frontWindowBarHeight: CGFloat = 3
    static let frontWindowBarAnimation: TimeInterval = 0.18

    /// Where an icon card's visible artwork ends, as a fraction of the card's height — the anchor
    /// an app dropped in from Finder grows from (the native Dock grows it up from the icon's
    /// bottom). Not the card's bottom: the icon slot is centred in the taller card and the artwork
    /// carries its own transparent margin, so the card's edge sits ~10pt lower and the icon would
    /// drift upward as it grows. Every term scales with the tier, so the ratio does not.
    static var visibleIconBottomFraction: CGFloat {
        let slotBottom = (chipHeight + bareIconSlot) / 2
        let artworkMargin = (bareIconSlot - bareIconVisibleSlot) / 2
        return (slotBottom - artworkMargin) / chipHeight
    }

    /// **Upper bound** on the whole-card hover scale in quiet mode (see `View.chipQuietHoverScale`).
    ///
    /// 1.10 does not make the visible pixels of adjacent icons collide: the card is 40 wide and the
    /// icon's visible square is only 32.5, so scaling to 35.75 still fits inside the card, leaving a bit
    /// over 2pt of transparent margin on each side.
    ///
    /// **Note this argument only covers icon cards**; see `quietHoverScale(forCardWidth:scale:)` below.
    static let quietHoverScale: CGFloat = 1.10

    /// The most a card grows outward on each side on hover (unscaled, multiplied by `scale` per tier).
    ///
    /// The visible gap between two titled cards is `2 * titledCardInset + Style.chipSpacing` = 10pt;
    /// with a 3pt budget the worst case still leaves 7pt.
    static let quietHoverEdgeBudget: CGFloat = 3

    /// Scale factor, clamped by card width.
    ///
    /// **The absolute displacement of a proportional scale follows the card width, so "the same 1.10"
    /// was never "the same amount of feedback".** The owner reported on 2026-08-17 that "a very wide tab
    /// crowds its neighbor when it scales up"; measured on his screenshot: a 40pt-wide icon card grows
    /// 2.0pt per side, while that 168.5pt-wide titled card grows **8.4pt** per side (4x), eating the 10pt
    /// gap down to 3.5pt. The `quietHoverScale` argument above never considered titled cards at all.
    ///
    /// The fix is to cap the **outward growth per side**, rather than branching by card type:
    /// an icon card computes to 1.15 and is clamped back to 1.10 (**not one pixel changes**); only cards
    /// wide enough to crowd get reined in. One rule covers all four kinds of card, and a new kind added
    /// later won't miss a branch.
    ///
    /// The ratio is independent of the tier (the budget and card width are both multiplied by `scale`);
    /// it is written out explicitly because the caller passes an already-scaled card width.
    static func quietHoverScale(forCardWidth width: CGFloat, scale: CGFloat) -> CGFloat {
        guard width > 0 else { return quietHoverScale }
        return min(quietHoverScale, 1 + 2 * quietHoverEdgeBudget * scale / width)
    }
    /// Card width of an icon-only card. **Center spacing = `cardWidth + Style.chipSpacing`; look at the
    /// two together.** Measured on 2026-08-16, the native Dock's icon center spacing is 42pt (a 40 tile
    /// + 2pt gap), whereas NeoBar used to be 52pt (44 + 8), twice as sparse; changed to 40 + 2 to match.
    /// The card width equals the icon size, so the icon has no extra horizontal slack. The native Dock
    /// is the same: the visible gap comes from the transparent margin built into the icon asset.
    static let cardWidth: CGFloat = 40

    /// Spacing between cards. **Defined here, and `Style.chipSpacing` references it.** The hover
    /// attribution logic (the gap-bridging amount in `StripHoverResolution`) needs it too, and `Style`
    /// is private so other files can't read it; two copies of a 2 would sooner or later drift apart.
    ///
    /// 2pt: matches the native Dock's icon center spacing of 42pt. **Changing it requires changing
    /// `StripContextMenuZone.defaultMinimumGapWidth` in sync**: that threshold must fall strictly
    /// between an "ordinary gap" and a "divider gap", otherwise right-click on the strip's empty area
    /// breaks entirely.
    static let chipSpacing: CGFloat = 2

    /// Center spacing of icon cards (measured 42pt natively). Currently only tests read it: it locks the
    /// identity "card width + spacing = native 42", and blows up immediately if the width or spacing changes.
    static let iconPitch: CGFloat = cardWidth + chipSpacing

    // MARK: Unread badge (`ChipBadgeView`)
    //
    // The default tier = the literals in the group below, character-for-character the same as before
    // 2026-08-17; the other tiers multiply everything by `scale`.
    // Before that, these numbers were hardcoded and **identical across all four tiers**: the red dot
    // was too small on a 70pt strip and too large on a 46pt one.
    // The same kind of slip-through as the hover bubble (AGENTS "Taskbar Size Tiers": every render path
    // in the strip must honor `scale`).
    static let badgeFontSize: CGFloat = 10
    /// Minimum size of the badge capsule (that is what a single digit gets).
    static let badgeMinimumSize: CGFloat = 16
    static let badgeHorizontalPadding: CGFloat = 5
    /// How far down from the card's top-right corner to push: most of a native badge overlaps the icon, poking out only slightly past the rounded corner.
    static let badgeTopOffset: CGFloat = 5
    /// Scale of the badge on a titled window card (relative to the icon card's badge). The icon slot in
    /// the pill is only 22pt, and a full-size 16pt badge would cover most of the icon; 0.8 → 12.8pt, and
    /// the 8pt font is still readable.
    static let titledCardBadgeScale: CGFloat = 0.8

    /// Distance from the pill box's top edge to the card's top edge: two `Spacer`s split `chipHeight - boxHeight` evenly.
    static let boxTopInset: CGFloat = (chipHeight - boxHeight) / 2

    static func height(scale: CGFloat) -> CGFloat { boxHeight * scale }

    /// Width of the label box: the title's actual rendered width (bounded by the `WindowTitleTextMetrics`
    /// cap), rounded up.
    ///
    /// `ChipView.multiWindowChip` uses it to give the label an **explicit** width instead of letting
    /// `Text` size itself: when the label grows or shrinks, this width interpolates with the strip's
    /// layout animation, and the text itself is swapped by identity rather than re-flowing at
    /// intermediate widths. For that reason, the rendered pill width also matches `width(title:scale:)`
    /// below to the point.
    static func labelWidth(title: String, scale: CGFloat) -> CGFloat {
        ceil(min(
            WindowTitleTextMetrics.intrinsicWidth(of: title, scale: scale),
            WindowTitleTextMetrics.maximumWidth(for: scale)
        ))
    }

    /// Whether the title exceeds the cap and needs truncation. If so, `Text` gets the cap width and adds
    /// the ellipsis itself; if not, `Text` is drawn at its natural width (it is not given a fixed
    /// width: SwiftUI may measure the text a fraction of a pt wider than AppKit, and a fixed width would
    /// swallow the last character into an ellipsis).
    static func labelTruncates(title: String, scale: CGFloat) -> Bool {
        WindowTitleTextMetrics.intrinsicWidth(of: title, scale: scale)
            > WindowTitleTextMetrics.maximumWidth(for: scale)
    }

    /// Pill width = horizontal padding + icon slot + spacing + label box width.
    static func width(title: String, scale: CGFloat) -> CGFloat {
        (2 * horizontalPadding + iconSlot + iconSpacing) * scale + labelWidth(title: title, scale: scale)
    }

    /// Derives the pill's screen rect from the stable card screen rect (macOS screen coordinates have y pointing up).
    /// The pill is horizontally centered in the card, so `midX` simply reuses the card's; the vertical
    /// part all comes from the constants above.
    static func pillRect(
        inCard card: CGRect,
        title: String,
        scale: CGFloat
    ) -> CGRect {
        let pillHeight = height(scale: scale)
        let topY = card.maxY - boxTopInset * scale
        let pillWidth = width(title: title, scale: scale)
        return CGRect(
            x: card.midX - pillWidth / 2,
            y: topY - pillHeight,
            width: pillWidth,
            height: pillHeight
        )
    }
}


/// Visuals of the chip on hover. **Geometry stays constant; only the "I'm over this" brightening follows the progress.**
///
/// Before 2026-08-16 this also interpolated three things: bare icon 40→26, pill box 34→28, icon in
/// the pill 22→18, plus a line of app name growing from zero width. **The only reason for that
/// shrinking was to make room for the name line below the icon.** Once the name became the native
/// Dock-style "bubble right above the icon" (owner, 2026-08-16), the reason was gone: natively the
/// icon neither shrinks nor moves on hover. Keeping it would only make the whole strip jitter as the
/// mouse sweeps across.
///
/// Also retired is the displacement formula (`pillHoverShift` / `subtitleShift`) that `ChipSubtitleMetrics`
/// got by solving equations against the old `VStack(spacing: 2)` layout. **Do not bring them back.**
struct ChipHoverVisual: Equatable {
    let progress: CGFloat
    let bareIconSize: CGFloat
    let pillHeight: CGFloat
    let pillIconSize: CGFloat
    /// How strongly the pill's base and stroke are emphasized. This is the **only** quantity that still varies with hover.
    let emphasisProgress: Double

    static func resolve(progress rawProgress: CGFloat, scale: CGFloat) -> ChipHoverVisual {
        let progress = min(max(rawProgress, 0), 1)
        return ChipHoverVisual(
            progress: progress,
            bareIconSize: ChipPillMetrics.bareIconSlot * scale,
            pillHeight: ChipPillMetrics.boxHeight * scale,
            pillIconSize: ChipPillMetrics.iconSlot * scale,
            emphasisProgress: Double(progress)
        )
    }
}

struct ChipHoverProgress<Content: View>: View, Animatable {
    var progress: CGFloat
    let content: (CGFloat) -> Content

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    init(progress: CGFloat, @ViewBuilder content: @escaping (CGFloat) -> Content) {
        self.progress = progress
        self.content = content
    }

    var body: some View {
        content(min(max(progress, 0), 1))
    }
}

enum ChipAnimationTrace {
    private static let enabled = DebugSwitch.chipAnimTrace.isEnabled(in: ProcessInfo.processInfo.environment)
    private static let runtime = Runtime()
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.neobar.NeoBar",
        category: "ChipAnimation"
    )

    static func record(
        chipID: String,
        kind: String,
        visual: ChipHoverVisual,
        isTapPressed: Bool,
        showsHover: Bool
    ) {
        guard enabled else { return }
        runtime.record(
            chipID: chipID,
            kind: kind,
            uptime: ProcessInfo.processInfo.systemUptime,
            visual: visual,
            state: ChipAnimationTraceState(isTapPressed: isTapPressed, showsHover: showsHover)
        )
    }

    static func event(
        chipID: String,
        kind: String,
        event: String,
        isTapPressed: Bool,
        showsHover: Bool
    ) {
        guard enabled else { return }
        runtime.event(
            chipID: chipID,
            kind: kind,
            uptime: ProcessInfo.processInfo.systemUptime,
            event: event,
            state: ChipAnimationTraceState(isTapPressed: isTapPressed, showsHover: showsHover)
        )
    }

    private final class Runtime: @unchecked Sendable {
        private let queue = DispatchQueue(label: "app.neobar.NeoBar.chip-animation-trace")
        private let fileManager = FileManager.default
        private var buffer = ChipAnimationTraceBuffer(capacity: 4_096)
        private var sessionByChip: [String: UUID] = [:]
        private var lastVisualByChip: [String: ChipHoverVisual] = [:]
        private var quiescenceGeneration: UInt64 = 0

        func record(
            chipID: String,
            kind: String,
            uptime: TimeInterval,
            visual: ChipHoverVisual,
            state: ChipAnimationTraceState
        ) {
            queue.async { [self] in
                let key = "\(kind)\u{0}\(chipID)"
                let isNewSession = sessionByChip[key] == nil
                let sessionID = sessionByChip[key] ?? UUID()
                sessionByChip[key] = sessionID
                lastVisualByChip[key] = visual
                appendSample(
                    sessionID: sessionID,
                    chipID: chipID,
                    kind: kind,
                    uptime: uptime,
                    visual: visual,
                    state: state,
                    event: isNewSession ? "sessionStart" : nil
                )
                scheduleExportAfterQuiescence()
            }
        }

        func event(
            chipID: String,
            kind: String,
            uptime: TimeInterval,
            event: String,
            state: ChipAnimationTraceState
        ) {
            queue.async { [self] in
                let key = "\(kind)\u{0}\(chipID)"
                let sessionID = sessionByChip[key] ?? UUID()
                sessionByChip[key] = sessionID
                appendSample(
                    sessionID: sessionID,
                    chipID: chipID,
                    kind: kind,
                    uptime: uptime,
                    visual: lastVisualByChip[key],
                    state: state,
                    event: event
                )
                scheduleExportAfterQuiescence()
            }
        }

        private func appendSample(
            sessionID: UUID,
            chipID: String,
            kind: String,
            uptime: TimeInterval,
            visual: ChipHoverVisual?,
            state: ChipAnimationTraceState,
            event: String?
        ) {
            buffer.append(ChipAnimationTraceSample(
                sessionID: sessionID,
                chipID: chipID,
                kind: kind,
                uptime: uptime,
                hoverProgress: visual.map { Double($0.progress) },
                bareIconSize: visual.map { Double($0.bareIconSize) },
                pillHeight: visual.map { Double($0.pillHeight) },
                pillIconSize: visual.map { Double($0.pillIconSize) },
                emphasisProgress: visual?.emphasisProgress,
                isTapPressed: state.isTapPressed,
                showsHover: state.showsHover,
                event: event
            ))
        }

        private func scheduleExportAfterQuiescence() {
            quiescenceGeneration &+= 1
            let generation = quiescenceGeneration
            queue.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self, self.quiescenceGeneration == generation else { return }
                self.exportBufferedSamples()
            }
        }

        private func exportBufferedSamples() {
            let samples = buffer.drain()
            guard !samples.isEmpty else { return }
            sessionByChip.removeAll(keepingCapacity: true)
            lastVisualByChip.removeAll(keepingCapacity: true)

            do {
                let url = try traceFileURL()
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                var payload = Data()
                for sample in samples {
                    payload.append(try encoder.encode(sample))
                    payload.append(0x0A)
                }
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: payload)
                let sessionCount = Set(samples.map(\.sessionID)).count
                ChipAnimationTrace.logger.info(
                    "exported samples=\(samples.count) sessions=\(sessionCount) path=\(url.path, privacy: .public)"
                )
            } catch {
                ChipAnimationTrace.logger.error("trace export failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        private func traceFileURL() throws -> URL {
            let library = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first
                ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true)
            let directory = library
                .appendingPathComponent("Logs", isDirectory: true)
                .appendingPathComponent("app.neobar.NeoBar", isDirectory: true)
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let url = directory.appendingPathComponent("chip-animation-trace.jsonl")
            if !fileManager.fileExists(atPath: url.path) {
                guard fileManager.createFile(
                    atPath: url.path,
                    contents: nil,
                    attributes: [.posixPermissions: 0o600]
                ) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            return url
        }
    }
}

struct ChipAnimationTraceState: Equatable {
    let isTapPressed: Bool
    let showsHover: Bool
}

enum ChipAnimationTraceEvent {
    static func hover(_ hovering: Bool) -> String { hovering ? "hoverEntered" : "hoverExited" }
    static func tap(_ pressed: Bool) -> String { pressed ? "tapPressed" : "tapReleased" }
}

struct ChipAnimationTraceSample: Codable, Equatable {
    let sessionID: UUID
    let chipID: String
    let kind: String
    let uptime: TimeInterval
    let hoverProgress: Double?
    let bareIconSize: Double?
    let pillHeight: Double?
    let pillIconSize: Double?
    let emphasisProgress: Double?
    let isTapPressed: Bool
    let showsHover: Bool
    let event: String?
}

struct ChipAnimationTraceBuffer {
    let capacity: Int
    private(set) var samples: [ChipAnimationTraceSample] = []

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    mutating func append(_ sample: ChipAnimationTraceSample) {
        if samples.count == capacity {
            samples.removeFirst()
        }
        samples.append(sample)
    }

    mutating func drain() -> [ChipAnimationTraceSample] {
        defer { samples.removeAll(keepingCapacity: true) }
        return samples
    }
}

/// What the bubble should show and where it attaches.
///
/// **There is only one sender in the whole app**: the single tracking area covering the entire strip
/// (`StripHoverResolution` → the `bubbleRequest` of `DockStripView`). It used to be that each card
/// sent its own, which required a whole set of guards about "who is entitled to occupy this panel".
/// The card-side `isHovering` could get stuck at true (a missed `.onHover(false)`), and from then on
/// that card would resend the request on every re-layout, dragging the bubble to flash somewhere the
/// pointer wasn't at all (reported by the owner on 2026-08-17). With a single sender, this kind of
/// preemption is structurally impossible, and the guards were deleted along with `Reason`.
struct WindowTitleTooltipRequest: Equatable {
    let chipID: String
    let title: String
    let anchorVisibleRect: CGRect
}

enum WindowTitleTooltipEvent: Equatable {
    case update(WindowTitleTooltipRequest)
    case exit(chipID: String)
}

/// Measured size of the app-name bubble on the native macOS 26 Dock.
///
/// Measured pixel by pixel from the owner's native screenshots on 2026-08-17 (@2x, black background,
/// "ChatGPT"). **Don't change it from impression**; to change it, re-screenshot and re-measure first:
///
/// | | Measured |
/// |---|---|
/// | Shape | **Capsule** (not a rounded rect). 26pt tall → 13pt corner radius; straight edge between the two semicircles |
/// | Height | 26pt |
/// | Left/right padding | 14pt each (measured to the glyph ink; 13 after subtracting the glyph's own side bearing) |
/// | Text | 57pt wide / 10.5pt ink height → SF 14pt regular (13pt is only 54.5 wide, clearly narrower) |
/// | Tail | **Pointing down**, base 23pt wide, 6.5pt tall, centered; flared base, straight middle section, **round-tipped end** |
/// | Tip distance from strip top | 6.5pt |
/// | Fill | Reads gray 173 on pure black |
///
/// The tail silhouette is **pixel-identical** in two native screenshots of different widths (half-widths
/// 16.5/14/12.5/10.5/9.5/8.5/7.5/6.5/5.5/4/3 @2x), so it is a fixed-size part that doesn't change with
/// the bubble width. The mid-section slope is about 1.17 (half-width/depth); extrapolated to 0 it
/// should end at 7.1pt, but it actually stops at 6.5pt: **the missing piece is the round tip** (what
/// the owner meant by "rounder").
///
/// **One size, whatever the bar height.** The native label is the same size on a small, default
/// and large Dock (measured on all three), and so is its gap to the Dock — so this table has no
/// scale factor and there is exactly one instance, `native`.
struct WindowTitleTooltipStyle: Equatable {
    let height: CGFloat
    let cornerRadius: CGFloat
    let horizontalPadding: CGFloat
    let fontSize: CGFloat
    let tailWidth: CGFloat
    let tailHeight: CGFloat
    /// Top end of the straight segment: the flared base closes in up to here.
    let tailShoulderDepth: CGFloat
    let tailShoulderHalfWidth: CGFloat
    /// Where the round tip starts: from here on it is that round cap.
    let tailTipDepth: CGFloat
    let tailTipHalfWidth: CGFloat
    /// Distance from the tip to the anchor's top edge.
    let tipGap: CGFloat
    let maximumWidth: CGFloat

    private init() {
        height = 26
        // Capsule: the corner radius is always half the height.
        cornerRadius = height / 2
        horizontalPadding = 13
        fontSize = 14
        tailWidth = 23
        tailHeight = 6.5
        tailShoulderDepth = 1.6
        tailShoulderHalfWidth = 6.6
        tailTipDepth = 5.6
        tailTipHalfWidth = 1.9
        tipGap = 6.5
        maximumWidth = 360
    }

    /// The measured native table — the only instance.
    static let native = WindowTitleTooltipStyle()
}

/// Capsule + a downward drop-shaped tail. The tail is drawn **inside the shape** instead of overlaying a triangle:
/// with an overlay, the strokes of the two pieces cross at the seam and leave a horizontal line, while the native one is a single continuous outline.
struct WindowTitleTooltipShape: InsettableShape {
    let style: WindowTitleTooltipStyle
    /// For `strokeBorder`: draws the stroke **entirely inside the shape**.
    ///
    /// It used to use `stroke`, which rides the line on the outline: half of a 0.5pt line falls outside
    /// the shape and antialiasing eats half of it, and the measured stroke was only 197 versus 209
    /// natively (converted against the same background). The stroke is the only source of the "crisp" look, so it can't be discounted.
    var insetAmount: CGFloat = 0

    func inset(by amount: CGFloat) -> Self {
        var copy = self
        copy.insetAmount += amount
        return copy
    }

    func path(in outerRect: CGRect) -> Path {
        let rect = outerRect.insetBy(dx: insetAmount, dy: insetAmount)
        let tail = style.tailHeight
        let body = CGRect(x: rect.minX, y: rect.minY,
                          width: rect.width, height: max(0, rect.height - tail))
        let radius = min(style.cornerRadius, body.height / 2)
        let halfTail = min(style.tailWidth, body.width) / 2
        let centerX = body.midX

        var path = Path()
        // Capsule body: right semicircle → top edge → left semicircle → bottom edge (up to the left of the tail's base).
        path.move(to: CGPoint(x: body.maxX - radius, y: body.maxY))
        path.addArc(center: CGPoint(x: body.maxX - radius, y: body.midY),
                    radius: radius, startAngle: .degrees(90), endAngle: .degrees(-90), clockwise: true)
        path.addLine(to: CGPoint(x: body.minX + radius, y: body.minY))
        path.addArc(center: CGPoint(x: body.minX + radius, y: body.midY),
                    radius: radius, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: true)
        // Tail in three segments (measured natively): flared concave shoulder at the base → straight middle section → round tip.
        // **Not a single point**: the extrapolated straight edge should close at 7.1pt, but it actually bottoms out at 6.5pt, and the missing piece is the round cap.
        let base = body.maxY
        let shoulderY = base + style.tailShoulderDepth
        let shoulderX = style.tailShoulderHalfWidth
        let tipY = base + style.tailTipDepth
        let tipX = style.tailTipHalfWidth
        // A quadratic curve reaches (start + 2×control + end)/4 at t=0.5, so the control point's y is solved this way to get the peak = base + tail.
        let capControlY = 2 * (base + tail) - tipY

        path.addLine(to: CGPoint(x: centerX - halfTail, y: base))
        path.addQuadCurve(to: CGPoint(x: centerX - shoulderX, y: shoulderY),
                          control: CGPoint(x: centerX - halfTail * 0.83, y: base + tail * 0.05))
        path.addLine(to: CGPoint(x: centerX - tipX, y: tipY))
        path.addQuadCurve(to: CGPoint(x: centerX + tipX, y: tipY),
                          control: CGPoint(x: centerX, y: capControlY))
        path.addLine(to: CGPoint(x: centerX + shoulderX, y: shoulderY))
        path.addQuadCurve(to: CGPoint(x: centerX + halfTail, y: base),
                          control: CGPoint(x: centerX + halfTail * 0.83, y: base + tail * 0.05))
        path.closeSubpath()
        return path
    }
}

struct WindowTitleTooltipView: View {
    let title: String
    /// Tier style. **Deliberately has no default value**: forgetting to pass it must be a compile error,
    /// same as `ChipView.scale` / `hoverStyle` /
    /// `onWindowTitleTooltipEvent` (AGENTS "Taskbar Size Tiers").
    let style: WindowTitleTooltipStyle
    /// Whether the backplate uses real liquid glass. **Likewise no default value**; the value is passed in by `PanelCoordinator`
    /// (its `usesLiquidGlass` is the single global source).
    let usesLiquidGlass: Bool

    @Environment(\.colorScheme) private var colorScheme
    private var theme: DockThemeTokens { .resolved(for: colorScheme) }

    var body: some View {
        let shape = WindowTitleTooltipShape(style: style)
        return label
            .frame(maxWidth: style.maximumWidth)
            .padding(.horizontal, style.horizontalPadding)
            // The text box fills the body height and is centered; the tail takes its space via extra bottom padding, so the text isn't pushed off by it.
            .frame(height: style.height)
            .padding(.bottom, style.tailHeight)
            .background(plate(shape: shape))
            // The system glass brings its own edge light and shadow; ours go only with our plate.
            .overlay {
                if drawsOwnChrome { shape.strokeBorder(theme.tooltipRim.color, lineWidth: 0.5) }
            }
            .dockShadow(theme.tooltipShadow, visible: drawsOwnChrome)
            .padding(PanelGeometry.windowTitleTooltipShadowPadding)
    }

    /// Bubble backplate. When glass is available it uses real liquid glass (with refraction); otherwise it falls back to the approved flat plate.
    ///
    /// **The native one is not an ordinary background blur but liquid-glass refraction** (pointed out by
    /// the owner on 2026-08-17, and measurements agree): on the same-brightness background (~235) the
    /// native fill is 247 and ours is 239, whereas the two "plate color x opacity" models differ by only 4 levels.
    /// The difference comes from **what is sampled behind it**: native samples the refracted neighborhood,
    /// so scattered dark text on a light window is smoothed away; we sample the real pixels behind, so
    /// native blurs into a wash while we can read it character by character.
    ///
    /// **Hand-rolling refraction ourselves is still impossible** (`.behindWindow` is composited in
    /// WindowServer, and this process can't see the pixels behind itself), but **using the system's glass
    /// is another matter**, and the five panels already do. The `in:` of `.glassEffect(_:in:)` takes any
    /// `Shape`, so the tail can render together with the body and doesn't have to be split in two
    /// (splitting leaves a horizontal line at the seam; we've stepped on that).
    ///
    /// Same structure as `DockLiquidGlassPlate`: glass + a layer of white lift **underneath** it.
    /// The two `materialActiveAppearance` / `appearsActive` settings can't be omitted: the bubble panel
    /// never becomes the key window, and without forcing them the material renders as "inactive" and the
    /// whole thing goes gray (already stepped on in the panel code).
    /// **The glass sits under the plate, not in place of it.** This was the most expensive lesson of this
    /// round; the measured numbers follow (black background / light background 235):
    ///
    /// | Plate approach | Black bg | Light bg | Native |
    /// |---|---|---|---|
    /// | `Glass.clear` only (the strip's approach) | — | **205** (darker than the background) | — |
    /// | `Glass.regular` only + 0.22 white lift | **45** | 245 | 173 / 247 |
    /// | Near-white plate 0.70 **over the glass** (current) | see verification | see verification | 173 / 247 |
    ///
    /// Glass alone can be tuned to 247 on a light background, **but on black it is only 45**:
    /// `.regular` darkens along with the background, while the native one stays light gray 173 on pure
    /// black, which is what makes black text readable. **One background can't calibrate two unknowns**
    /// (see `Docs/28`), and we almost fell into the same pit again.
    ///
    /// The native behavior is "a near-white semi-transparent plate + a blurred backdrop", so the plate's
    /// algebra is unchanged by a single character (`0.965 @ 0.70`, calibrated from three measured points
    /// and locked by `DockThemeTests`), and the glass is only responsible for **blurring the 30% that shows
    /// through**. The two paths therefore have identical algebra and differ only in whether that 30% is
    /// clear, so the fallback path can't drift off.
    @ViewBuilder
    private var label: some View {
        if theme.tooltipTextSmoothing {
            Text(title)
                .font(.system(size: style.fontSize, weight: .regular))
                .foregroundStyle(theme.tooltipText.color)
                .lineLimit(1)
                .truncationMode(.tail)
        } else {
            // The frame is computed here, from the title, not taken from the AppKit view: the panel
            // is sized from `fittingSize` in the same turn the title is swapped in, and a
            // representable's intrinsic size still describes the previous title at that point.
            let size = UnsmoothedLabel.size(of: title, fontSize: style.fontSize, maximumWidth: style.maximumWidth)
            UnsmoothedLabel(title: title, fontSize: style.fontSize, tint: theme.tooltipText)
                .frame(width: size.width, height: size.height)
        }
    }

    /// False only when the surface is the system's regular glass alone (`DockTooltipSurface`).
    private var drawsOwnChrome: Bool {
        guard #available(macOS 26.0, *), usesLiquidGlass else { return true }
        return theme.tooltipGlassSurface == .plateOverClearGlass
    }

    @ViewBuilder
    private func plate(shape: WindowTitleTooltipShape) -> some View {
        // Plate: shared by both paths, **not changed because of glass**.
        // Don't put `.ultraThinMaterial` underneath here: measured, it only lets through about 54% of the background and adds no white,
        // which presses the bubble down to 174 on a white background (native 249), and lowering the opacity can't save it either (it would need a plate color of 384).
        let plate = shape.fill(theme.tooltipPlate.color.opacity(theme.tooltipPlateOpacity))
        if #available(macOS 26.0, *), usesLiquidGlass, theme.tooltipGlassSurface == .regularGlassAlone {
            // Dark: the native bubble is this material, measured (`DockThemeTokens.dark`).
            shape
                .fill(Color.clear)
                .glassEffect(.regular.interactive(false), in: shape)
                .materialActiveAppearance(.active)
                .environment(\.appearsActive, true)
        } else if #available(macOS 26.0, *), usesLiquidGlass {
            plate.background {
                shape
                    .fill(Color.clear)
                    // **`.clear` rather than `.regular`: it preserves color noticeably better.** Measured on the same
                    // red target (plate on top, glass below; the black/white brightness points of both are identical):
                    // `.clear` (232,197,194) saturation **0.164**, `.regular` (206,187,186) saturation 0.097.
                    // Back-solving the glass's own output, `.clear`'s saturation is 0.63: **what washes out the color
                    // is the white plate above**, not the glass. Native is 0.269, which we can't reach: thinning the
                    // plate would recover chroma, but the 173 on black would collapse with it (computed at a=0.55 it
                    // drops to just 141), and black text being readable on black relies entirely on that.
                    // The native material self-illuminates in the dark **and** preserves color, which a linear stack
                    // can't do; this is an accepted limit.
                    .glassEffect(.clear.interactive(false), in: shape)
                    // The bubble panel never becomes the key window, and without forcing them the material renders as
                    // "inactive" and the whole thing goes gray (already stepped on in the panel code; see the comment
                    // on `DockLiquidGlassPlate`).
                    .materialActiveAppearance(.active)
                    .environment(\.appearsActive, true)
            }
        } else {
            plate
        }
    }
}

/// One line of text drawn with font smoothing off. SwiftUI's `Text` has no switch for it, and
/// smoothing is what makes the bubble's light-on-dark text read bolder than the native label
/// (`DockThemeTokens.tooltipTextSmoothing`).
private struct UnsmoothedLabel: NSViewRepresentable {
    let title: String
    let fontSize: CGFloat
    let tint: DockTint

    private static func font(_ size: CGFloat) -> NSFont { .systemFont(ofSize: size, weight: .regular) }

    /// The label's layout size, in whole points; wider titles are truncated to `maximumWidth`.
    static func size(of title: String, fontSize: CGFloat, maximumWidth: CGFloat) -> CGSize {
        let size = (title as NSString).size(withAttributes: [.font: font(fontSize)])
        return CGSize(width: min(ceil(size.width), maximumWidth), height: ceil(size.height))
    }

    func makeNSView(context: Context) -> UnsmoothedLabelView {
        let view = UnsmoothedLabelView()
        apply(to: view)
        return view
    }

    // SwiftUI re-runs update, never re-creates the view: the title and colour follow here.
    func updateNSView(_ view: UnsmoothedLabelView, context: Context) { apply(to: view) }

    private func apply(to view: UnsmoothedLabelView) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let colour = NSColor(white: tint.base == .white ? 1 : 0, alpha: tint.opacity)
        view.set(NSAttributedString(string: title, attributes: [
            .font: Self.font(fontSize),
            .foregroundColor: colour,
            .paragraphStyle: paragraph,
        ]))
    }
}

/// Draws into whatever frame SwiftUI gives it; it has no intrinsic size on purpose (see the call site).
final class UnsmoothedLabelView: NSView {
    private var text = NSAttributedString()

    override var isFlipped: Bool { true }

    func set(_ text: NSAttributedString) {
        guard text != self.text else { return }
        self.text = text
        needsDisplay = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setShouldSmoothFonts(false)
        text.draw(with: bounds, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}
