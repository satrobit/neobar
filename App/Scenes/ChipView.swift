import AppKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Chip View

/// Width driver for the label box: an `Animatable` view whose `animatableData` is the box width. On every animation frame
/// the body reruns with the interpolated `width`, and `content(width)` uses it to draw `.frame(width:)`. **It has to be driven
/// this way; relying on the implicit animation of `.frame(width:)` itself does not work.** Burst screen captures (2026-09-13)
/// showed that path renders in a single step in this strip, even with an animation in the transaction and even when the
/// probe sees the animated variable interpolating. Same mechanism as `ChipHoverProgress` for the hover pill.
/// The `boxA:` probe (`DOCK_LABEL_PROBE=1`) also logs the per-frame width for comparison with `panel:` on the panel side.
private struct LabelBoxWidthDriver<Content: View>: View, Animatable {
    var width: CGFloat
    let chipID: String
    @ViewBuilder let content: (CGFloat) -> Content
    @Environment(\.labelBoxWidthTick) private var tick
    var animatableData: CGFloat {
        get { width }
        set { width = newValue }
    }
    var body: some View {
        // Each frame, report the current box width to the panel (`PanelCoordinator.labelBoxWidthDidTick`). The panel sets its frame in the same pass,
        // committed together with this frame's content. Only SwiftUI's clock remains; the backing plate no longer has its own curve or prediction.
        let _ = tick(chipID, width)
        let _ = HoverTrace.width("boxA:" + String(chipID.suffix(4)), width)
        content(width)
    }
}

/// Reporting hook for the label box's per-frame width, injected by `DockStripView` and pointing at the coordinator of the panel cell it lives in. Default is a no-op:
/// strips that are not attached to a panel, such as the drag-carrier snapshot, have no backing plate to follow.
struct LabelBoxWidthTickKey: EnvironmentKey {
    static let defaultValue: (String, CGFloat) -> Void = { _, _ in }
}

extension EnvironmentValues {
    var labelBoxWidthTick: (String, CGFloat) -> Void {
        get { self[LabelBoxWidthTickKey.self] }
        set { self[LabelBoxWidthTickKey.self] = newValue }
    }
}

struct ChipView: View {
    @EnvironmentObject var runtime: AppRuntime
    @EnvironmentObject var drawerStore: DrawerStore
    @EnvironmentObject var messagingStore: MessagingAppStore
    @EnvironmentObject var keptAppStore: KeptAppStore
    @EnvironmentObject var appMembershipController: AppMembershipController
    @Environment(\.colorScheme) private var colorScheme
    private var theme: DockThemeTokens { .resolved(for: colorScheme) }
    let item: StripItem
    /// The line of text shown on the card, computed by the projection layer (app-name suffix removed, plus the common segment among several cards of the same app, issue #41).
    /// **Deliberately has no default value**: a missed argument would silently show the unprocessed long title, and all tests here are pure geometry
    /// with none checking SwiftUI call sites. The missing default is the regression test itself (same iron rule as `scale`).
    /// The full title goes through `fullTitle`, used only for the system tooltip of `.help()`.
    let labelTitle: String
    /// Height factor (`DockPanelHeight.scale`). **Deliberately has no default value**: the messaging zone once silently missed passing it because it had a default of 1.0,
    /// and rendered at the medium size on non-medium tiers (see AGENTS "Taskbar Size Tiers"). A missed argument must be a compile error.
    let scale: CGFloat
    /// Hover effect tier. **Also deliberately has no default value**: a missed argument is a compile error; see the `scale` note above for the reason.
    /// Under `.quiet`, hover produces no visual change; the full-text overlay for long titles is unaffected (it follows the bare `isHovering`).
    let hoverStyle: HoverStyle
    /// Whether the pointer is on this card. **Computed by the single tracking region covering the whole strip and passed in**; the card no longer attaches its own `.onHover`
    /// (gaps + boundary-band direction; for causes and measurements see `StripHoverResolution`). Also deliberately has no default value.
    let isHovered: Bool
    /// Whether the top of the context menu should list a Dock-style window list. Only entries where "one icon represents the whole app" are true
    ///(live zone = `item.isAppLevelFallback`; messaging-zone main-window card = always true); a plain window card is itself
    /// that window, so always false. **Deliberately has no default value**: a missed argument must be a compile error (same iron rule as `scale`).
    let showsWindowListInMenu: Bool
    /// This chip stands for the window that is in front right now (`StripProjection.frontWindowChipIDs`):
    /// the running dot stretches into a short bar. **No default on purpose** — an omission must be a
    /// compile error (same rule as `scale`): the two strip call sites both have the projection in hand.
    let isFrontWindow: Bool
    var iconOnly: Bool = false
    var showRunningDot: Bool = false
    /// See `EnvironmentValues.isDragCarrierSnapshot`: when snapshotting a copy, do not draw the dot or bake in the shadow.
    @Environment(\.isDragCarrierSnapshot) private var isDragCarrierSnapshot
    @Environment(\.chipPillUsesGlass) private var pillUsesGlass
    @Environment(\.displayScale) private var displayScale
    /// A height drag is a new icon size every tick: reuse the rendered bitmap until it ends.
    @Environment(\.isPanelHeightResizing) private var isPanelHeightResizing
    var drawerTap: (() -> Void)? = nil
    /// Pulse signal triggered by an external gesture (force-click / middle-click preview): a nonce change fires fireTapPulse once,
    /// giving the live Finder window preview an instant "tap registered" confirmation during its ~200ms reverse-lookup delay. Default 0 = no pulse.
    var pulseNonce: Int = 0
    /// Unread badge text (for messaging-app cards: the icon in the messaging zone, or the leftmost card in the regular zone); `nil` = draw nothing. The default `nil` is the **correct** omission semantics
    /// (most chips have no badge at all), so this one may have a default, unlike
    /// `scale` / `hoverStyle`, where a missed argument silently renders wrong.
    /// It is drawn inside the chip rather than layered in a ZStack by the caller; see `ChipBadgeView` for the reason.
    var badgeText: String? = nil
    /// Whether this card's slot is currently empty because the card is **being held in the hand** (`DragController.hiddenSlotPayload`).
    /// As soon as it becomes true, clear the press scale: in-strip reordering moves this card and SwiftUI then cancels the press gesture,
    /// so `isTapPressed` can only be reset by the 1s watchdog. At the moment the card is revealed on drop it may still be 0.93 or mid-bounce,
    /// a bit off from the carrier, which settles at 1.0 (one component of the owner's 2026-08-19 "drop-in jitter"). Clear it while the card is hidden,
    /// so on reveal it is always 1.0. The default `false` is the correct omission semantics (cards not being dragged do not need it), same as `badgeText`.
    var slotHidden: Bool = false
    /// Tap-confirmation pulse: a state-independent press rebound. Activating an "already visible" window produces zero change on the light/dark axis,
    /// so without it there is "no reaction at all" (owner 2026-07-06). A pure view-layer signal, never fed to the planner/frontmost axis (AGENTS).
    /// Driven by a declarative .animation(value:) (lesson from the LauncherChip zombie animation: no repeatForever + reset).
    @State private var isTapPressed = false

    /// Visual hover state: the real pointer hover OR forced (drag copy), then gated by the hover tier.
    /// Always false under "quiet": so the icon does not scale, the app name does not pop up, the capsule fill does not brighten, and the row does not reflow.
    private var showsHover: Bool { hoverStyle.showsExpressiveHover(isHovering: isHovered) }
    /// Hover feedback for the quiet tier (always false on the standard tier, whose feedback is the name bubble).
    private var quietHoverFeedback: Bool {
        hoverStyle.showsQuietHoverFeedback(isHovering: isHovered)
    }
    private var animationTraceKind: String {
        !iconOnly && (item.showsTitle || isMessagingAppWindow) ? "window" : "icon"
    }

    /// Diagnostic outlet for the press state. The state machine itself lives in `ChipPressFeedback`; only the trace is added here.
    private func recordPressEvent(_ pressed: Bool) {
        ChipAnimationTrace.event(
            chipID: item.id,
            kind: animationTraceKind,
            event: ChipAnimationTraceEvent.tap(pressed),
            isTapPressed: pressed,
            showsHover: showsHover
        )
    }

    private func recordHoverEvent(_ hovering: Bool) {
        ChipAnimationTrace.event(
            chipID: item.id,
            kind: animationTraceKind,
            event: ChipAnimationTraceEvent.hover(hovering),
            isTapPressed: isTapPressed,
            showsHover: hoverStyle.isExpressive && hovering
        )
    }

    /// Optimistic state first (interaction polish 2026-06-13): the moment of a click the chip renders immediately in the predicted state
    ///(minimize -> dimmed), without waiting for the snapshot round-trip and without a spinner.
    private var effectiveStatus: String {
        runtime.optimisticStatesByWindowID[item.actionWindowID]?.status.rawValue ?? item.status
    }

    private var effectiveIsOnDesktop: Bool {
        guard let optimistic = runtime.optimisticStatesByWindowID[item.actionWindowID] else {
            return item.isOnDesktop
        }
        return optimistic.status == .active
    }

    private var isMessagingAppWindow: Bool {
        guard let bid = item.bundleIdentifier else { return false }
        return !item.isAppLevelFallback && messagingStore.contains(bid)
    }

    var body: some View {
        Group {
            if !iconOnly && (item.showsTitle || isMessagingAppWindow) {
                multiWindowChip
            } else {
                bareIconChip
            }
        }
        .animation(.easeInOut(duration: 0.2), value: item.showsTitle)
        // Clear the press as soon as the slot is empty (see `slotHidden`). The card is transparent now, so nobody sees this rebound.
        .onChange(of: slotHidden) { hidden in
            if hidden, isTapPressed { isTapPressed = false }
        }
    }

    // MARK: - Icon-only chip

    private var bareIconChip: some View {
        let capturedFullTitle = fullTitle
        // **Hover on an icon-only card changes no pixels**, so no animation driver is attached here.
        //
        // Since the app name moved into the bubble above the icon, the icon no longer scales, the slot no longer changes, and the icon never fades by state
        // (owner 2026-08-02). The only remaining effect of `ChipHoverProgress` is to run an animatable scalar
        // through 0.18s, recomputing a dozen-odd frames on every hover enter/exit for nothing. When sweeping across a row of icons that cost piles onto the main thread,
        // and once the main thread is busy macOS **coalesces mouse-move events**, so cells passed in between never receive a hover callback
        // (exactly the owner's "moving at a steady speed over many, they don't get time to show"). The same mechanism bit us once in menus;
        // see the 100ms stickiness in AGENTS "Menus, Panels, And Screens".
        //
        // Titled cards still need it: the brightening of the pill fill and stroke really is animating.
        let hover = ChipHoverVisual.resolve(progress: 0, scale: scale)
        let _ = ChipAnimationTrace.record(
            chipID: item.id,
            kind: "icon",
            visual: hover,
            isTapPressed: isTapPressed,
            showsHover: showsHover
        )
        return VStack(spacing: 0) {
            Spacer(minLength: 0)
            appIcon(size: hover.bareIconSize)
            // The slot height must equal the **resting** icon size: this ZStack is .top-aligned,
            // so a slot smaller than the icon makes the whole block overflow downward (hardcoding 36 while the icon changed to 40 measured a 4pt shift down).
            .frame(width: ChipPillMetrics.cardWidth * scale,
                   height: ChipPillMetrics.bareIconSlot * scale,
                   alignment: .top)
            Spacer(minLength: 0)
        }
        .frame(width: ChipPillMetrics.cardWidth * scale,
               height: ChipPillMetrics.chipHeight * scale)
        // The dragged copy draws no dot (same as the native Dock: the dot disappears while dragging and returns on drop).
        // The bitmap is therefore **transparent** where the dot is, and the dot of the card on the strip shows straight through during the handoff pass, with no flash and no delay.
        .overlay(alignment: .bottom) {
            if showRunningDot && !isDragCarrierSnapshot {
                Capsule()
                    .fill(theme.runningDot.color)
                    .frame(width: (isFrontWindow ? ChipPillMetrics.frontWindowBarWidth : ChipPillMetrics.runningDotSize) * scale,
                           height: (isFrontWindow ? ChipPillMetrics.frontWindowBarHeight : ChipPillMetrics.runningDotSize) * scale)
                    .padding(.bottom, ChipPillMetrics.runningDotBottomPadding * scale)
                    .animation(.easeInOut(duration: ChipPillMetrics.frontWindowBarAnimation), value: isFrontWindow)
            }
        }
        // Unread badge: **must be attached before the two scales**, otherwise it stays still while the icon enlarges / shrinks back on press
        // (owner 2026-08-17 reported "when the icon grows, shouldn't the number and red dot change too?").
        .overlay(alignment: .topTrailing) {
            if let badgeText {
                ChipBadgeView(text: badgeText, scale: scale)
            }
        }
        // Hover feedback for the quiet tier: the whole block enlarges slightly. Placed **after** the running-dot overlay so the icon and dot enlarge together;
        // placed before `chipPressScale`, so on press the two scales multiply, as if the same object were being held down.
        // Card width 40 -> the cap rule computes 1.15, clamped back to 1.10 by the limit; the look of icon cards is unchanged by a single pixel.
        .chipQuietHoverScale(quietHoverFeedback,
                             cardWidth: ChipPillMetrics.cardWidth * scale,
                             scale: scale)
        .chipPressScale(isTapPressed)
        // Hover is neither measured by this card itself nor is the bubble emitted by it; both belong to the single whole-strip tracking region
        // (`StripHoverResolution`). Here the card just "draws according to `isHovered`".
        .contentShape(Rectangle())
        .onChange(of: isHovered) { recordHoverEvent($0) }
        .onTapGesture {
            if let drawerTap { drawerTap() } else { runtime.toggle(windowID: item.actionWindowID) }
        }
        // The press follows **press-down**, no longer waiting for onTapGesture (which fires only on mouse-up). Attached after contentShape,
        // so the hit region is exactly the same as for the click.
        .chipPressGesture(
            isPressed: $isTapPressed,
            pulseNonce: pulseNonce,
            onEvent: recordPressEvent
        )
        .nativeContextMenu { buildChipMenu() }
        .help(capturedFullTitle)
    }

    // MARK: - Labeled chip

    /// The pill's fill + stroke, the **only** thing on this card that still changes with hover.
    /// Per-frame interpolation stops here; for the reason see the comment in `multiWindowChip`.
    private var pillEmphasisBackground: some View {
        ChipHoverProgress(progress: showsHover ? 1 : 0) { progress in
            let shape = RoundedRectangle(cornerRadius: 10 * scale, style: .continuous)
            // The diagnostic sampling point for hover progress must stay here, because it needs the per-frame progress
            //(`DOCK_CHIP_ANIM_TRACE=1`, off by default).
            let _ = ChipAnimationTrace.record(
                chipID: item.id,
                kind: "window",
                visual: ChipHoverVisual.resolve(progress: progress, scale: scale),
                isTapPressed: isTapPressed,
                showsHover: showsHover
            )
            if #available(macOS 26.0, *), pillUsesGlass, let glass = theme.chipPillGlass {
                // The glass itself never changes per frame; only the lift over it animates.
                shape
                    .fill(Color.clear)
                    .glassEffect(.regular.tint(glass.tint.color).interactive(false), in: shape)
                    .overlay(shape.fill(DockTint(base: glass.hoverLift.base,
                                                 opacity: glass.hoverLift.opacity * Double(progress)).color))
            } else {
                shape
                    .fill(theme.effectiveChipPillFill.color(emphasisProgress: Double(progress)))
                    .overlay(
                        shape.strokeBorder(
                            theme.chipPillRimStyle(emphasisProgress: Double(progress)),
                            lineWidth: 0.5
                        )
                    )
            }
        }
        .animation(.easeInOut(duration: 0.18), value: showsHover)
    }

    private var multiWindowChip: some View {
        // The icon is always its original color (not faded by state, owner 2026-08-02); "whether it is on the desktop" is expressed only by the title color.
        let titleColor: Color = effectiveIsOnDesktop ? theme.labelActive.color : theme.effectiveLabelInactive.color
        let capturedDisplayTitle = displayTitle
        let capturedFullTitle = fullTitle
        // **The animatable scalar wraps only the pill's fill and stroke, not the whole card.**
        //
        // `ChipHoverProgress` is an `Animatable` view: every change of its `animatableData` reruns
        // the content closure. It used to wrap the whole card, so **every frame** of the 0.18s animation recomputed the icon, text,
        // padding, and the entire layout, while only the pill fill and stroke were actually moving; the
        // other fields of `ChipHoverVisual` (icon size, pill height) have all been constants since the hover geometry was frozen on 2026-08-16.
        // When sweeping across a row of titled cards this cost is multiplied by the number of cards.
        //
        // With it moved inside `.background`, only two shapes are recomputed per frame, with exactly the same interpolation function and values,
        // so the look is pixel-identical (it is the signed-off look).
        let metrics = ChipHoverVisual.resolve(progress: 0, scale: scale)
        let pill = HStack(spacing: ChipPillMetrics.iconSpacing * scale) {
            appIcon(size: metrics.pillIconSize)
                .frame(width: ChipPillMetrics.iconSlot * scale, height: ChipPillMetrics.iconSlot * scale)
                // Unread badge (cards in the regular zone also draw it since 2026-08-23): pressed onto the top-right of the small icon inside the pill, scaled down
                // one step by `titledCardBadgeScale`, since a 16pt badge on a 22pt icon is too crowded.
                // Likewise attached before the two scales, so it moves with hover / press / tier.
                .overlay(alignment: .topTrailing) {
                    if let badgeText {
                        ChipBadgeView(text: badgeText, scale: scale * ChipPillMetrics.titledCardBadgeScale)
                    }
                }
            titleLabel(capturedDisplayTitle, color: titleColor)
        }
        .padding(.horizontal, ChipPillMetrics.horizontalPadding * scale)
        .frame(height: metrics.pillHeight)
        .background(pillEmphasisBackground)

        return VStack(spacing: 0) {
            Spacer(minLength: 0)
            pill
                .frame(height: ChipPillMetrics.boxHeight * scale, alignment: .top)
            Spacer(minLength: 0)
        }
        .frame(height: ChipPillMetrics.chipHeight * scale)
        // Front-window bar under the pill, on the same bottom edge as the icon cards' dots. Titled cards
        // have no resting dot, so the bar grows out of nothing; the carrier bitmap leaves it out
        // like the dot (see `isDragCarrierSnapshot`). Placed before the scale modifiers so it moves
        // with the pill (size-tiers rule).
        .overlay(alignment: .bottom) {
            if !isDragCarrierSnapshot {
                Capsule()
                    .fill(theme.runningDot.color)
                    .frame(width: isFrontWindow ? ChipPillMetrics.frontWindowBarWidth * scale : 0,
                           height: ChipPillMetrics.frontWindowBarHeight * scale)
                    .opacity(isFrontWindow ? 1 : 0)
                    .padding(.bottom, ChipPillMetrics.runningDotBottomPadding * scale)
                    .animation(.easeInOut(duration: ChipPillMetrics.frontWindowBarAnimation), value: isFrontWindow)
            }
        }
        .padding(.horizontal, ChipPillMetrics.titledCardInset * scale)
        // Hover feedback for the quiet tier: the whole block enlarges slightly (the feedback on the standard tier is the name bubble + pill brightening).
        //
        // **The card width passed must be this card's own**: proportional enlargement expands far more on a wide card (measured: a 168.5pt card
        // grows 8.4pt per side, squeezing the 10pt gap between cards to only 3.5pt; reported by the owner 2026-08-17).
        // The width uses the same `ChipPillMetrics.width` that renders the pill, not a separate copy.
        .chipQuietHoverScale(
            quietHoverFeedback,
            cardWidth: ChipPillMetrics.width(title: capturedDisplayTitle, scale: scale)
                + 2 * ChipPillMetrics.titledCardInset * scale,
            scale: scale
        )
        .chipPressScale(isTapPressed)
        // Same as bareIconChip: hover and the bubble both belong to the whole-strip tracking region; here we only draw according to `isHovered`.
        .contentShape(Rectangle())
        .onChange(of: isHovered) { recordHoverEvent($0) }
        .onTapGesture {
            if let drawerTap { drawerTap() } else { runtime.toggle(windowID: item.actionWindowID) }
        }
        .chipPressGesture(
            isPressed: $isTapPressed,
            pulseNonce: pulseNonce,
            onEvent: recordPressEvent
        )
        .nativeContextMenu { buildChipMenu() }
        // The label is truncated at 140pt, and the title on this card also has the app-name suffix removed, so the full title has only this one outlet.
        // (The hover bubble does not count: it shows the app name, and newly installed users default to `.quiet`, which has no bubble at all.)
        .help(capturedFullTitle)
    }

    // MARK: - Title Label

    /// Label text swap: the old text first fades out quickly, then the new text slides in from the icon side and fades in. The two phases are staggered rather than overlapping
    /// (fading in and out at once stacks two lines of different lengths, giving the word start a momentary double image). The total length must be shorter than the box's width animation
    /// (`LabelWidthAnimation.curve.duration`): the text settles first while the box is still finishing; the reverse would read as two separate motions.
    private static let labelRemoval: Animation = .easeOut(duration: 0.16)
    private static let labelInsertion: Animation = .easeOut(duration: 0.34).delay(0.14)
    /// Offset of the new text at its start relative to its end position (unscaled), toward the icon side.
    private static let labelInsertionOffset: CGFloat = 3

    /// The line of text on a titled card.
    ///
    /// **The width is given explicitly, and the text is swapped by identity.** When the title goes from short to long (or the reverse), three things on this card
    /// change: the text, the pill width, and the position of the right-hand neighbor card; the panel window's glass backing plate is chased by
    /// a separate 0.22s AppKit animation from `PanelCoordinator`. With the let-`Text`-size-itself approach the first three snap in one step and only
    /// the plate slides, which is what the owner called "stiff, abrupt" on 2026-09-12. Here the three are separated:
    /// - the outer box's `.frame(width:)` follows the strip's layout animation with the same curve and duration as the plate
    ///   (the one on `DockStripView` triggered by `labelTitleByChipID`), so the pill and neighbor cards slide along with it;
    /// - the text swaps identity via `.id(title)` with an asymmetric transition: old text fades out first, then new text slides in and fades in, with no instant swap;
    /// - each `Text` only knows its own width (fixed-width truncation only past the cap) and **does not reflow at the box's intermediate widths**,
    ///   otherwise the ellipsis is recomputed and the tail jitters on every frame mid-animation.
    /// `.clipped()` clips only to the box's current width: when growing, the new text is revealed frame by frame from the icon side; when shrinking, the old text is tucked in.
    private func titleLabel(_ title: String, color: Color) -> some View {
        let boxWidth = ChipPillMetrics.labelWidth(title: title, scale: scale)
        let truncates = ChipPillMetrics.labelTruncates(title: title, scale: scale)
        return LabelBoxWidthDriver(width: boxWidth, chipID: item.id) { liveWidth in ZStack(alignment: .leading) {
            Text(title)
                .font(.system(size: max(10, 12 * scale), weight: .medium, design: .rounded))
                .foregroundStyle(color)
                .lineLimit(1)
                .frame(width: truncates ? WindowTitleTextMetrics.maximumWidth(for: scale) : nil,
                       alignment: .leading)
                .fixedSize(horizontal: !truncates, vertical: false)
                .id(title)
                .transition(.asymmetric(
                    insertion: .opacity
                        .combined(with: .offset(x: -Self.labelInsertionOffset * scale))
                        .animation(Self.labelInsertion),
                    removal: .opacity.animation(Self.labelRemoval)
                ))
        }
        // Wraps only the text swap; the box's `.frame(width:)` is **outside** this layer and takes the strip's layout animation.
        // The two transition phases each carry their own curve; this one just puts the swap inside an animatable transaction.
        .animation(Self.labelInsertion, value: title)
        // The box width takes the `liveWidth` that the driver supplies every frame (see `LabelBoxWidthDriver`); neighbor cards reflow frame by frame with it.
        .frame(width: liveWidth, alignment: .leading)
        .clipped()
        }
        // Drives only `LabelBoxWidthDriver.animatableData`; the curve is shared with the panel plate via `LabelWidthAnimation`.
        .animation(LabelWidthAnimation.swiftUI, value: boxWidth)
    }

    // MARK: - Shared Icon

    private func appIcon(size: CGFloat) -> some View {
        Image(nsImage: AppIconResolver.icon(for: item.bundleIdentifier ?? item.appID, points: size,
                                             displayScale: displayScale, colorScheme: colorScheme,
                                             allowsRendering: !isPanelHeightResizing))
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size / 4, style: .continuous))
            // We **add no extra** outer shadow (owner 2026-08-19): the layer we added before was a net surplus,
            // measuring 18-24 darker directly under the icon than in the gaps on either side. Same for the transit-cell square and the folder cover.
            //
            // ⚠️ This used to say "measured: the macOS icon asset casts no shadow of its own, alpha is exactly 0 below the body" --
            // **that was wrong, disproved on 2026-08-20**: it only measured a single line directly under the icon, while the shadow baked into the asset
            // is **all around**. Pixel-level measurement (preview icon, 32pt): about 5px outside the body is semi-transparent pure black,
            // with alpha rising from 0.004 up to 0.102 and luminance always 0. Data and lessons in
            // `Docs/Archive/Engineering/24-guardrail-provenance.md`.
            // So the dark rim around the icon at rest is **drawn by Apple in the asset**, not drawn by us.
    }

    // MARK: - Context Menu

    // Interruptible (2026-06-13): menu items are no longer grayed out by pending; show/hide actions can be clicked at any time
    //(the optimistic overlay guarantees consistency), and close / quit re-entry is guarded by runtime.trigger.
    // State branches read effectiveStatus, so right-clicking right after minimizing still shows "Restore".
    private var isFinderChip: Bool { FinderTaskbarPolicy.isFinder(item.bundleIdentifier) }

    /// Native AppKit menu rebuilt fresh on each right-click (captures live runtime
    /// + store + optimistic state). See AppMenuFragments for why this isn't SwiftUI.
    private func buildChipMenu() -> NSMenu {
        let menu = NSMenu()
        let bid = item.bundleIdentifier
        // Window list first (app-level entries only; ordering see Docs/27 2026-08-24): ✓ frontmost window, ◇ minimized.
        // Read-only snapshot: the menu is built synchronously at the instant of right-click, and no AX is done on this path.
        if showsWindowListInMenu, let listBid = bid {
            AppMenuBuilder.appendWindowList(
                to: menu,
                entries: WindowListMenuPlan.entries(
                    snapshot: runtime.snapshot,
                    bundleID: listBid,
                    fallbackTitle: AppDisplayNameResolver.displayName(for: listBid)
                ),
                activate: { runtime.activate(windowID: $0) }
            )
        }
        // Recent items pinned on top: Finder shows "Recent Folders" (FXRecentFolders), other apps show "Recent Files".
        if isFinderChip {
            AppMenuBuilder.appendFinderRecentFolders(to: menu)
        } else {
            AppMenuBuilder.appendRecentDocuments(to: menu, bundleID: bid)
        }
        if item.isAppLevelFallback {
            if isFinderChip { AppMenuBuilder.appendFinderItems(to: menu) }
            if effectiveStatus == "hidden" {
                menu.addItem(ClosureMenuItem(String(localized: "Show")) { runtime.activate(windowID: item.actionWindowID) })
            } else {
                menu.addItem(ClosureMenuItem(String(localized: "Hide")) { runtime.hide(windowID: item.actionWindowID) })
            }
            // Member items first and Quit always last, consistent with the window-card branch below.
            appendMembershipItems(to: menu)
            menu.addItem(.separator())
            AppMenuBuilder.appendQuitItems(to: menu, bundleID: bid) {
                runtime.quit(windowID: item.actionWindowID)
            }
        } else {
            if isFinderChip { AppMenuBuilder.appendFinderItems(to: menu) }
            menu.addItem(ClosureMenuItem(String(localized: "New Window")) { runtime.newWindow(windowID: item.actionWindowID) })
            if effectiveStatus == "minimized" {
                menu.addItem(ClosureMenuItem(String(localized: "Restore")) { runtime.activate(windowID: item.actionWindowID) })
            } else {
                menu.addItem(ClosureMenuItem(String(localized: "Minimize")) { runtime.minimize(windowID: item.actionWindowID) })
            }
            if effectiveStatus == "hidden" {
                menu.addItem(ClosureMenuItem(String(localized: "Show")) { runtime.activate(windowID: item.actionWindowID) })
            } else {
                menu.addItem(ClosureMenuItem(String(localized: "Hide App")) { runtime.hide(windowID: item.actionWindowID) })
            }
            appendMembershipItems(to: menu)
            menu.addItem(.separator())
            // Close whole group (2026-06-14): "Close Window" on a tab group closes every tab in the group;
            // for a plain window memberWindowIDs == [id], behavior unchanged.
            menu.addItem(ClosureMenuItem(String(localized: "Close Window")) {
                for wid in item.memberWindowIDs { runtime.close(windowID: wid) }
            })
            AppMenuBuilder.appendQuitItems(to: menu, bundleID: bid) {
                runtime.quit(windowID: item.actionWindowID)
            }
        }
        return menu
    }

    /// Kept membership conversions go through the controller. Messaging remains
    /// mutually exclusive with kept membership. Stashing (into the drawer) has no menu entry:
    /// the only path is dragging onto the capsule/drawer (owner 2026-07-10: right-click keeps only "Keep in Dock" and the messaging flag).
    private func appendMembershipItems(to menu: NSMenu) {
        guard let bid = item.bundleIdentifier else { return }
        let items = LauncherMembershipItem.items(
            surface: .strip,
            bundleID: bid,
            isKept: keptAppStore.contains(bid),
            isMessaging: messagingStore.contains(bid),
            controller: appMembershipController
        )
        guard !items.isEmpty else { return }
        menu.addItem(.separator())
        for descriptor in items {
            menu.addItem(AppMenuBuilder.membershipItem(descriptor))
        }
    }

    // MARK: - Helpers

    /// The label rendered on the card (the `labelTitle` computed by the projection layer).
    ///
    /// **This one string feeds three places at once**: the rendered `Text`, `chipQuietHoverScale` derived from `ChipPillMetrics.width(title:scale:)`,
    /// and the bubble anchor computed by `ChipPillMetrics.pillRect`. If any one of them goes back to
    /// `fullTitle`, the hover scale cap and the bubble tail anchor on a width that does not exist.
    private var displayTitle: String { labelTitle }

    /// The full, untruncated title, used only for the system tooltip: icon-only cards show no text, and with the app name shortened it would be visible nowhere.
    private var fullTitle: String {
        WindowDisplayTitle.resolve(rawTitle: item.title, fallbackName: appName)
    }

    private var appName: String {
        let name = item.bundleIdentifier.map(AppDisplayNameResolver.displayName(for:)) ?? item.appID
        return WindowDisplayTitle.resolve(rawTitle: nil, fallbackName: name)
    }
}
