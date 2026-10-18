import AppKit
import Combine
import SwiftUI

// `DragSource` is defined in Core/Support/DragConversionPlan.swift (pure decision layer, compiled locally in the test target).

/// Container for the carrier panel. A plain transparent `NSView` whose layer hosts the `CALayer` holding the carrier bitmap.
///
/// An `NSHostingView` cannot be used directly as the `contentView` (the AGENTS guardrail), and since 2026-08-18 the carrier
/// is no longer SwiftUI at all. This is a **non-flipped view**, so sublayer coordinates have a bottom-left origin with y up,
/// the same orientation as screen coordinates, and the conversion is just a translation (see `DragCarrierGeometry`).
private final class CarrierContainerView: NSView {
    /// Non-nil **only during the landing flight**: the frame of the returning icon right now (presentation) in this view's coordinates.
    /// The panel normally has `ignoresMouseEvents = true` and never reaches `hitTest`; while the pointer is over the icon during flight,
    /// the controller switches the panel to accept events (`DragController.refreshLandingGrabState`), and this property then guards
    /// by the icon's current frame: a point outside the icon always yields `nil`.
    var grabRegion: (@MainActor () -> CGRect?)?
    /// Pressing on the flying icon continues the drag from its current position (`DragController.regrabLanding`).
    var onGrab: (@MainActor (CGPoint) -> Void)?

    /// The carrier panel is never the key window, so the first press must be accepted too (same reason as `MenuActionButton`).
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let region = grabRegion?(), region.contains(convert(point, from: superview)) else { return nil }
        return self
    }
    override func mouseDown(with event: NSEvent) { onGrab?(NSEvent.mouseLocation) }
}

/// What the carrier (the floating copy) is drawn as.
enum DragVisualKind { case stripChip, drawerIcon, folderChip, keptAppIcon, messagingIcon }

/// Generic drag payload. Strip cards have a `StripItem`; many drawer icons (windowless running items / non-running stashed items / pure pinned items)
/// only have a bundleID and no `StripItem`, so `item` is optional and `bundleID` is the unified primary key. `id` is for the source panel's own
/// ordering (strip = chip identity token `item.id`, drawer = bundleID), so the source panel does not have to guess from the payload.
struct DragPayload {
    let source: DragSource
    let id: String          // strip = item.id (chip token); drawer = bundleID
    let bundleID: String
    let item: StripItem?     // Only present for strip window cards
    let visualKind: DragVisualKind
    /// Whether it can be dropped on the "other panel" to trigger stash / move back. strip = `canStash`; drawer = a real stashed item (`drawerStore.contains`).
    /// Pure pinned items = false: they can only be reordered within the drawer, and dragging to the strip neither highlights nor acts (Codex second review).
    let canExternalDrop: Bool
}

/// The single authority for cross-panel dragging (drag a card into the drawer: route C / drag from the drawer back to the strip, 2026-06-20 to 21).
///
/// Symmetric in both directions: dragging a strip card onto the capsule = stash; dragging a drawer icon onto the strip = move back. A full-screen self-drawn carrier + local monitor
/// mechanism is reused in reverse (mechanism probe 2026-06-20 confirmed: after a mouse-down starts a drag, the implicit grab makes the local monitor receive events throughout, including the release).
/// Everything is contained here: carrier panel lifecycle, monitors, drop-target detection, idempotent teardown. Source panels only call `beginDrag` and read
/// `draggingPayload` (hide the original slot) / `isOverDropZone` (reorder while inside the zone).
@MainActor
final class DragController: ObservableObject {
    @Published private(set) var draggingPayload: DragPayload?
    @Published private(set) var isOverDropZone = false

    /// Cursor position during a drag (screen coordinates). **Deliberately not `@Published`.**
    ///
    /// Measured 2026-08-18 (`DOCK_HOVER_TRACE`): it used to be `@Published`, and `DockStripView`
    /// subscribes to this object via `@EnvironmentObject`, so **every mouse movement invalidated and recomputed the whole strip**,
    /// reaching **46 full-body recomputations per second** of dragging (each rebuilding the whole projection: snapshot to cards, member projection, order reconciliation).
    /// With the main thread saturated by these, carrier position updates arrived late and frames were even dropped on fast drags, which is exactly the owner's report of
    /// "lag when starting a drag" and "the icon briefly disappears when dragging fast".
    ///
    /// Now: the value itself is a plain property, and changes are broadcast through `pointerMoves`.
    /// - The carrier's **position** no longer goes through SwiftUI at all: `update()` sets the `position` of the layer holding the bitmap directly
    ///   (see `moveCarrier`).
    /// - Anything that needs to **run a side effect every frame** (in-strip reordering, cross-panel conversion) uses `.onReceive(pointerMoves)`:
    ///   the closure still runs, but no dependency is created on the view, so it only redraws if the side effect actually changed something.
    private(set) var globalLocation: CGPoint = .zero
    private let pointerSubject = CurrentValueSubject<CGPoint, Never>(.zero)
    /// A "click" on a card during flight (released after the regrab without moving past `regrabClickSlop`). The action is dispatched by the panel that owns the card
    /// (`.onReceive` in `DockStripView` / `DrawerView`); the controller does not know what each kind of card should do when clicked.
    let carrierClicks: AnyPublisher<DragPayload, Never>
    private let carrierClickSubject = PassthroughSubject<DragPayload, Never>()
    /// A bar card / messaging chip released on the capsule. Each capsule turns to its first page,
    /// where the stashed app now sits (it goes to the front of the drawer order).
    let capsuleStashes: AnyPublisher<String, Never>
    private let capsuleStashSubject = PassthroughSubject<String, Never>()
    /// **Store as a `let`; do not erase on every call**: SwiftUI's `onReceive` resubscribes whenever the publisher instance changes,
    /// and `CurrentValueSubject` re-emits the current value on subscribe, which would needlessly rerun the side effect on every body evaluation.
    let pointerMoves: AnyPublisher<CGPoint, Never>
    /// Cross-screen drop (multi-screen items 3 and 4, owner 2026-09-02): when a strip card is released while claimed by a **different** strip (that strip has taken over
    /// once the pointer hovers over it, see `DockStripView.updateCrossStripHover`) -> window card: the window moves to that strip's screen; for a windowless
    /// fallback card / reserved placeholder: that app's "which screen its windowless icon lives on" is changed to that screen. The orchestration layer picks this up in `AppRuntime.handleCrossStripDrop`.
    var onCrossStripDrop: ((DragPayload, String) -> Void)?

    private(set) var grabOffset: CGSize = .zero
    private(set) var carrierScreenFrame: CGRect = .zero

    // MARK: - Landing flight after release

    /// The 0.26 seconds between release and the carrier actually disappearing: the floating copy flies from the cursor back to the card slot.
    /// See `DragLandingPlan`. `nil` = no flight in progress (including when it is disabled or no landing point is available).
    struct Landing: Equatable {
        /// Fly back to the card slot (can be corrected, regrabbed, clicked) / get sucked into the capsule (stash: fixed target and duration, none of those).
        enum Kind { case returnToSlot, stash }
        /// A new token for every flight: the carrier-retire timer and the animation completion callback both claim by it,
        /// so two consecutive drags do not finish each other.
        let token: Int
        let payload: DragPayload
        let kind: Kind
        /// **The destination can change mid-flight** (`var`, not `let`). At release the card slot is often still running its make-way animation,
        /// so the measured position is an interpolated one; correcting once more after it settles keeps the icon from jumping at the last moment.
        var flight: DragLandingFlight

        static func == (lhs: Landing, rhs: Landing) -> Bool {
            lhs.token == rhs.token && lhs.kind == rhs.kind && lhs.flight == rhs.flight
        }
    }
    /// Published **only when the flight's identity changes** (a new flight, or none): the views
    /// read `landing?.payload` to keep the slot empty and exempt the flying card from hover, and
    /// nothing in SwiftUI reads `flight`. A mid-flight retarget (`retargetLandingIfNeeded`) rewrites
    /// `flight` on every make-way frame — publishing those would re-evaluate every strip per frame
    /// for a geometry change that the carrier layer alone consumes. Not `@Published` for that
    /// reason; the token comparison is the publication boundary.
    private(set) var landing: Landing? {
        willSet {
            guard landing?.token != newValue?.token else { return }
            HoverTrace.landingPublish()
            objectWillChange.send()
        }
    }

    /// **The view decides "which slot must stay empty" with this, always.** The original slot must stay empty during the landing flight,
    /// otherwise the card appears while the carrier is still flying = two shadows again.
    ///
    /// The drag-start side **no longer has any gating**: the carrier is a bitmap, and `beginDrag` places it synchronously in the same run loop turn
    /// at the card's original slot, at the same size, pixel for pixel on top of the card, so no matter when "the card hides" there is no gap showing:
    /// an overlap of one or two frames is invisible. The earlier `carrierReady` / `onAppear` report / 50ms fallback timer machinery
    /// was refereeing a race between two renderers, and was deleted along with the bitmap carrier.
    var carriedPayload: DragPayload? { draggingPayload ?? landing?.payload }

    /// **The view decides "which slot must stay empty" with this, not `carriedPayload`.** The drag-start side must wait for `carrierArmed`
    /// (see that property for why); the landing side should show the card as soon as `landing` is cleared, so the two ends are asymmetric.
    var hiddenSlotPayload: DragPayload? {
        if draggingPayload != nil { return carrierArmed ? draggingPayload : nil }
        return landing?.payload
    }

    /// The carrier has landed and the card on the strip is visible again, but the bitmap stays for one more run loop turn before being retired
    /// (see `finishLanding`). Hover must still be suppressed during that turn.
    /// Not `@Published`: no view reads it (nor `isCarrying`); it only gates `clearCandidate` and the
    /// handoff turn inside this controller. As a published flag its true→false flip on the next
    /// run-loop turn cost every strip one more whole re-evaluation per landing.
    private(set) var carrierRetiring = false

    /// **From which moment the slot on the strip is truly empty**, and from which moment the lift animation begins. The two are tied together.
    ///
    /// At drag start the carrier's bitmap is a brand-new `CGImage`, and its first frame waits for one texture upload; measured, it is **always** a whole display frame
    /// later than SwiftUI hiding the card (2026-08-19, frame-by-frame comparison of three consecutive drag recordings: frames 46 / 137 / 228
    /// each showed one frame of "slot empty, carrier not yet on screen", and keeping the panel resident without `orderOut` made no difference,
    /// so it is not `orderFront` latency).
    ///
    /// Two paths, depending on whether a **prepared candidate** exists (see `prepareCandidate`):
    /// - At press time the bitmap was already attached to the layer and the texture warmed up at an imperceptible opacity -> release immediately in the drag-start turn:
    ///   lighting up the carrier and hiding the card happen in the same turn and the same commit, and `liftCarrier` also runs that turn.
    /// - No candidate (the caller did not prepare one, or the candidate does not match) -> first let the carrier appear at the card's original slot, same size, pixel for pixel,
    ///   **wait two display frames** (`DragLandingPlan.pickUpSettle`), then "hide the card + lift". The first version deferred by
    ///   "one run loop turn": synthetic drags step every 16ms so the next turn lands exactly on the next frame and the problem was invisible; a real mouse
    ///   delivers an event every 1-8ms, so the next turn is often still in the same frame, and a hidden card with the bitmap not yet on screen = a one-frame gap,
    ///   which is the owner's 2026-08-19 report of "it sometimes disappears". Deferring by time rather than by turns is what matches display frames.
    /// An overlap of one or two frames is harmless; a one-frame gap is a visible flash.
    @Published private(set) var carrierArmed = false

    /// "Something is held in hand" (including the landing flight after release and the final overlapping turn). **It must stay true until the carrier is really gone**,
    /// otherwise the card is already in hover state during the overlapping frame (the quiet tier even scales it by 1.10), differing noticeably from the carrier's last frame.
    var isCarrying: Bool { carriedPayload != nil || carrierRetiring }

    /// The period during which hover detection should **freeze in place**: the carrier is already on the original slot, but the card is not hidden yet.
    ///
    /// During these frames the carrier's pose is set from the slot's current "hover x press" composite state (`DragCarrierGeometry.pickUpPose`),
    /// and if the card had its hover cleared because "dragging started" and began its 0.12s fall-back, the two would no longer match.
    /// The first version exposed an "up/down ghosting" exactly this way. So **touch nothing** at drag start: `hoveredEntryID` stays as it was.
    var hoverFrozen: Bool { draggingPayload != nil && !carrierArmed }

    /// The period during which **the whole strip does not evaluate hover**: only when something is truly held in hand.
    ///
    /// Lighting up whatever the pointer sweeps over during a drag, and popping its name tooltip, was wrong to begin with; in the native Dock other icons do not light up during a drag either.
    ///
    /// **The landing flight is not included** (owner 2026-08-19 reported "no hover effect when sweeping over other icons while an icon is flying"):
    /// after release the mouse is free again, and natively, sweeping over other icons at that point still shows their names. During flight, only **the one flying card** is exempted,
    /// see `hoverExemptPayload`.
    var hoverSuppressed: Bool { draggingPayload != nil && carrierArmed }

    /// The **single exempted** card: the one flying back / the one that just settled and is still waiting for pointer movement. Other cards hover normally.
    ///
    /// Both reasons apply to this one card only, not to any other card:
    /// - During flight its slot is empty; if hover were granted to it then, by the time it lands and reappears it would already be in hover state (the quiet tier even
    ///   scales it by 1.10), while the carrier's last frame is drawn in the **non-hover** state, so the handoff frame would "pop";
    /// - After landing the pointer is necessarily on top of it; re-evaluating hover just as the card settles at 1.0 would make it grow on the spot, which is the owner's
    ///   2026-08-19 report of "landing jitter". AppKit itself also waits for the mouse to move before sending
    ///   mouseEntered after a drag-and-drop ends (the hold period is handled by `hoverHoldPayload` and lifted as soon as the pointer moves).
    ///
    /// The turn that retires the carrier (card visible, bitmap not yet removed) needs no special handling: the non-flying branches of `finishLanding` and `teardown`
    /// both call `beginHoverHold(for:)` **before** `retireCarrierAfterHandoff()`, so that turn is covered by the hold.
    var hoverExemptPayload: DragPayload? { landing?.payload ?? hoverHoldPayload }

    /// The combined value of the hover gates. The view uses it as the trigger for re-evaluation: with `hoverSuppressed` alone,
    /// "the exempted target changed" would not trigger re-evaluation (the moment the flight ends is exactly when it changes).
    var hoverGate: HoverGate {
        HoverGate(suppressed: hoverSuppressed, exemptID: hoverExemptPayload?.id,
                  exemptSource: hoverExemptPayload?.source)
    }
    struct HoverGate: Equatable {
        let suppressed: Bool
        let exemptID: String?
        let exemptSource: DragSource?
    }

    /// The card that just settled while the pointer has not moved yet. While non-nil, hover is always suppressed; cleared as soon as the pointer moves (or after a 3-second fallback).
    /// The drawer side uses it to suppress `LauncherChip` hover feedback; the strip side goes through `hoverSuppressed`.
    @Published private(set) var hoverHoldPayload: DragPayload?
    private var hoverHoldTimer: Timer?
    private var hoverHoldOrigin: CGPoint = .zero
    private var hoverHoldStartedAt: CFTimeInterval = 0

    /// Scale while held in hand. The carrier and the flight start share this one expression; written separately, they drift apart.
    ///
    /// Shrinking to `dropZoneScale` means "releasing now will stash it into the drawer", so it **only applies to sources taken from the strip**.
    /// Drawer sources do not shrink (owner 2026-08-20): their "drop zone" is the whole strip, so shrinking would mean shrinking the moment it enters the strip,
    /// while in-strip drags never shrink on the strip; in the normal case it would also first shrink to 0.82 within the same turn and then bounce back to 1.0 once converted,
    /// with two 0.12s animations fighting; and in `.reject` / `.releaseToMessaging` modes it would stay shrunk the whole time.
    var carriedScale: CGFloat {
        guard let source = draggingPayload?.source, source != .drawer else {
            return DragLandingPlan.carriedScale
        }
        return isOverDropZone && !isConvertedToStrip
            ? DragLandingPlan.dropZoneScale : DragLandingPlan.carriedScale
    }

    /// The scale the carrier should have right now. When a folder chip is dragged out of the strip's visible range, one more enlargement step is layered on
    /// (`.folder` always has `canExternalDrop == false`, so the `carriedScale` branch is constant at its normal value and the two do not conflict).
    private var carrierVisualScale: CGFloat {
        guard draggingPayload?.source == .folder, folderDragZone == .outsideStrip else { return carriedScale }
        return carriedScale * DragLandingPlan.folderRemovalScale
    }

    /// The opacity the carrier should have right now. Only "a folder chip dragged out of the strip's visible range" fades out.
    private var carrierVisualOpacity: Float {
        draggingPayload?.source == .folder && folderDragZone == .outsideStrip
            ? DragLandingPlan.folderRemovalOpacity : 1
    }

    /// Drop-target anchor (screen coordinates). **Each of the two views writes its own, on every cursor update**, tagged with an owner label:
    /// the strip side handles `.strip` / `.messaging` payloads, the drawer side handles `.drawer` payloads.
    /// Without the owner tag, after a drawer icon is converted into the strip, the stale anchor written by the drawer would linger,
    /// and the icon would fly into a drawer that has already closed.
    enum LandingAnchorOwner { case strip, drawer }
    private var landingAnchor: (owner: LandingAnchorOwner, rect: CGRect)?
    private var landingTimer: Timer?
    /// Whether the CA animation for this landing flight has been issued. False during the hold period (`DragLandingPlan.landingSettle`):
    /// correction only changes the destination without reissuing; after takeoff it is true and correction really reissues the animation.
    private var landingLaunched = false
    private var landingLaunchTask: DispatchWorkItem?
    /// Incremented each time a flight animation is (re)issued. CA's completion callback also fires when an animation is **replaced**,
    /// and `landing.token` alone cannot tell (correction does not change the token), so a separate generation counter is kept.
    private var landingAnimation = 0
    private var dragBeganAt: CFTimeInterval = 0
    private var landingToken = 0
    /// Correction can push the flight back, but not indefinitely. The cap is fixed as soon as the flight starts.
    private var landingDeadline: CFTimeInterval = 0

    func setLandingAnchor(_ rect: CGRect?, owner: LandingAnchorOwner) {
        if let rect {
            landingAnchor = (owner, rect)
            if owner == .strip { lastKnownSlotAnchor = rect }
        } else if landingAnchor?.owner == owner {
            landingAnchor = nil
        }
        if landing != nil {
            HoverTrace.landingAnchor(owner: "\(owner)", rect: landingAnchor?.rect)
        }
        retargetLandingIfNeeded()
    }

    /// **Mid-flight correction** during the flight.
    ///
    /// At release the card slot is mostly still running its make-way animation (a 0.28s spring in the strip / a 0.22s grid reflow in the drawer),
    /// and `GeometryReader` reports an interpolated intermediate value; flying to it means that by the time the carrier is retired the card has landed elsewhere,
    /// and the dozen or so pt of difference is what the owner saw as "landing still jitters". The anchor keeps updating during flight
    /// (the view side was changed to report per frame change, see `updateLandingAnchor`), and the destination follows it here;
    /// SwiftUI then continues smoothly from the current position.
    ///
    /// Threshold 0.5pt: sub-pixel jitter is not worth reissuing for (`DockStripView` observes this object,
    /// and each reissue recomputes the whole body).
    private func retargetLandingIfNeeded() {
        guard var current = landing,
              DragLandingPlan.allowsRetarget(
                remainingBeforeDeadline: landingDeadline - CACurrentMediaTime(),
                flightDuration: current.flight.duration)
        else { return }
        // **The two kinds of flight follow two different destinations; never mix them.**
        // `.returnToSlot` follows the card slot anchor; `.stash` follows the **capsule** (fetching `stashTargetProvider` again).
        // `.stash` used to be excluded from correction entirely, with the comment's reason being "for a frame or two after stashing the strip still reports
        // the old frame of that slot, and following it would pull the icon back onto the strip". That is about the card slot anchor, not the capsule, so splitting by destination source is enough.
        // The cost of excluding it was the owner's 2026-08-20 report of "dragging onto the capsule, the icon occasionally flies outside the drawer":
        // the destination is computed at release and only afterwards `drawerStore.add` runs; once the card leaves the strip, the strip narrows and re-centers as a whole,
        // the capsule slides left for 0.22s along with it, while the flight still heads to the capsule's old position.
        let updatedFlight: DragLandingFlight?
        switch current.kind {
        case .returnToSlot:
            var from = current.flight.from
            // Not yet airborne, but the anchor is on a different screen (when a window is dragged across screens and released, the anchor is reported by the other strip one turn later):
            // first switch the carrier panel and recompute the start point from the new panel's origin, same scheme as `plannedLanding`. No screen switch after takeoff.
            if !landingLaunched, let rect = landingAnchor?.rect,
               !carrierScreenFrame.contains(CGPoint(x: rect.midX, y: rect.midY)) {
                followScreenIfNeeded(CGPoint(x: rect.midX, y: rect.midY))
                placeCarrierUnderPointer()
                from = DragCarrierGeometry.topLeftCarriedCenter(pointer: globalLocation,
                                                                grabOffset: grabOffset,
                                                                panelFrame: carrierScreenFrame)
            }
            updatedFlight = DragLandingPlan.flight(from: from,
                                                   fromScale: current.flight.fromScale,
                                                   anchorScreenRect: landingAnchor?.rect,
                                                   carrierScreenFrame: carrierScreenFrame)
        case .stash:
            updatedFlight = DragLandingPlan.stashFlight(from: current.flight.from,
                                                        fromScale: current.flight.fromScale,
                                                        targetScreenRect: stashTargetProvider(),
                                                        carrierScreenFrame: carrierScreenFrame)
        }
        guard let updated = updatedFlight,
              hypot(updated.to.x - current.flight.to.x, updated.to.y - current.flight.to.y) > 0.5
        else { return }
        HoverTrace.landingRetarget(from: updated.from, to: updated.to, previous: current.flight.to)
        // Still in the hold period (`DragLandingPlan.landingSettle`): only change the destination, do not take off. This change is mostly
        // "the grid shifted by one slot after the drop was committed"; taking off immediately would mean flying toward the old slot and then being yanked back, and that kinked path is exactly what is being fixed.
        // Not yet airborne, so the whole flight (including the duration and curve computed from the new distance) can be replaced.
        guard landingLaunched else {
            current.flight = updated
            landing = current
            return
        }
        // Already flying: **only slide the destination along the original timeline; do not reissue a new curve.** The old approach was `flyCarrier(along: updated)`,
        // reissuing a whole segment, which restarts from the current position and eases to a stop every time; with the anchor drifting per frame over those 0.22s it reissued a dozen times,
        // which is the owner's 2026-09-03 report of "landing stutters". Flights that have finished are not changed again (left to finish).
        guard let timeline = flightTimeline,
              CACurrentMediaTime() - timeline.beganAt < timeline.duration else { return }
        let slid = current.flight.sliding(to: updated.to, toScale: updated.toScale)
        current.flight = slid
        landing = current
        slideLanding(to: slid, token: current.token)
    }

    /// Implementation of mid-flight correction: re-attach the translation / scale animations **with the original `beginTime`, duration and curve**,
    /// changing only the end value to the new destination. CA continues from the same curve's current progress, so the carrier slides along one continuous path to the new slot,
    /// and the moment the carrier is retired does not change either (the fallback timer is not rescheduled). The completion callback claims by generation: the callback of the replaced
    /// animation group fires immediately, and must not be allowed to end the flight (same as `flyCarrier`).
    private func slideLanding(to flight: DragLandingFlight, token: Int) {
        guard let layer = carrierLayer, let timeline = flightTimeline else { return }
        let destination = alignedCenter(
            DragCarrierGeometry.panelPoint(fromTopLeft: flight.to, panelFrame: carrierScreenFrame), on: layer)
        let toTransform = Self.scaleTransform(flight.toScale)
        landingAnimation &+= 1
        let generation = landingAnimation
        let c = timeline.curve
        let timing = CAMediaTimingFunction(controlPoints: Float(c.c0x), Float(c.c0y), Float(c.c1x), Float(c.c1y))
        let beginTime = layer.convertTime(timeline.beganAt, from: nil)
        CATransaction.begin()
        CATransaction.setDisableActions(true)   // The model value lands directly; the animation is handled by the two explicit animations below
        CATransaction.setCompletionBlock { [weak self] in
            Task { @MainActor in
                guard let self, self.landingAnimation == generation else { return }
                self.finishLanding(token: token)
            }
        }
        let tracks: [(String, Any, Any)] = [
            ("position", NSValue(point: timeline.start.position), NSValue(point: destination)),
            ("transform", NSValue(caTransform3D: Self.scaleTransform(timeline.start.scale)),
                          NSValue(caTransform3D: toTransform))
        ]
        for (keyPath, from, to) in tracks {
            let animation = CABasicAnimation(keyPath: keyPath)
            animation.fromValue = from
            animation.toValue = to
            animation.beginTime = beginTime
            animation.duration = timeline.duration
            animation.timingFunction = timing
            layer.add(animation, forKey: keyPath)
        }
        layer.position = destination
        layer.transform = toTransform
        CATransaction.commit()
        flightTimeline = FlightTimeline(beganAt: timeline.beganAt, start: timeline.start,
                                        destination: LayerPose(position: destination, scale: flight.toScale),
                                        duration: timeline.duration, curve: timeline.curve)
    }

    /// Fly to the destination. **First make the card on the strip visible, then retire the carrier one run loop turn later**: both ends are "new before old":
    /// the card is already on screen, and the carrier's last frame is pixel- and position-identical to it, so the overlapping frame is invisible;
    /// retiring the carrier first would inevitably expose a frame of empty slot (the other side of the owner's 2026-08-18 "landing ghost" report). Idempotent.
    func finishLanding(token: Int) {
        guard let current = landing, current.token == token else { return }
        let spanStart = HoverTrace.now(); defer { HoverTrace.span("finishLanding", since: spanStart) }
        landingTimer?.invalidate(); landingTimer = nil
        landingLaunchTask?.cancel(); landingLaunchTask = nil
        landingAnimation &+= 1
        endLandingGrabWatch()
        flightTimeline = nil
        recordLandingDelta()
        beginHoverHold(for: current.payload)   // Hold hover first, then let the card become visible; the reverse order makes it jitter
        landing = nil            // <- the strip / drawer makes the card visible in this turn's SwiftUI commit
        convertedChipID = nil    // The empty slot of the converted card is kept until here, released in the same turn as `landing`
        clearStripClaims()
        setStripSlotCollapsed(false)   // The card sucked into the capsule is a drawer member by now, so it is no longer on the strip
        lastKnownSlotAnchor = nil
        hideCarrierInSlotRevealCommit()
        retireCarrierAfterHandoff()
    }

    /// The copy's disappearance and the card's appearance must land in **the same** CA commit.
    ///
    /// The card's appearance is committed by SwiftUI together with the implicit transaction at the end of this run loop turn; if the carrier waits for the next turn to retire
    /// (`retireCarrierAfterHandoff`), then a single vsync between the two commits shows a frame of "card visible,
    /// still holding one in hand". Previously the appearance frame had to re-decode the icon (the `AppIconResolver` cache was perpetually invalid),
    /// which was slow by itself, and the card often had not been drawn yet when the copy was retired; after the 2026-09-04 cache fix the appearance became fast, while the next turn was often
    /// held up by a whole-strip recomputation for 25-30ms, and this frame went from occasional to common (owner reported the same day: "dragging from the drawer into the strip sometimes ghosts").
    ///
    /// So the assignment here **deliberately uses an implicit transaction**: it goes through the same end-of-turn commit as SwiftUI's appearance. It must not be wrapped in `instantly`:
    /// an explicit transaction with no enclosing implicit one is sent immediately, so the copy would disappear before the card, producing the reverse gap. Landing happens in a timer
    /// callback with no event flood, so the implicit transaction is guaranteed to flush this turn (the rule that "carrier changes must use explicit transactions" targets mid-drag).
    /// Implicit actions are disabled by `carrierActionGate` only for the duration of this one assignment; otherwise opacity would use the default 0.25s fade-out.
    private func hideCarrierInSlotRevealCommit() {
        guard let layer = carrierLayer else { return }
        carrierActionGate.suppressesImplicitActions = true
        layer.opacity = 0
        carrierActionGate.suppressesImplicitActions = false
    }

    /// Retire the carrier one run loop turn later, and keep suppressing hover during that turn (`carrierRetiring`).
    private func retireCarrierAfterHandoff() {
        carrierRetiring = true
        let generation = carrierGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Generation mismatch = the next turn has already started a new drag and the carrier belongs to it; but this flag was set by this turn,
            // so it must be cleared by this turn; leaving it would suppress the new drag's hover too (the first version avoided exposing this only because
            // `abortLanding()` in `beginDrag` happened to clear it).
            defer { self.carrierRetiring = false }
            guard self.carrierGeneration == generation else { return }
            self.retireCarrier()
        }
    }

    // MARK: - Landing flight is interruptible (owner 2026-08-19: "native and bestdock can both interrupt it; now it is a bit hard to select")

    /// Pressing on the icon during flight -> continue dragging from **its current** position, with the slot empty throughout and no flicker.
    ///
    /// The carrier is a bitmap on another panel and normally does not take events; without this, a press on the flying icon would fall through to what is underneath:
    /// either its empty card slot (`beginDrag` -> `abortLanding` -> the icon jumps from mid-air back to the slot and then lifts),
    /// or a neighbor (picking up the neighbor), or the desktop. The native Dock flies the icon itself, so pressing anywhere on it grabs it.
    ///
    /// - Parameter requireHit: `true` = the point must fall within the icon's current frame (a press received by the carrier panel itself);
    ///   `false` = the same card's slot was pressed (a SwiftUI gesture started a drag with the same payload), continue however far the icon is from the pointer,
    ///   and the grab offset is its current position relative to the pointer, same as native: the icon does not jump under the pointer.
    @discardableResult
    func regrabLanding(at screenPoint: CGPoint, requireHit: Bool = true) -> Bool {
        guard let current = landing, current.kind == .returnToSlot,
              let layer = carrierLayer, carrierScreenFrame.width > 0 else { return false }
        if requireHit {
            guard let iconFrame = landingIconScreenFrame(), iconFrame.contains(screenPoint) else { return false }
        }
        // Freeze at the position **computed from the timeline** (not `presentation()`, see `FlightTimeline` for the reason).
        let elapsedMs = flightTimeline.map { (CACurrentMediaTime() - $0.beganAt) * 1000 } ?? 0
        // Estimate slightly ahead (`grabFreezeLead`): in two frame-grab measurements the freeze point lagged the last on-screen frame by 2-3pt (about 0.25 frame).
        // Moving one or two pt further ahead looks like "moved once more and stopped", whereas stepping back is a visible jitter.
        let pose = landingPose(at: CACurrentMediaTime() + Self.grabFreezeLead)
            ?? LayerPose(position: layer.position, scale: Self.scale(of: layer.transform))
        landingTimer?.invalidate(); landingTimer = nil
        landingAnimation &+= 1          // CA completion callbacks are discarded by generation
        endLandingGrabWatch()
        Self.instantly {
            layer.removeAllAnimations()
            layer.position = self.alignedCenter(pose.position, on: layer)
            layer.transform = Self.scaleTransform(pose.scale)
            layer.opacity = 1
        }
        grabOffset = DragCarrierGeometry.grabOffset(pointer: screenPoint, carriedCenter: pose.position,
                                                    panelFrame: carrierScreenFrame)
        // Click vs. drag is only known on release: record the press point; while pressed the carrier shrinks slightly (same as the chip's press feedback),
        // moving past `regrabClickSlop` restores the held look (`update`), and not moving is a click (`endDrag`).
        regrabOrigin = screenPoint
        regrabPressed = ChipPressSwitches.pressDownEnabled
        // **Switch state within the same synchronous block**: both branches of `hiddenSlotPayload` point to the same card, so the slot stays empty continuously.
        let payload = current.payload
        draggingPayload = payload
        carrierArmed = true
        carrierLifted = true
        landing = nil
        carrierRetiring = false
        endHoverHold()
        dragBeganAt = CACurrentMediaTime()
        globalLocation = screenPoint
        pointerSubject.send(screenPoint)
        refreshDropZone()
        installMonitors()
        startPoll()
        flightTimeline = nil
        applyCarrierVisualState(animated: true)   // Scale 0.93 during the press-and-hold period
        HoverTrace.dragHandoff("regrab", msSinceBegin: elapsedMs)
        return true
    }
    /// Where the regrab press landed, and whether it is still in the "held without moving" state.
    private var regrabOrigin: CGPoint?
    private var regrabPressed = false

    /// The hit region of the flying icon (carrier panel coordinates): **the current frame ∪ the frame from two frames ago**; nil when not flying.
    ///
    /// People press according to the position they saw one or two frames earlier, and the press event takes another 10-20ms to reach us; in the early flight the icon moves a dozen pt per frame,
    /// so recognizing only the current frame would just graze past (2026-08-19 synthetic measurement: pressing the origin 46ms after release, the icon had moved 28pt,
    /// half-height 27pt, missed by 1pt). Adapts to speed: a longer tail when flying fast, almost no expansion in the slow final stretch.
    private func landingIconPanelFrame() -> CGRect? {
        guard let layer = carrierLayer else { return nil }
        let now = CACurrentMediaTime()
        guard let current = landingPose(at: now), let trailing = landingPose(at: now - Self.grabTrail) else { return nil }
        func frame(_ pose: LayerPose) -> CGRect {
            let size = CGSize(width: layer.bounds.width * pose.scale, height: layer.bounds.height * pose.scale)
            return CGRect(x: pose.position.x - size.width / 2, y: pose.position.y - size.height / 2,
                          width: size.width, height: size.height)
        }
        return frame(current).union(frame(trailing))
    }
    /// How far back the hit region traces (about two display frames).
    private static let grabTrail: CFTimeInterval = 0.034
    /// The lead applied to the regrab freeze point (about a quarter frame, see `regrabLanding` for the reason).
    private static let grabFreezeLead: CFTimeInterval = 0.005

    /// Same as above, in screen coordinates.
    private func landingIconScreenFrame() -> CGRect? {
        guard carrierScreenFrame.width > 0, let frame = landingIconPanelFrame() else { return nil }
        return frame.offsetBy(dx: carrierScreenFrame.minX, dy: carrierScreenFrame.minY)
    }

    /// During flight, check at 60Hz whether the pointer is over the icon: yes -> the carrier panel accepts events (a press is a regrab); no -> keep ignoring events as before.
    ///
    /// **Why it cannot accept events for the whole flight**: with `ignoresMouseEvents = false` on a transparent panel, clicks on transparent areas
    /// **do not** pass through to the windows below (2026-08-19 spike measurement: clicks in areas where `hitTest` returns nil are swallowed,
    /// and the window underneath never receives them), which would mean every click on another icon fails for 0.9s after landing. So it only accepts events during the frames in which the pointer
    /// is over the icon. Polling is the same as for the post-landing hover hold (`.common`, a result as soon as the pointer moves, the longest flight).
    private func beginLandingGrabWatch() {
        landingGrabTimer?.invalidate()
        refreshLandingGrabState()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else { timer.invalidate(); return }
                guard self.landing != nil else { timer.invalidate(); return }
                self.refreshLandingGrabState()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        landingGrabTimer = timer
    }

    private func endLandingGrabWatch() {
        landingGrabTimer?.invalidate(); landingGrabTimer = nil
        setCarrierAcceptsMouse(false)
    }

    private func refreshLandingGrabState() {
        let inside = landingIconScreenFrame()?.contains(NSEvent.mouseLocation) == true
        setCarrierAcceptsMouse(inside)
    }

    /// Only the current set of panels may accept events; the rest never do. Compare before writing so we do not send to WindowServer every frame.
    private func setCarrierAcceptsMouse(_ accepts: Bool) {
        for surface in surfaces {
            let ignores = !(accepts && surface.panel === carrierPanel)
            if surface.panel.ignoresMouseEvents != ignores { surface.panel.ignoresMouseEvents = ignores }
        }
    }
    private var landingGrabTimer: Timer?

    // MARK: - Hover hold after landing

    /// Hold hover from the moment of settling until the pointer actually moves (or a 3-second fallback).
    ///
    /// It polls `NSEvent.mouseLocation` at 60Hz rather than using an event monitor: none of this app's panels is the key window,
    /// so there is no guarantee that `.mouseMoved` reaches a local monitor (the strip's tracking area was changed to polling for exactly this reason, see
    /// `StripPointerTracker`), and a global `.mouseMoved` monitor is a resident event tap explicitly banned by AGENTS.
    /// The polling is transient: it stops as soon as the pointer moves, at most 3 seconds.
    private func beginHoverHold(for payload: DragPayload) {
        hoverHoldTimer?.invalidate()
        hoverHoldPayload = payload
        hoverHoldOrigin = NSEvent.mouseLocation
        hoverHoldStartedAt = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            Task { @MainActor in
                // If the controller is gone, stop itself: a `repeats: true` timer does not stop just because self is released.
                guard let self else { timer.invalidate(); return }
                guard self.hoverHoldPayload != nil else { timer.invalidate(); return }
                let now = NSEvent.mouseLocation
                let moved = hypot(now.x - self.hoverHoldOrigin.x, now.y - self.hoverHoldOrigin.y) > 0.5
                let expired = CACurrentMediaTime() - self.hoverHoldStartedAt > DragLandingPlan.hoverHoldMaximum
                if moved || expired { self.endHoverHold() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        hoverHoldTimer = timer
    }

    private func endHoverHold() {
        hoverHoldTimer?.invalidate(); hoverHoldTimer = nil
        if hoverHoldPayload != nil { hoverHoldPayload = nil }
    }

    /// Immediately retire the carrier bitmap and panel. **Call only when "the card is already visible" or "there is no card to make visible at all"**.
    private func retireCarrier() {
        let spanStart = HoverTrace.now(); defer { HoverTrace.span("retireCarrier", since: spanStart) }
        if let layer = carrierLayer {
            Self.instantly {
                layer.removeAllAnimations()
                layer.contents = nil
            }
        }
        carrierSnapshot = nil
        originSnapshot = nil
        // **The panel stays resident; no orderOut.** It is fully transparent, ignores the mouse, and sits one level above our own panels; ordering it out and
        // back in on every drag only buys timing pitfalls such as "a freshly ordered-in window's content reaches the screen a few frames late"
        // (measured 2026-08-19: same code, with the resident panel 6/6 drag starts had no gap and the carrier always appeared;
        // with repeated ordering, on several occasions the carrier never reached the screen for the entire drag). When idle it is only **moved off screen** (`carrierParked`).
        parkCarrierSurfaces()
    }

    /// End the flight immediately without handoff (interrupted by a new drag, abnormal cancel, panel teardown).
    /// On these paths the card slot may no longer exist, so retiring the carrier is not deferred.
    func abortLanding() {
        landingTimer?.invalidate(); landingTimer = nil
        landingLaunchTask?.cancel(); landingLaunchTask = nil
        landingAnimation &+= 1
        endLandingGrabWatch()
        flightTimeline = nil
        carrierRetiring = false
        convertedChipID = nil
        clearStripClaims()
        setStripSlotCollapsed(false)
        lastKnownSlotAnchor = nil
        guard landing != nil else { return }
        landing = nil
        retireCarrier()
    }

    /// The capsule highlight lights up only when "a strip card / messaging chip is hovering over the stash zone".
    /// The opposite direction has **no** symmetric whole-strip highlight: dragging a drawer icon back to the strip is expressed by cards making way (owner 2026-08-20, aligned with native).
    var isOverStashZone: Bool {
        guard isOverDropZone, let s = draggingPayload?.source else { return false }
        return s == .strip || s == .messaging
    }

    /// Cross-panel **temporary conversion** state: an explicit "original source + rollback snapshot", at most one conversion in progress at a time
    /// (Codex review 2026-07-11: no more stacked boolean flags). commit = `teardown()` clears state without rollback;
    /// rollback = each revert method restores from the snapshot; `cancelDrag()` rolls back according to the current case and then finishes.
    /// `@Published`: carrier switching, strip width freezing, and member-listener exemption all need to drive refresh.
    enum CrossPanelConversion {
        /// A strip card has been temporarily stashed into the drawer. Rollback = drawer.remove + restore the payload; kept is unchanged.
        case stripToDrawer(original: DragPayload)
        /// A drawer icon has been temporarily converted into the strip (unstash / keepPlacement). Rollback = drawer.add.
        case drawerToStrip(bundleID: String)
        /// A messaging-area chip has been temporarily stashed into the drawer. Rollback = drawer.remove + restore the `.messaging` payload.
        case messagingToDrawer(original: DragPayload)
        /// A running messaging app in the drawer has been temporarily released back to the messaging area. Rollback = drawer.add + restore the `.drawer` payload.
        case drawerToMessaging(original: DragPayload)

    }
    @Published private(set) var conversion: CrossPanelConversion?

    /// A projection compatible with existing call sites in the view layer (reads `conversion`; @Published guarantees refresh).
    var convertedDrawerBundleID: String? {
        if case let .drawerToStrip(bid) = conversion { return bid }
        return nil
    }
    var isConvertedToStrip: Bool { convertedDrawerBundleID != nil }
    var isConvertedFromStrip: Bool {
        if case .stripToDrawer = conversion { return true }
        return false
    }
    var isConvertedFromMessaging: Bool {
        if case .messagingToDrawer = conversion { return true }
        return false
    }
    var isReleasedToMessaging: Bool {
        if case .drawerToMessaging = conversion { return true }
        return false
    }

    /// The drawer member the conversion in flight added (`convertedInID`) or removed
    /// (`convertedOutID`); the drawer shapes its grid with that undone (`DrawerGridShape`).
    var drawerConversionDelta: (convertedInID: String?, convertedOutID: String?) {
        switch conversion {
        case .stripToDrawer, .messagingToDrawer: return (draggingPayload?.bundleID, nil)
        case let .drawerToStrip(bundleID): return (nil, bundleID)
        case let .drawerToMessaging(original): return (nil, original.bundleID)
        case nil: return (nil, nil)
        }
    }

    /// The **sole representative card** the carrier is redrawn as after conversion. Written by DockStripView after the window card is materialized (the first
    /// materialized **real window card** of that app in display order); nil before materialization (the carrier still draws the small drawer icon). Cleared by `revert`/`teardown`.
    @Published private(set) var convertedRepresentative: StripItem?

    /// **Which card on the strip to hide after conversion** (to free up the slot). Deliberately kept separate from the field above:
    ///
    /// the carrier can only draw a `StripItem`, while what gets materialized on the strip may be a `.keptApp` placeholder or an `isAppLevelFallback`
    /// fallback card; neither is something that "can be drawn as a window card", and `liveChipIDs` excludes them too.
    /// Earlier both jobs shared the single field `convertedRepresentative`, so on the `keepPlacement` path
    /// (a non-running kept app, or a running app with only an app-level fallback card) it was always nil, and **the card on the strip was drawn fully opaque
    /// while the same icon was still held in hand = two shadows** (reported by the owner 2026-08-18).
    /// So what is stored here is a chip id, not the card itself.
    @Published private(set) var convertedChipID: String?
    /// The "active strip surface" of the current drag (under multi-screen items 3 and 4 there are several strips with identical content, all subscribed to this controller,
    /// but only one may write back the drop anchor / reorder / convert -- otherwise the strip on another screen would report its own screen's rectangle as the drop point, causing
    /// the carrier flying to the wrong screen; see `DockStripView.ownsActiveDrag`). The strip where the drag began claims it before `beginDrag`;
    /// for drawer drags it is claimed at the moment of conversion by the strip under the pointer, and undoing the conversion releases it; cleared when landing ends or aborts.
    /// **Not `@Published`**: it changes only once at drag start and once at settle, not worth recomputing the whole strip.
    private(set) var activeStripSurfaceID: String?
    /// The strip where the drag began (nil for drawer drags). Criterion for a cross-screen drop = `activeStripSurfaceID != originStripSurfaceID` at release.
    private(set) var originStripSurfaceID: String?
    /// The screen pinned by the currently claiming strip (brought in by `claimStripSurface(_:displayUUID:)`), used to move the window on a cross-screen drop.
    private(set) var activeStripDisplayUUID: String?
    /// Incremented when the claim changes hands. `activeStripSurfaceID` is deliberately not `@Published`, but under item 4 the projection layer decides by claim
    /// which strip draws the dragged card (`DockStripView.makeProjection`), so a handoff must make each strip recompute once;
    /// a handoff happens only when the pointer crosses strips, not every frame.
    @Published private(set) var stripClaimGeneration = 0

    func claimStripSurface(_ id: String, displayUUID: String? = nil) {
        activeStripDisplayUUID = displayUUID
        guard activeStripSurfaceID != id else { return }
        // Handoff = the old strip's slot is meaningless to the new strip. If kept, releasing in an empty spot on screen B after a cross-screen drag would first fly toward A's old slot
        // (the carrier panel switches to screen A, the icon vanishes from screen B), and by the time B reports a real anchor it is already in the wrong panel coordinates (owner 2026-09-03).
        if activeStripSurfaceID != nil {
            lastKnownSlotAnchor = nil
            if landingAnchor?.owner == .strip { landingAnchor = nil }
        }
        activeStripSurfaceID = id
        stripClaimGeneration &+= 1
    }

    private func clearStripClaims() {
        activeStripSurfaceID = nil
        originStripSurfaceID = nil
        activeStripDisplayUUID = nil
    }

    /// **Close up as soon as it is dragged out** (owner 2026-09-03, aligned with native Dock; reverses 2026-08-20 "when taken off the strip, clamp the strip width"):
    /// once the card dragged from the strip (window card / placeholder / messaging chip / folder chip) leaves the strip (the pointer has clearly left the hit box of the strip currently
    /// claiming it, or it has already converted into the drawer body), the strip no longer reserves a gap for it and the panel shortens; as soon as the pointer re-enters any strip's hit box it is restored.
    /// Previously the gap was kept throughout and the strip width did not change, and the owner reported it as "unintuitive". `@Published`: the projection layer uses it to decide whether to draw that card
    /// (`DockStripView.makeProjection`), and `PanelCoordinator` uses it to re-lay-out the panel width.
    @Published private(set) var stripSlotCollapsed = false
    /// While closed up the strip cannot report a slot frame (the card is not in the layout). Releasing outside the strip and outside the drop zone must reopen the slot before flying;
    /// this is the temporary destination of that flight: the last slot that was reported. Once a slot frame is reported again, correction takes over and moves it to the real position.
    private var lastKnownSlotAnchor: CGRect?

    /// The pointer entered some strip's hit box (`DockStripView.updateStripPresence`, which runs before the owner gate).
    /// Only the box of the strip currently claiming is honored: the claim itself is determined by the screen under the pointer (`.strip` payloads cross screens, `claimStripSurface`);
    /// messaging / folder chips do not cross strips and the claim always stays with the strip where the drag began.
    func noteStripEntered(surfaceID: String, displayUUID: String?) {
        guard let p = draggingPayload, p.source != .drawer, conversion == nil,
              activeStripSurfaceID == surfaceID else { return }
        setStripSlotCollapsed(false)
    }

    /// The pointer has clearly left this strip's hit box. Only the departure of the strip currently claiming counts as "leaving the task strip" (the claim does not change hands because of it).
    func noteStripLeft(surfaceID: String) {
        guard let p = draggingPayload, p.source != .drawer, conversion == nil,
              activeStripSurfaceID == surfaceID else { return }
        setStripSlotCollapsed(true)
    }

    private func setStripSlotCollapsed(_ collapsed: Bool) {
        guard stripSlotCollapsed != collapsed else { return }
        stripSlotCollapsed = collapsed
    }

    func setConvertedRepresentative(_ item: StripItem?, chipID: String?) {
        if convertedRepresentative != item { convertedRepresentative = item }
        if convertedChipID != chipID {
            convertedChipID = chipID
            HoverTrace.carrierRepresentative(rep: item?.id, hidden: chipID)
        }
    }
    /// Callback on a successful release and settle (converted state); the composition layer receives it and calls `stripOrderStore.commitExternalBlock()`.
    /// The only place that receives mouseUp is `endDrag`, so commit must be triggered from there rather than inferred from DockStripView seeing payload become nil.
    var onDrawerToStripCommitted: ((String) -> Void)?
    /// Callback on abnormal cancel (cancelDrag) of a drawer-to-strip drag; the composition layer receives it and calls `stripOrderStore.cancelExternalBlock()`.
    /// Symmetric with onDrawerToStripCommitted: commit = settle clears the staging; cancel = undo clears the staging + boundIDs.
    var onDrawerToStripCancelled: (() -> Void)?
    /// Callback when a drawer icon is released into the strip (both the precise drop-point path and the fallback path trigger it).
    /// PanelCoordinator uses it to close the drawer; independent of onDrawerToStripCommitted, neither replaces the other.
    var onDrawerToStripCompleted: ((String) -> Void)?
    /// Called right before a capsule release adds the app to `drawerStore`: the order is written
    /// first, or `reconciled(members:)` shows the new member last for a frame.
    var onCapsuleStashWillAdd: ((String) -> Void)?
    /// Live drop-point classification for folder chip dragging: **computed and written by DockStripView** (only it has folderChipFrames/
    /// shelfFrame/stripRootScreenRect); the carrier view (DragCarrierView) only reads it to decide whether to fade out.
    /// The final mouseUp is still triggered by `endDrag()`, which reclassifies once with `folderDropGeometry`.
    @Published private(set) var folderDragZone: FolderChipDropZone?
    func setFolderDragZone(_ zone: FolderChipDropZone?) {
        guard folderDragZone != zone else { return }
        folderDragZone = zone
        applyCarrierVisualState(animated: true)   // Dragged out of the strip -> fade out + slightly enlarge
    }
    private var folderDropGeometry: FolderChipDropGeometry?
    func setFolderDropGeometry(_ geometry: FolderChipDropGeometry?) {
        if folderDropGeometry != geometry { folderDropGeometry = geometry }
    }
    /// A pinned-folder drag is released and settled. PanelCoordinator performs the store / Finder side effects; the controller only handles reliable wrap-up.
    var onFolderDragEnded: ((String, FolderChipDropZone) -> Void)?

    /// The drag's **original source**. Conversion flips `draggingPayload.source` (it becomes `.drawer` once inside the drawer body),
    /// so "was this drag brought in from outside the drawer" can only be judged from this. The sole authority is the rollback snapshot inside `conversion`
    /// -- **no parallel field is added** (see the `CrossPanelConversion` comment: no more stacked boolean flags).
    private var originSource: DragSource? {
        guard let payload = draggingPayload else { return nil }
        switch conversion {
        case let .stripToDrawer(original),
             let .messagingToDrawer(original),
             let .drawerToMessaging(original):
            return original.source
        case .drawerToStrip:
            return .drawer
        case nil:
            return payload.source
        }
    }

    private let drawerStore: DrawerStore
    private let messagingStore: MessagingAppStore
    /// The only write entry for kept: re-checking after a stash settles goes through it; `DragController` itself does not hold `KeptAppStore`.
    private let membershipController: AppMembershipController
    /// Provides drop candidate regions by source (screen coordinates, already inset + tolerance): strip/messaging -> capsule (+drawer); drawer -> the strip dock panel.
    private let dropZonesProvider: (DragSource) -> [CGRect]
    /// **All** screens. One set of carrier panels per screen (see `CarrierSurface`), switched according to the screen under the pointer.
    private let screensProvider: () -> [NSScreen]
    /// The capsule's visible frame (screen coordinates): when a strip card / messaging chip is released on the capsule to stash, the icon is sucked into here. `nil` = no flight.
    private let stashTargetProvider: () -> CGRect?

    /// One set per screen (panel + container view + bitmap layer). **Why not a single panel following the pointer**: when a window is `setFrame`d
    /// onto another display, WindowServer needs a frame or two to rebuild it on the new screen, and the carrier just lit up in those frames
    /// is invisible (measured 2026-08-19: if the panel last stayed on another screen, this drag start showed a 2-frame gap). Keeping one set resident per screen
    /// and switching by the pointer's screen means there is no migration at all.
    private struct CarrierSurface {
        let panel: NSPanel
        let container: CarrierContainerView
        let layer: CALayer
        let frame: CGRect
    }
    private var surfaces: [CarrierSurface] = []
    /// **Idle carrier panels are parked off every display; they are never ordered out.**
    ///
    /// The panels are resident (see `retireCarrier`), transparent and mouse-transparent, yet as
    /// full-screen windows at `PanelLevel.carrier` they head the on-screen window list. Third-party
    /// window managers that resolve "which window is under the pointer" from
    /// `CGWindowListCopyWindowInfo` (Rectangle 1.100 takes the first window with level < 21 whose
    /// bounds contain the pointer, alpha not consulted) picked our carrier for every mouse-down and
    /// never saw the real window move, so drag-to-snap was dead while the taskbar ran (two user
    /// reports, 0.11.2 / 0.11.5). Moving the frame keeps the backing surface and the ordering; only
    /// order-in/out was measured to lose frames (`retireCarrier`). Starts parked so panels built by
    /// `prewarmCarrier` are off-screen from birth; `ensureCarrierPanel` wakes them for a drag.
    private var carrierParked = true
    private static let parkedCarrierOrigin = CGPoint(x: -100_000, y: -100_000)
    /// The carrier layer's delegate; it does exactly one thing: disable implicit actions during the one assignment in `hideCarrierInSlotRevealCommit`.
    /// It does not use `layer.actions = [...NSNull]` (which would also kill the landing flight's implicit animations, see `makeCarrierPanel`),
    /// nor `instantly` (an explicit transaction **is sent immediately** when there is no enclosing implicit transaction, which is exactly what must be avoided here).
    private final class CarrierLayerActionGate: NSObject, CALayerDelegate {
        var suppressesImplicitActions = false
        func action(for layer: CALayer, forKey event: String) -> CAAction? {
            suppressesImplicitActions ? NSNull() : nil   // nil = hand back to the default lookup, no interference normally
        }
    }
    private let carrierActionGate = CarrierLayerActionGate()
    private var activeSurface: CarrierSurface?
    /// After the carrier panel is built and ordered front, it is handed to the orchestration layer to be pinned into the **private space the strip lives in** (`OverlaySpaceHost`).
    /// Once the strip is pinned in a private space, windows left in the desktop space are composited beneath it regardless of `level`; the carrier looked semi-transparent as soon as it was pressed onto the glass backing,
    /// and darkened as it approached the capsule (owner 2026-09-03, confirmed by `DOCK_OVERLAY_SPACE=0` A/B).
    /// On assignment, the sets already built are pinned as well (`prewarmCarrier` may run before the wiring).
    var pinCarrierWindows: (([Int]) -> Void)? {
        didSet { pinCarrierWindows?(surfaces.map { $0.panel.windowNumber }) }
    }
    private var carrierPanel: NSPanel? { activeSurface?.panel }
    private var carrierContainer: CarrierContainerView? { activeSurface?.container }
    /// The layer holding the carrier bitmap. **Position / scale / shadow / opacity are all its CA properties**,
    /// decided synchronously by this controller in the same run loop turn as the mouse event, without going through SwiftUI, so there is no handoff race.
    private var carrierLayer: CALayer? { activeSurface?.layer }
    /// The current bitmap. If the card's appearance changes before landing, retake it (see `setCarrierSnapshot`).
    private var carrierSnapshot: CarrierSnapshot?
    /// The one taken at drag start. When a drawer icon is converted into the strip it is temporarily replaced with the representative card's image, and restored on rollback.
    private var originSnapshot: CarrierSnapshot?
    /// Incremented each time the carrier goes on screen. The "retire one turn later" async claims by it; otherwise, if the next turn has already started a new drag,
    /// it would wipe out the new carrier's bitmap too.
    private var carrierGeneration = 0

    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var pollTimer: Timer?

    init(drawerStore: DrawerStore,
         messagingStore: MessagingAppStore,
         membershipController: AppMembershipController,
         dropZonesProvider: @escaping (DragSource) -> [CGRect],
         screensProvider: @escaping () -> [NSScreen],
         stashTargetProvider: @escaping () -> CGRect? = { nil }) {
        self.pointerMoves = pointerSubject.eraseToAnyPublisher()
        self.carrierClicks = carrierClickSubject.eraseToAnyPublisher()
        self.capsuleStashes = capsuleStashSubject.eraseToAnyPublisher()
        self.drawerStore = drawerStore
        self.messagingStore = messagingStore
        self.membershipController = membershipController
        self.dropZonesProvider = dropZonesProvider
        self.screensProvider = screensProvider
        self.stashTargetProvider = stashTargetProvider
    }

    // MARK: - Drag start

    /// The carrier prepared at press time: bitmap already attached to the layer and texture already uploaded (see `prepareCandidate`).
    private struct Candidate {
        let payloadID: String
        let snapshot: CarrierSnapshot
        let sourceScreenRect: CGRect
        let preparedAt: CFTimeInterval
    }
    /// How long a candidate counts as fresh: when SwiftUI cancels the gesture `clearCandidate` is not called, and the candidate lingers until the next press;
    /// pressing the same card again reuses it if still fresh (saves one snapshot), otherwise retakes it since the card's appearance may have changed.
    private static let candidateFreshness: CFTimeInterval = 2
    private var candidate: Candidate?
    /// The step of "wait two display frames, then hide the card + lift" when there is no candidate.
    private var armTask: DispatchWorkItem?

    /// **Prepare on press**: at the moment of mouse-down, attach this card's bitmap to the carrier layer and put it on screen once at an invisible opacity,
    /// paying the texture-upload cost up front. When the drag really starts (>= 8pt), `beginDrag` only needs to light it up +
    /// position it, in the **same turn and same commit** as `draggingPayload = payload` (hiding the card), so both land in the same frame
    /// and the lift can happen in the drag-start turn, with no need to "hold it in place for a turn first".
    ///
    /// Opacity is 0.01 rather than 0: a fully transparent layer is culled from the render tree and the texture is never uploaded, making the warm-up pointless;
    /// 0.01 is invisible to the eye (under 3/255 brightness on a dark backing) but really goes through the upload.
    /// One click costs about 0.6ms of snapshot plus one transparent panel order front, which is acceptable.
    /// Released without a drag -> `clearCandidate`. A candidate is claimed by `payloadID`; on a mismatch it falls back to the no-candidate path.
    func prepareCandidate(payloadID: String, sourceScreenRect: CGRect,
                          snapshot: @autoclosure () -> CarrierSnapshot?) {
        guard draggingPayload == nil, landing == nil,
              sourceScreenRect.width > 0, sourceScreenRect.height > 0 else { return }
        // Idempotent: a gesture with `minimumDistance: 0` held down keeps firing `onChanged`, so prepare only once per press.
        if let current = candidate, current.payloadID == payloadID,
           CACurrentMediaTime() - current.preparedAt < Self.candidateFreshness {
            return
        }
        guard let snapshot = snapshot() else { return }
        candidate = Candidate(payloadID: payloadID, snapshot: snapshot,
                              sourceScreenRect: sourceScreenRect, preparedAt: CACurrentMediaTime())
        let frame = ensureCarrierPanel(for: CGPoint(x: sourceScreenRect.midX, y: sourceScreenRect.midY))
        guard let layer = carrierLayer, let panel = carrierPanel else { return }
        carrierGeneration &+= 1
        Self.instantly {
            layer.removeAllAnimations()
            self.apply(snapshot, to: layer)
            layer.position = self.alignedCenter(
                DragCarrierGeometry.panelCenter(ofScreenRect: sourceScreenRect, panelFrame: frame), on: layer)
            layer.transform = CATransform3DIdentity
            layer.opacity = DragLandingPlan.candidateOpacity
        }
        orderCarrierFrontIfNeeded(panel)
        HoverTrace.dragHandoff("candidatePrepared", msSinceBegin: 0)
    }

    /// The press did not turn into a drag (released / gesture cancelled) -> discard the candidate. **Leave it alone while a drag is in progress**: by then the candidate has been
    /// claimed by `beginDrag` and the carrier is in hand.
    func clearCandidate(payloadID: String) {
        guard draggingPayload == nil, landing == nil, !carrierRetiring,
              candidate?.payloadID == payloadID else { return }
        candidate = nil
        retireCarrier()
    }

    /// - Parameters:
    ///   - sourceScreenRect: the slot this card **currently occupies on screen** (screen coordinates). The carrier first appears here at the slot's
    ///     original size, then lifts to under the pointer. **It cannot be derived back from `grabOffset`**: `grabOffset` is measured relative to the gesture start
    ///     `value.startLocation`, while `startScreenLocation` is the position at the moment `minimumDistance: 8` fired,
    ///     so they naturally differ by 8pt or more, and those 8pt are exactly the jump in the owner's "first frame stutters" report.
    ///   - pose: the slot's **current** form (composite scale and offset from hover x press). The carrier's first frame is posed with it,
    ///     so it coincides pixel for pixel with the slot; see `DragCarrierGeometry.pickUpPose`.
    ///   - snapshot: a bitmap of the same view as the slot (taken by the view that renders the slot itself, see `ChipSnapshotter`).
    ///     **An autoclosure**: if a candidate was already prepared at press time (`prepareCandidate`), no further snapshot is taken here.
    ///     If neither side can produce one, the drag does not start: with no bitmap there is nothing to hold, and forcing the drag would just make the icon vanish.
    /// - Parameter stripSurfaceID: the surface identity of the strip where the drag began (`activeStripSurfaceID`); pass nil for drawer drags.
    func beginDrag(payload: DragPayload,
                   stripSurfaceID: String? = nil,
                   startScreenLocation: CGPoint,
                   grabOffset: CGSize,
                   sourceScreenRect: CGRect,
                   pose: DragCarrierGeometry.PickUpPose,
                   snapshot: @autoclosure () -> CarrierSnapshot?) {
        guard draggingPayload == nil else { return }
        // The same card is still in its landing flight -> continue dragging from the icon's current position, avoiding the jump of "instant retire + re-lift from the slot"
        // (see `regrabLanding`). On the strip this path is normally unreachable (an empty slot has opacity 0 and SwiftUI does not give it
        // hit-testing, measured synthetically); it is kept as a guardrail: if some panel / OS version does deliver it, it must continue the drag rather than jump.
        if let current = landing, current.payload.id == payload.id,
           regrabLanding(at: startScreenLocation, requireHit: false) {
            return
        }
        let prepared = candidate.flatMap { $0.payloadID == payload.id ? $0 : nil }
        candidate = nil
        guard let image = prepared?.snapshot ?? snapshot() else {
            HoverTrace.dragHandoff("noSnapshot", msSinceBegin: 0)
            retireCarrier()
            return
        }
        // If the previous landing is still flying, retire it immediately (**no deferred handoff**: that is for normal landings).
        abortLanding()
        endHoverHold()
        activeStripSurfaceID = stripSurfaceID   // Placed after abortLanding: aborting the previous flight clears the claim
        originStripSurfaceID = stripSurfaceID
        activeStripDisplayUUID = nil
        let started = CACurrentMediaTime()
        dragBeganAt = started
        let hadCarrier = carrierPanel != nil
        carrierArmed = false
        carrierLifted = false
        liftTimer?.invalidate(); liftTimer = nil
        armTask?.cancel(); armTask = nil
        self.grabOffset = grabOffset
        globalLocation = startScreenLocation
        pointerSubject.send(startScreenLocation)
        // **Place the carrier at the slot's original position first, then publish the payload**: at this moment the bitmap sits over that card in the slot's current pose,
        // so even if the card is hidden a frame later it cannot be noticed, and no gap can appear.
        let beforeCarrier = CACurrentMediaTime()
        // The slot frame is whatever was measured at the moment of drag start (the strip may have reordered between press and drag start); the one from prepare time is used only if none can be measured.
        let slotRect = sourceScreenRect.width > 0 && sourceScreenRect.height > 0
            ? sourceScreenRect : (prepared?.sourceScreenRect ?? sourceScreenRect)
        presentCarrier(snapshot: image, at: slotRect, pose: pose)
        let afterCarrier = CACurrentMediaTime()
        draggingPayload = payload
        refreshDropZone()
        installMonitors()
        startPoll()
        if prepared != nil {
            // The texture is already on the GPU: light up and hide the card in the same commit, and lift in that same turn.
            armCarrier()
        } else {
            // Not warmed up: hold over the card for two display frames first (reason in `carrierArmed`), then hide the card + lift.
            let task = DispatchWorkItem { [weak self] in
                guard let self, self.draggingPayload != nil, !self.carrierArmed else { return }
                self.armCarrier()
            }
            armTask = task
            DispatchQueue.main.asyncAfter(deadline: .now() + DragLandingPlan.pickUpSettle, execute: task)
        }
        HoverTrace.dragStart(totalMs: (CACurrentMediaTime() - started) * 1000,
                             carrierMs: (afterCarrier - beforeCarrier) * 1000,
                             carrierCreated: !hadCarrier,
                             prepared: prepared != nil)
    }

    /// Hide the card (this turn) + lift (after `DragLandingPlan.liftDelay`). Idempotent.
    ///
    /// **Why lifting waits a little longer**: carrier changes use an explicit transaction and `commit` reaches WindowServer on the spot;
    /// whereas "hiding" the card on the strip is a SwiftUI update, committed only in AppKit's display cycle for this turn. When the main thread is busy
    /// (high-frequency mouse events, reordering), the two can differ by one or two display frames; if the carrier has already left the slot toward the pointer during that time,
    /// the screen shows two icons: "the card is still there, the copy has already flown out a bit" (measured in a 1000Hz synthetic-drag screen recording:
    /// leaving in the drag-start turn first showed a 2-frame vertically offset double image, and only then was the card hidden). The carrier first stays at the slot's original position, held still in the slot's current
    /// pose for two frames, so the hide-card commit always arrives first; during those two overlapping frames the two are pixel-identical and unnoticeable.
    private func armCarrier() {
        guard draggingPayload != nil, !carrierArmed else { return }
        armTask?.cancel(); armTask = nil
        carrierArmed = true
        HoverTrace.dragHandoff("slotHidden", msSinceBegin: (CACurrentMediaTime() - dragBeganAt) * 1000)
        liftTimer?.invalidate()
        let timer = Timer(timeInterval: DragLandingPlan.liftDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.draggingPayload != nil, self.carrierArmed, !self.carrierLifted else { return }
                self.liftCarrier()
            }
        }
        RunLoop.main.add(timer, forMode: .common)   // Timers during a drag must be .common (AGENTS)
        liftTimer = timer
    }
    private var liftTimer: Timer?
    /// The lift has started (the carrier follows the hand from this moment).
    private(set) var carrierLifted = false

    // MARK: - Strip card into the drawer body -> converted to an in-drawer drag (unified feel, owner 2026-06-22)

    /// A strip card dragged into the **open drawer body** -> instantly "converted" into a drawer member, with the source changed to `.drawer`. After that it follows the in-drawer
    /// reorder path entirely (global mouse driven, no placeholder gap, no repeated panel scaling), completely bypassing the old "placeholder + panel scaling" mechanism.
    /// **Reversible**: conversion is only a temporary insert (pushing others aside = preview); dragging the card out of the drawer body -> `revertStripFromDrawer` undoes and restores;
    /// only the moment of releasing inside the drawer counts as settled (owner 2026-06-22: reopening the drawer must show the original state, not one that was pushed around).
    /// `guard source==.strip && conversion==nil` guarantees idempotence (no retrigger after one conversion).
    func convertStripToDrawer() {
        guard let p = draggingPayload, p.source == .strip, p.canExternalDrop, conversion == nil else { return }
        conversion = .stripToDrawer(original: p)  // Set first: flip the payload first, then touch the store (the member-disappearance listener exempts by source)
        draggingPayload = DragPayload(source: .drawer, id: p.bundleID, bundleID: p.bundleID,
                                      item: p.item, visualKind: p.visualKind, canExternalDrop: true)
        setStripSlotCollapsed(true)               // Entering the drawer body = leaving the strip (after an undo, the strip's hit box decides when it is restored)
        drawerStore.add(p.bundleID)
        refreshDropZone()   // The set of drop zones changes with the source; recompute
    }

    /// Undo conversion: the card is dragged out of the drawer body -> removed from drawer members (the drawer shrinks back, other icons return to place), source restored to a strip card.
    /// Dragging into the drawer body again will `convertStripToDrawer` anew, so that "reopening the drawer = the original state".
    /// Clear the conversion state and restore the payload first, **then** touch the store: the member listener exempts by the new payload's source, so there is no cancel race (review P1-2).
    func revertStripFromDrawer() {
        guard case let .stripToDrawer(original) = conversion, draggingPayload?.source == .drawer else { return }
        conversion = nil    // Unfreeze + trigger relayout (dragging out of the drawer restores it -> the strip returns to its original width)
        draggingPayload = original
        drawerStore.remove(original.bundleID)
        refreshDropZone()
    }

    // MARK: - Messaging-area chip into the drawer body -> stash preview / restore on drag-out (same feel as strip cards)

    /// A messaging-area chip dragged into the **open drawer body** -> temporarily stashed as a drawer member, with the source flipped to `.drawer` (afterwards the in-drawer reorder
    /// machinery is fully reused). **The messaging flag is untouched**: moving into the drawer is only a projection hide, consistent with existing stash semantics.
    /// Set the conversion state first, flip the payload before `drawer.add`: the messaging-area listener exempts by source, so it does not misread "chip disappeared from the area" (review P1-2/P2-5).
    func convertMessagingToDrawer() {
        guard let p = draggingPayload, p.source == .messaging, p.canExternalDrop, conversion == nil else { return }
        conversion = .messagingToDrawer(original: p)
        draggingPayload = DragPayload(source: .drawer, id: p.bundleID, bundleID: p.bundleID,
                                      item: nil, visualKind: .drawerIcon, canExternalDrop: true)
        setStripSlotCollapsed(true)               // Same as convertStripToDrawer
        drawerStore.add(p.bundleID)
        refreshDropZone()
    }

    /// Undo the stash preview: dragged out of the drawer body -> removed from drawer members, payload restored to `.messaging` (the chip returns to its original place in the messaging area).
    func revertMessagingFromDrawer() {
        guard case let .messagingToDrawer(original) = conversion, draggingPayload?.source == .drawer else { return }
        conversion = nil
        draggingPayload = original
        drawerStore.remove(original.bundleID)
        refreshDropZone()
    }

    // MARK: - Drawer icon dragged into the strip area -> converted into a strip window card / restored on drag-out (drawer dragged back to strip, precise drop point, 2026-06-22)

    /// A drawer icon dragged into the **strip panel area** -> instantly "converted": `drawerStore.remove(bid)`, and that app's window card enters the live area right away.
    /// Drop-point ordering (staging + placement inside sync) belongs to DockStripView; this method only handles the membership change + recording the bundleID. **It does not flip source**: keeping
    /// `.drawer` lets the `.drawer` branch of `endDrag` and the owner attribution of the drop anchor continue to hold. `guard` keeps it idempotent.
    func convertDrawerToStrip() {
        guard let p = draggingPayload, p.source == .drawer, p.canExternalDrop, conversion == nil else { return }
        conversion = .drawerToStrip(bundleID: p.bundleID)  // Set first (freeze the width), then touch drawerStore
        drawerStore.remove(p.bundleID)
        applyCarrierVisualState(animated: true)   // After conversion it no longer shrinks to 0.82; it keeps the normal held-in-hand size
    }

    /// Undo conversion: dragged out of the strip area -> `drawerStore.add(bid)` restores the placement; kept is always unchanged.
    /// Undo at the ordering layer (delete boundIDs + clear absentSince) is done by DockStripView calling `cancelExternalBlock` **before** this method.
    func revertDrawerToStrip() {
        guard case let .drawerToStrip(bid) = conversion else { return }
        drawerStore.add(bid)
        conversion = nil
        convertedRepresentative = nil   // The carrier returns to the small drawer icon
        convertedChipID = nil           // No card on the strip needs to make way anymore
        activeStripSurfaceID = nil      // Release the claim: after dragging back to the drawer area, any strip may do the conversion
        applyCarrierVisualState(animated: true)
    }

    // MARK: - Messaging app in the drawer dragged into the messaging-area range -> temporarily released back to the messaging area / restored on leaving the area (review P1-3)

    /// A **running messaging app** dragged from the drawer enters the messaging-area range -> temporary release: the payload flips to `.messaging` (in-area reorder and
    /// the stash preview on re-entering the drawer all reuse the generic logic), then `drawer.remove` (the projection immediately returns the chip to its original order slot in the messaging area).
    /// The trigger range is decided by DockStripView from the messaging-area frame, and is **not** "release as soon as it leaves the drawer body".
    func convertDrawerToMessaging() {
        guard let p = draggingPayload, p.source == .drawer, p.canExternalDrop, conversion == nil else { return }
        conversion = .drawerToMessaging(original: p)
        draggingPayload = DragPayload(source: .messaging, id: p.bundleID, bundleID: p.bundleID,
                                      item: nil, visualKind: .messagingIcon, canExternalDrop: true)
        drawerStore.remove(p.bundleID)
        refreshDropZone()
    }

    /// Undo the release: leaving the messaging-area range (or entering a drop zone) -> taken back into the drawer, payload restored to `.drawer`.
    func revertDrawerToMessaging() {
        guard case let .drawerToMessaging(original) = conversion, draggingPayload?.source == .messaging else { return }
        conversion = nil
        draggingPayload = original
        drawerStore.add(original.bundleID)
        activeStripSurfaceID = nil      // Release the claim (same as revertDrawerToStrip): re-entering the messaging area of any strip can release again
        refreshDropZone()
    }

    // MARK: - Following the hand / drop point

    private func update(_ loc: CGPoint) {
        globalLocation = loc
        // **Position synchronously, as the very first thing**: this is the whole of hand-following. The old SwiftUI route needs a pass through the render pipeline every frame,
        // and dragged fast the copy trails the cursor by over a hundred pt (owner's 2026-08-18 burst-capture evidence).
        followScreenIfNeeded(loc)
        moveCarrier()
        if regrabPressed, let origin = regrabOrigin,
           hypot(loc.x - origin.x, loc.y - origin.y) > DragLandingPlan.regrabClickSlop {
            regrabPressed = false                    // Moved past the threshold = a drag: return to the held look (equivalent to lifting)
            applyCarrierVisualState(animated: true)
        }
        refreshDropZone()
        pointerSubject.send(loc)    // Side-effect subscribers (strip / drawer); no view dependency is created
        auditCarrierVisibility()
    }

    /// A self-check on every cursor update: **the slot on the strip is already empty; is the copy really on screen?**
    /// If the two do not hold at the same time, what the user sees is "the icon disappeared". The owner reported "it occasionally disappears" three rounds in a row,
    /// and screenshots could only guess; this turns it into a fact that can be counted in the log.
    ///
    /// The opposite direction (copy on screen while the slot on the strip is still occupied = ghosting) **no longer needs checking**: drag start has no gating anymore,
    /// the timing of the two is guaranteed by the same run loop turn, and the degree of freedom of "which comes first" does not exist.
    private func auditCarrierVisibility() {
        guard HoverTrace.isEnabled, carriedPayload != nil,
              let panel = carrierPanel, let layer = carrierLayer else { return }
        let onScreen = panel.isVisible && panel.alphaValue > 0.99
        let drawn = layer.contents != nil && layer.opacity > 0.01
        // The bitmap center must really fall inside the panel (= the union of all screens), with 24pt of extra tolerance.
        let inFrame = CGRect(origin: .zero, size: carrierScreenFrame.size)
            .insetBy(dx: -24, dy: -24).contains(layer.position)
        guard !onScreen || !drawn || !inFrame else { return }
        let reason = !panel.isVisible ? "panelHidden"
            : (panel.alphaValue <= 0.99 ? "panelFaded"
               : (!drawn ? "emptyContent" : "iconOffscreen"))
        HoverTrace.carrierGap(reason: reason, alpha: panel.alphaValue,
                              hostX: layer.position.x, hostY: layer.position.y)
    }

    /// **Write only when the conclusion really changes**: `@Published` notifies on every assignment and does not compare old values.
    /// Writing on every mouse movement would invalidate the whole strip on every mouse movement (same as the `globalLocation` case).
    private func refreshDropZone() {
        let next: Bool = {
            guard let p = draggingPayload, p.canExternalDrop else { return false }
            return dropZonesProvider(p.source).contains { $0.contains(globalLocation) }
        }()
        guard isOverDropZone != next else { return }
        isOverDropZone = next
        applyCarrierVisualState(animated: true)   // Entering / leaving the drop zone -> 0.82 <-> normal
    }

    // MARK: - Wrap-up (idempotent, clear first then commit)

    /// Normal release: inside the drop zone -> stash / move back by source; otherwise do nothing (in-zone reordering was already committed live during the drag).
    /// The wrap-up decisions for `.messaging`/`.drawer` go through the pure logic `DragConversionPlan.endAction` (covered by unit tests).
    func endDrag() {
        guard let p = draggingPayload else { return }
        let spanStart = HoverTrace.now(); defer { HoverTrace.span("endDrag", since: spanStart) }
        // Regrabbed during flight and released without moving = **a click on this card**: the icon still flies back to its slot as usual (no stash, nothing settled),
        // and then "it was clicked" is handed to the panel that owns it to do the wake / minimize (owner 2026-08-19: clicking it before it lands did nothing).
        if let origin = regrabOrigin,
           hypot(globalLocation.x - origin.x, globalLocation.y - origin.y) < DragLandingPlan.regrabClickSlop {
            let folderZone = folderDropGeometry?.classify(screenPoint: globalLocation) ?? .folderZone
            teardown(landing: plannedLanding(for: p, folderZone: folderZone, allowStash: false))
            HoverTrace.dragHandoff("click", msSinceBegin: 0)
            carrierClickSubject.send(p)
            return
        }
        let external = isOverDropZone
        let converted = isConvertedToStrip
        let convertedBid = convertedDrawerBundleID
        let origin = originSource ?? p.source   // Must be read before teardown() clears conversion
        let finalLocation = globalLocation
        let folderZone = folderDropGeometry?.classify(screenPoint: finalLocation) ?? .folderZone
        let action = DragConversionPlan.endAction(source: p.source,
                                                  isConvertedToStrip: converted,
                                                  isOverDropZone: external,
                                                  isMessagingMember: messagingStore.contains(p.bundleID))
        // Cross-screen drop (multi-screen items 3 and 4): at release the claim is on a **different** strip (that strip took over as soon as the pointer hovered over it:
        // the empty slot, reordering and drop anchor are all its) -> the flight goes as usual toward the slot it reports, and the window moves to that screen.
        let crossStripDisplayUUID = crossStripDropDisplayUUID(for: p, external: external)
        if crossStripDisplayUUID != nil {
            HoverTrace.dragHandoff("crossStrip", msSinceBegin: (CACurrentMediaTime() - dragBeganAt) * 1000)
        }
        // The card is still outside the strip (the gap has closed up) and will not be stashed -> reopen the slot first (in the same synchronous block, the strip lengthens right away), and the flight first heads to
        // the last known slot (`plannedLanding`); once a slot frame is reported, correction takes over and moves it to the real position.
        // Releasing a folder chip outside the strip = unpin, no reopening.
        if stripSlotCollapsed, p.source != .folder, !willStash(p) { setStripSlotCollapsed(false) }
        teardown(landing: plannedLanding(for: p, folderZone: folderZone))
        if let crossStripDisplayUUID {
            onCrossStripDrop?(p, crossStripDisplayUUID)
        }
        switch p.source {
        case .folder:
            onFolderDragEnded?(p.id, folderZone)
        case .strip:
            // A card that entered the drawer body has been converted to .drawer by convertStripToDrawer (dropped inside = already a member, does not come here).
            // This branch = a card that did not enter the drawer body: released in the drop zone (capsule) -> change the drawer placement.
            // kept is not changed here; the four entry paths share the unified criterion after the switch.
            if external {
                stashOntoCapsule(p.bundleID)
            }
        case .messaging:
            // A messaging-area drag that was not converted (after conversion the source is already .drawer), or a drawer drag that was released back to the messaging area (drawer.remove
            // already happened, so releasing settles it). Drop zone (capsule) -> stash; any other position -> leave in place (in-area reordering was already committed live).
            if action == .stashMessagingChip {
                stashOntoCapsule(p.bundleID)
            }
        case .drawer:
            switch action {
            case .commitDrawerToStrip:
                // Already converted into the strip (member removed, window card placed) -> treated as settled, no longer touching members based on external.
                // The undo already happened live when leaving the area; here we only notify the ordering layer to commit (clear the staging tracking).
                let bid = convertedBid ?? p.bundleID
                onDrawerToStripCommitted?(bid)
                onDrawerToStripCompleted?(bid)
            case .fallbackUnstash:
                // Not converted (not running / app-fallback): dropped on the strip -> move back. Messaging members never take this branch --
                // their only path back to the strip is the temporary release in the messaging-area range (review P1-3); released anywhere else they stay in the drawer.
                drawerStore.remove(p.bundleID)
                onDrawerToStripCompleted?(p.bundleID)
            case .none, .stashMessagingChip:
                break
            }
        }

        // After a stash settles -> turn on "Keep in Dock" (owner 2026-08-06). Placed **after** the switch:
        // by now drawerStore holds the final membership, and the four entry paths (strip/messaging chip x drawer body/capsule)
        // share one criterion, which also naturally excludes in-drawer reordering, conversion into the strip, and fallback removal, which must not turn it on.
        // Semantics (only on, never off; re-enabled on every drag-in) are in DragConversionPlan.enablesKeptOnDrop;
        // the execution point is AppMembershipController.applyDragLanding (the single mutation boundary for kept).
        membershipController.applyDragLanding(bundleID: p.bundleID, originSource: origin)
    }

    /// Capsule release lands at the front of the drawer, as a Finder drop does (`Docs/27`).
    private func stashOntoCapsule(_ bundleID: String) {
        onCapsuleStashWillAdd?(bundleID)
        drawerStore.add(bundleID)
        capsuleStashSubject.send(bundleID)
    }

    /// Cancel: abnormal paths such as the target disappearing mid-drag or a screen change. First roll back the store changes that already happened according to the current conversion state
    /// (same path as each "restore on drag-out"), then wrap up, so every temporary state restores the original membership.
    func cancelDrag() {
        // During the landing flight `draggingPayload` is already nil, but the carrier panel is still open; screen changes / panel teardown
        // and such paths all come through here, and without retiring it first a semi-transparent full-screen carrier would be left on the screen.
        abortLanding()
        guard draggingPayload != nil else { return }
        switch conversion {
        case .stripToDrawer:
            revertStripFromDrawer()
        case .drawerToStrip:
            onDrawerToStripCancelled?()
            revertDrawerToStrip()
        case .messagingToDrawer:
            revertMessagingFromDrawer()
        case .drawerToMessaging:
            revertDrawerToMessaging()
        case nil:
            break
        }
        // Abnormal cancel (target disappeared / screen change) does not fly: that is not "landing in a slot", and flying back to a position that no longer exists would only look stranger.
        teardown(landing: nil)
    }

    /// Whether this release should fly, and where to. If no drop anchor is available (or it is disabled by `DOCK_DRAG_LANDING=0`) -> nil -> finish instantly.
    private func plannedLanding(for payload: DragPayload, folderZone: FolderChipDropZone,
                                allowStash: Bool = true) -> Landing? {
        guard DragLandingSwitches.enabled else { return nil }
        // A folder chip dragged out of the strip (release = unpin / open) -> that slot is about to vanish,
        // and flying back to a disappearing position would only look stranger. Retire the carrier directly while it stays faded out.
        guard payload.source != .folder || folderZone == .folderZone else { return nil }
        // Released on the capsule to stash -> get sucked into the capsule (`DragLandingPlan.stashFlight`). The criterion matches the two branches in `endDrag` that really
        // `drawerStore.add`. **It cannot fly back to the slot**: the slot is gone as soon as the stash is committed (owner 2026-08-19 screenshot:
        // the icon drifts toward the strip for a while and then vanishes out of nowhere). If no capsule frame is available, finish instantly.
        if allowStash, willStash(payload) {
            let from = DragCarrierGeometry.topLeftCarriedCenter(pointer: globalLocation,
                                                                grabOffset: grabOffset,
                                                                panelFrame: carrierScreenFrame)
            guard let flight = DragLandingPlan.stashFlight(from: from, fromScale: carriedScale,
                                                           targetScreenRect: stashTargetProvider(),
                                                           carrierScreenFrame: carrierScreenFrame) else {
                HoverTrace.landing(from: from, to: nil, source: "stash:\(payload.source)")
                return nil
            }
            HoverTrace.landing(from: from, to: flight.to, source: "stash:\(payload.source)")
            landingToken &+= 1
            return Landing(token: landingToken, payload: payload, kind: .stash, flight: flight)
        }
        // The gap was just reopened and the slot frame has not been reported yet (released outside the strip after the close-up on drag-out): first fly toward the last known slot,
        // and correction takes over to the real position during the hold period / after takeoff. Only payloads dragged from the strip have this memory.
        let slotAnchor = landingAnchor?.rect
            ?? ((payload.source == .strip || payload.source == .messaging) ? lastKnownSlotAnchor : nil)
        // The card slot is on a different screen (dragged back across screens): the panel first moves to the slot's screen, so the flight is computed within the same panel.
        if let rect = slotAnchor {
            followScreenIfNeeded(CGPoint(x: rect.midX, y: rect.midY))
            placeCarrierUnderPointer()   // The carrier's current position in the new panel coordinates = start point
        }
        let from = DragCarrierGeometry.topLeftCarriedCenter(pointer: globalLocation,
                                                            grabOffset: grabOffset,
                                                            panelFrame: carrierScreenFrame)
        var flight = DragLandingPlan.flight(from: from,
                                            fromScale: carriedScale,
                                            anchorScreenRect: slotAnchor,
                                            carrierScreenFrame: carrierScreenFrame)
        // There is no anchor at all, but the empty slot was just reopened (a payload dragged from the strip): hold in place and wait; during the hold, correction replaces it wholesale with
        // the real flight; if it still has not come when time is up, settle directly (`launchLanding`). Reason in `DragLandingPlan.holdingFlight`.
        if flight == nil, slotAnchor == nil, payload.source == .strip || payload.source == .messaging,
           carrierScreenFrame.width > 0 {
            flight = DragLandingPlan.holdingFlight(at: from, scale: carriedScale)
        }
        HoverTrace.landing(from: from, to: flight?.to, source: "\(payload.source)")
        guard let flight else { return nil }
        landingToken &+= 1
        return Landing(token: landingToken, payload: payload, kind: .returnToSlot, flight: flight)
    }

    /// Place the carrier under the pointer on the spot (panel coordinates computed by `carrierScreenFrame`), without the "does not follow the hand before lift" guard of `moveCarrier`:
    /// in the landing phase `carrierLifted` has been cleared by `teardown`, and after a cross-screen panel switch the carrier must be repositioned to have a start point.
    private func placeCarrierUnderPointer() {
        guard let layer = carrierLayer, carrierScreenFrame.width > 0 else { return }
        let center = DragCarrierGeometry.carriedCenter(pointer: globalLocation,
                                                       grabOffset: grabOffset,
                                                       panelFrame: carrierScreenFrame)
        let aligned = alignedCenter(center, on: layer)
        Self.instantly { layer.position = aligned }
    }

    /// Cross-screen drop determination: a strip card, not in the stash drop zone, no cross-panel conversion in progress, and the strip currently claiming is not
    /// the one where the drag began. Items 1 and 2 have only one strip, so always nil. Returns the screen pinned by the target strip.
    private func crossStripDropDisplayUUID(for payload: DragPayload, external: Bool) -> String? {
        guard !external, conversion == nil, payload.source == .strip,
              let origin = originStripSurfaceID, let active = activeStripSurfaceID,
              active != origin else { return nil }
        return activeStripDisplayUUID
    }

    /// Whether this release will stash into the drawer (= the `external` branch of `.strip` / the `.stashMessagingChip` branch of `.messaging` in `endDrag`).
    private func willStash(_ payload: DragPayload) -> Bool {
        switch payload.source {
        case .strip:
            return isOverDropZone
        case .messaging:
            return DragConversionPlan.endAction(source: .messaging,
                                                isConvertedToStrip: isConvertedToStrip,
                                                isOverDropZone: isOverDropZone,
                                                isMessagingMember: messagingStore.contains(payload.bundleID))
                == .stashMessagingChip
        case .drawer, .folder:
            return false
        }
    }

    /// Wrap-up. When `landing` is non-nil, **the carrier is not retired**: it still has a stretch to fly; `finishLanding()` retires it when time is up.
    private func teardown(landing flight: Landing?) {
        let spanStart = HoverTrace.now(); defer { HoverTrace.span("teardown", since: spanStart) }
        let released = draggingPayload
        conversion = nil                  // Settle path: clear the conversion state without rollback (commit)
        convertedRepresentative = nil
        // **The empty slot of the converted card must be held until landing**, same as in-strip drags (there `hiddenSlotPayload` holds it for the whole flight).
        // If cleared on the spot, the card would appear fully opaque immediately while the carrier is still flying = double image. Cleared by `finishLanding` / `abortLanding`.
        if flight == nil {
            convertedChipID = nil
            clearStripClaims()
            setStripSlotCollapsed(false)
            lastKnownSlotAnchor = nil
        }
        folderDragZone = nil
        folderDropGeometry = nil
        draggingPayload = nil
        carrierArmed = false
        carrierLifted = false
        regrabOrigin = nil
        regrabPressed = false
        liftTimer?.invalidate(); liftTimer = nil
        armTask?.cancel(); armTask = nil
        candidate = nil
        isOverDropZone = false
        landingAnchor = nil
        removeMonitors()
        pollTimer?.invalidate(); pollTimer = nil
        landingTimer?.invalidate(); landingTimer = nil
        landingLaunchTask?.cancel(); landingLaunchTask = nil
        landing = flight
        guard let flight else {
            // **Even when not flying, "show first, retire after" applies.** `draggingPayload` was just cleared, and the card on the strip only becomes visible on SwiftUI's
            // next commit; calling `orderOut` right here would inevitably expose a frame of empty slot. These non-flying paths (sub-pixel landing
            // (displacement below `minimumTravel`, no flight), no anchor, a folder dragged out of the strip)
            // flash every time, which is exactly how the owner's report "clicking an icon makes the neighboring icon ghost up and down" shows up under rapid clicking.
            // Hover is likewise held until the pointer moves again: on this path the pointer also sits on the just-revealed card.
            if let released { beginHoverHold(for: released) }
            retireCarrierAfterHandoff()
            return
        }
        startLanding(flight)
    }

    /// The landing's common tail after `landing` is set: a drag's release (`teardown`) and an
    /// outside drop's hand-over (`beginExternalLanding`) fly the same way.
    private func startLanding(_ flight: Landing) {
        landingDeadline = CACurrentMediaTime() + DragLandingPlan.maximumDuration
        guard flight.kind == .returnToSlot else {
            // Sucked into the capsule: the destination is the capsule and does not change with layout, so there is nothing to wait for.
            landingLaunched = true
            flyCarrier(along: flight.flight, token: flight.token)
            return
        }
        // Flying back to the slot / cell: first hold for two display frames until the drop anchor settles (`DragLandingPlan.landingSettle`);
        // meanwhile `retargetLandingIfNeeded` only updates the destination and does not take off, otherwise the first leg would fly toward the old cell.
        landingLaunched = false
        let token = flight.token
        let task = DispatchWorkItem { [weak self] in self?.launchLanding(token: token) }
        landingLaunchTask?.cancel()
        landingLaunchTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + DragLandingPlan.landingSettle, execute: task)
        beginLandingGrabWatch()
    }

    /// An app dropped from outside (Finder) takes over from the system's drag image: the carrier
    /// appears at `fromScreenRect` — where that image was let go — and lands like a released drag,
    /// into the slot the owning view reports (`.returnToSlot`) or into the capsule (`.stash`).
    /// The system image vanishes on release and cannot be animated (`Docs/05`), so this is the
    /// only way the drop flies. A candidate prepared under `payload.id` while hovering
    /// (`prepareCandidate`) is claimed, so the carrier is on screen in the release frame; without
    /// one the new bitmap may show a frame late. The caller commits the stores in the same turn and,
    /// for `.returnToSlot`, reports the slot right after (`setLandingAnchor`) — an unchanged layout
    /// reports nothing on its own, and the flight would land in place.
    func beginExternalLanding(payload: DragPayload, snapshot: @autoclosure () -> CarrierSnapshot?,
                              fromScreenRect: CGRect, kind: Landing.Kind) {
        let prepared = candidate.flatMap { $0.payloadID == payload.id ? $0 : nil }
        guard draggingPayload == nil, DragLandingSwitches.enabled,
              fromScreenRect.width > 0, fromScreenRect.height > 0,
              let image = prepared?.snapshot ?? snapshot() else {
            if prepared != nil { clearCandidate(payloadID: payload.id) }
            return
        }
        candidate = nil
        abortLanding()
        endHoverHold()
        landingAnchor = nil
        let center = CGPoint(x: fromScreenRect.midX, y: fromScreenRect.midY)
        globalLocation = center
        grabOffset = .zero
        presentCarrier(snapshot: image, at: fromScreenRect, pose: .resting)
        // Inside the drop callback an outer implicit transaction would hold this until the turn
        // ends, behind the stores' re-render: two blank frames after the system image goes, not one.
        CATransaction.flush()
        let from = DragCarrierGeometry.topLeftCarriedCenter(pointer: center, grabOffset: .zero,
                                                            panelFrame: carrierScreenFrame)
        let scale = DragLandingPlan.carriedScale
        let flight: DragLandingFlight?
        switch kind {
        case .stash:
            flight = DragLandingPlan.stashFlight(from: from, fromScale: scale,
                                                 targetScreenRect: stashTargetProvider(),
                                                 carrierScreenFrame: carrierScreenFrame)
        case .returnToSlot:
            // No slot reported yet: hold in place; the anchor the caller reports next replaces it.
            flight = DragLandingPlan.flight(from: from, fromScale: scale,
                                            anchorScreenRect: landingAnchor?.rect,
                                            carrierScreenFrame: carrierScreenFrame)
                ?? DragLandingPlan.holdingFlight(at: from, scale: scale)
        }
        HoverTrace.landing(from: from, to: flight?.to, source: "external:\(kind)")
        guard let flight else {
            retireCarrier()
            return
        }
        landingToken &+= 1
        let landing = Landing(token: landingToken, payload: payload, kind: kind, flight: flight)
        self.landing = landing
        startLanding(landing)
    }

    /// The hold period ends: take off with the latest destination as of now. Idempotent (does nothing if the token mismatches or it has already taken off).
    private func launchLanding(token: Int) {
        guard !landingLaunched, let current = landing, current.token == token else { return }
        landingLaunched = true
        // The hold period ended and it is still holding in place (the anchor never came) -> settle directly; do not leave the carrier hanging in place for a full duration.
        guard !current.flight.isStationary else { finishLanding(token: token); return }
        flyCarrier(along: current.flight, token: token)
    }

    /// Schedule (or reschedule) the "retire the carrier once the flight is done" step.
    /// `.common`: at the moment of release the main run loop may still be in event-tracking mode, where a default-mode timer does not fire,
    /// and the carrier would hang in mid-air forever (same reason as `armSpringOpenTimer`).
    private func scheduleLandingFinish(token: Int) {
        landingTimer?.invalidate()
        let flightDuration = landing?.flight.duration ?? DragLandingPlan.duration
        let remaining = max(0.05, min(flightDuration + DragLandingPlan.settleMargin,
                                      landingDeadline - CACurrentMediaTime()))
        let timer = Timer(timeInterval: remaining, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.finishLanding(token: token)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        landingTimer = timer
    }

    /// Whether a strip card can be stashed: only blocks items without a bundleID (Finder can also be stashed since 2026-08-20).
    /// App-level fallback is not blocked: the drawer's running area already shows app-level icons.
    static func canStash(_ item: StripItem) -> Bool {
        guard let bid = item.bundleIdentifier, !bid.isEmpty else { return false }
        return true
    }

    // MARK: - Carrier panel (bitmap layer)

    /// Build the carrier panels ahead of time, so the user's **first drag** does not pay this cost for us.
    ///
    /// Now that the carrier is a bitmap this cost is much smaller (no need to order front once to force a SwiftUI host tree to lay out),
    /// but building an `NSPanel` still has a cost, and the first drag is exactly the one the owner called "the first frame stutters".
    func prewarmCarrier() {
        guard surfaces.isEmpty else { return }
        // One set per screen, ordered front right now (the layer holds nothing, so it is invisible on screen). Reason in `retireCarrier`.
        for frame in screensProvider().map(\.frame) { _ = surface(for: frame) }
        activeSurface = surfaces.first
        carrierScreenFrame = activeSurface?.frame ?? .zero
    }

    /// Panel teardown (suspended on permission loss, etc.): the resident panels must be retired explicitly, since an `NSWindow` that is on screen does not go away with the controller.
    func closeCarrierSurfaces() {
        abortLanding()
        for surface in surfaces { surface.panel.orderOut(nil); surface.panel.close() }
        surfaces.removeAll()
        activeSurface = nil
        carrierScreenFrame = .zero
    }

    /// The set covering the screen with `frame`; if none exists, build one and order it front.
    private func surface(for frame: CGRect) -> CarrierSurface {
        if let existing = surfaces.first(where: { $0.frame == frame }) { return existing }
        let made = makeCarrierSurface(frame: frame)
        surfaces.append(made)
        made.panel.orderFrontRegardless()
        pinCarrierWindows?([made.panel.windowNumber])
        if carrierParked { made.panel.setFrameOrigin(Self.parkedCarrierOrigin) }
        return made
    }

    /// Make "the current set" the one for the screen containing `point`; returns that screen's frame.
    /// On a screen change the old set's layers are cleared, and the caller immediately fills the new set with `apply(snapshot)`.
    @discardableResult
    private func ensureCarrierPanel(for point: CGPoint) -> CGRect {
        let frames = screensProvider().map(\.frame)
        // The screen arrangement changed: retire the sets for screens that no longer exist (they were empty anyway and invisible).
        for stale in surfaces where !frames.contains(stale.frame) {
            stale.panel.orderOut(nil); stale.panel.close()
            if activeSurface?.panel === stale.panel { activeSurface = nil }
        }
        surfaces.removeAll { !frames.contains($0.frame) }
        let frame = DragCarrierGeometry.screenFrame(containing: point, in: frames)
        guard frame.width > 0 else { return .zero }
        let next = surface(for: frame)
        if activeSurface?.panel !== next.panel {
            if let old = activeSurface {
                Self.instantly { old.layer.removeAllAnimations(); old.layer.contents = nil }
            }
            activeSurface = next
        }
        carrierScreenFrame = frame
        wakeCarrierSurfaces()
        return frame
    }

    /// Every panel back on its own screen (all of them: a drag may cross displays mid-flight and
    /// the other screen's panel must already be in place). Re-pinned into the overlay space in case
    /// the window server re-homed a window that spent its idle time on no display.
    private func wakeCarrierSurfaces() {
        guard carrierParked else { return }
        carrierParked = false
        for surface in surfaces { surface.panel.setFrameOrigin(surface.frame.origin) }
        pinCarrierWindows?(surfaces.map { $0.panel.windowNumber })
    }

    /// Off every display until the next `ensureCarrierPanel`. See `carrierParked`.
    private func parkCarrierSurfaces() {
        guard !carrierParked else { return }
        carrierParked = true
        for surface in surfaces { surface.panel.setFrameOrigin(Self.parkedCarrierOrigin) }
    }

    /// The pointer crosses to another screen -> switch to that screen's set, move the current bitmap / scale / projection over as is, then position by screen coordinates
    /// (the geometry is all "screen coordinates minus panel origin", so a changed origin just works). Within the same screen, do nothing.
    private func followScreenIfNeeded(_ point: CGPoint) {
        guard carrierScreenFrame.width > 0, !carrierScreenFrame.contains(point) else { return }
        let frames = screensProvider().map(\.frame)
        guard frames.contains(where: { $0.contains(point) }) else { return }   // In the seam between screens, leave it alone for now
        ensureCarrierPanel(for: point)
        if let layer = carrierLayer, let snapshot = carrierSnapshot {
            Self.instantly { self.apply(snapshot, to: layer); layer.opacity = 1 }
            applyCarrierVisualState(animated: false)
        }
        HoverTrace.dragHandoff("screenSwitch", msSinceBegin: (CACurrentMediaTime() - dragBeganAt) * 1000)
    }

    /// Place the bitmap at the slot's original position, appearing in the slot's current pose (not lifted yet). Fully synchronous, no implicit animation.
    private func presentCarrier(snapshot: CarrierSnapshot, at sourceScreenRect: CGRect,
                                pose: DragCarrierGeometry.PickUpPose) {
        let anchor = sourceScreenRect.width > 0 && sourceScreenRect.height > 0
            ? CGPoint(x: sourceScreenRect.midX, y: sourceScreenRect.midY) : globalLocation
        let frame = ensureCarrierPanel(for: anchor)
        guard let layer = carrierLayer, let panel = carrierPanel else { return }
        carrierGeneration &+= 1
        carrierSnapshot = snapshot
        originSnapshot = snapshot
        // If the frame has not been measured yet (`.zero`), fall back to "place directly under the pointer", which beats placing it at the screen's bottom-left corner.
        var center = sourceScreenRect.width > 0 && sourceScreenRect.height > 0
            ? DragCarrierGeometry.panelCenter(ofScreenRect: sourceScreenRect, panelFrame: frame)
            : DragCarrierGeometry.carriedCenter(pointer: globalLocation, grabOffset: grabOffset, panelFrame: frame)
        // If the slot is currently held up by the quiet tier's hover bottom anchor and shrunk by the press, the visual center is not the slot center: compensate by pose.
        center.y += pose.dy
        Self.instantly {
            layer.removeAllAnimations()
            self.apply(snapshot, to: layer)          // Swap the image first: `alignedCenter` needs the new bounds
            layer.position = self.alignedCenter(center, on: layer)
            layer.transform = Self.scaleTransform(pose.scale)
            layer.opacity = 1
        }
        orderCarrierFrontIfNeeded(panel)
    }

    /// **Every change to the carrier layer must be wrapped in an explicit `CATransaction`, even instantaneous assignments.**
    ///
    /// Measured (2026-08-19, item-by-item A/B): **a bare assignment to a sublayer in this panel does not reach WindowServer**:
    /// `presentation()` reads back the new value (that is computed locally) but the screen does not move at all: the position does not follow the hand and the opacity stays at the
    /// 0.01 from preparation, which looks like "the carrier vanished entirely"; the same code works as soon as it is wrapped in `begin/commit`.
    /// The cause was not traced to the bottom (this panel has no AppKit display cycle to flush the commit for it), but the rule is firm:
    /// **a bare assignment = silent failure**. Instantaneous changes go through here (which also disables implicit animations); changes that should animate go through `animate`, likewise wrapped in a transaction.
    private static func instantly(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    /// **If it is already frontmost, do not order it again.**
    ///
    /// Measured (2026-08-19, frame-by-frame in a 1000Hz synthetic-drag screen recording, all else equal): calling `orderFrontRegardless()` once more at drag start on a carrier panel that is **already**
    /// ordered front makes its content reach the screen 2-3 display frames late
    /// -- the slot side has already hidden and the copy has not appeared yet, which is that 3-frame gap; removing the redundant ordering brings the gap to zero.
    /// The panel was already ordered front when the press was prepared (`prepareCandidate`); in the drag-start turn only the layer should change, not the window.
    private func orderCarrierFrontIfNeeded(_ panel: NSPanel) {
        guard !panel.isVisible else { return }
        panel.orderFrontRegardless()
    }

    /// Lift: slide from the slot to under the pointer while growing to the normal size.
    private func liftCarrier() {
        guard let layer = carrierLayer else { return }
        carrierLifted = true
        HoverTrace.dragHandoff("lift", msSinceBegin: (CACurrentMediaTime() - dragBeganAt) * 1000)
        let rawTarget = DragCarrierGeometry.carriedCenter(pointer: globalLocation,
                                                       grabOffset: grabOffset,
                                                       panelFrame: carrierScreenFrame)
        let target = alignedCenter(rawTarget, on: layer)
        let from = layer.position
        // The model value lands directly (this is what the per-frame hand-following changes), and the **additive** animation makes up the difference in position.
        // Otherwise, every hand-following position write during the lift would fight with an absolute-value animation, and the copy would first fly toward the old target and then teleport.
        // Adding the animation is also inside the transaction: **any bare layer change (including adding an animation) may open an implicit transaction that is never committed**
        // (see `instantly`).
        Self.instantly {
            layer.position = target
            if hypot(target.x - from.x, target.y - from.y) > 0.5 {
                let slide = CABasicAnimation(keyPath: "position")
                slide.isAdditive = true
                slide.fromValue = NSValue(point: NSPoint(x: from.x - target.x, y: from.y - target.y))
                slide.toValue = NSValue(point: .zero)
                slide.duration = DragLandingPlan.liftDuration
                slide.timingFunction = CAMediaTimingFunction(name: .easeOut)
                slide.isRemovedOnCompletion = true
                layer.add(slide, forKey: "lift")
            }
        }
        applyCarrierVisualState(animated: true)
    }

    /// Hand-following: position synchronously on every mouse event. **Implicit animations must be disabled**: `CALayer.position` has a default 0.25s
    /// implicit animation, and left on, each frame would interpolate toward the previous frame's target, so the copy would trail the cursor limply forever.
    private func moveCarrier() {
        // **Do not follow the hand before the lift**: in that turn the carrier must stay at the slot's original position covering the card (see `carrierArmed`).
        // Without this guard, a dragged event arriving first in the drag-start turn would teleport the carrier under the pointer,
        // and the start point measured by `liftCarrier` afterwards would already be the end point, silently losing that slide.
        guard carrierLifted, let layer = carrierLayer, carrierScreenFrame.width > 0 else { return }
        let center = DragCarrierGeometry.carriedCenter(pointer: globalLocation,
                                                       grabOffset: grabOffset,
                                                       panelFrame: carrierScreenFrame)
        let aligned = alignedCenter(center, on: layer)   // If not aligned, the whole drag looks blurry; see `alignedCenter`
        Self.instantly { layer.position = aligned }
    }

    /// Scale + opacity (entering / leaving the drop zone, conversion, a folder dragged out of the strip) all go through this one exit,
    /// so several places do not each write their own and overwrite each other when states stack.
    private func applyCarrierVisualState(animated: Bool) {
        // Same as `moveCarrier`: before the lift the carrier keeps the "slot as is" look (0.93),
        // otherwise a single drop-zone determination in the drag-start turn could pull it to the normal size early, and the lift animation would be cut in half.
        guard carrierLifted, let layer = carrierLayer, draggingPayload != nil else { return }
        let scale = regrabPressed ? ChipPressDecision.pressedScale : carrierVisualScale
        let opacity = carrierVisualOpacity
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(DragLandingPlan.stateChangeDuration)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        } else {
            CATransaction.setDisableActions(true)
        }
        layer.transform = Self.scaleTransform(scale)
        layer.opacity = opacity
        CATransaction.commit()
    }

    /// Run an explicit animation on a layer property: the model value lands immediately, and the animation connects from the **current presentation value** to the new value.
    /// `duration == 0` means instantaneous. All of the layer's implicit actions are disabled (see `makeCarrierPanel`),
    /// so animating can only go through here; conversely, where no animation is wanted, a direct assignment is already instantaneous and needs no transaction wrapper.
    private static func animate(_ layer: CALayer, _ keyPath: String, to value: Any,
                                duration: TimeInterval,
                                timing: CAMediaTimingFunction = CAMediaTimingFunction(name: .easeOut)) {
        let from = (layer.presentation() ?? layer).value(forKeyPath: keyPath)
        layer.setValue(value, forKeyPath: keyPath)
        guard duration > 0 else { layer.removeAnimation(forKey: keyPath); return }
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = value
        animation.duration = duration
        animation.timingFunction = timing
        animation.isRemovedOnCompletion = true
        layer.add(animation, forKey: keyPath)
    }

    /// Swap in a different bitmap (drawer icon converted into a strip card / rollback; strip card moved into the drawer body / restored on drag-out; the card's appearance changed before landing).
    /// **Passing `nil` = swap back to the one from drag start** (rollback path).
    ///
    /// - Parameter reanchor: `true` = the old and new bitmaps differ greatly in size (a 168pt title card <-> a 30.8pt small drawer icon),
    ///   and the grab offset scales proportionally with size so the pointer stays at the **same relative position** on the icon; otherwise a title card grabbed at its right end would,
    ///   after swapping to the small icon, float tens of pt away from the pointer (owner 2026-08-19 screenshot: after entering the drawer the icon sat on the drawer edge); the position slides over,
    ///   and bounds and contents transition with the same 0.12s animation (the large card shrinks into the small icon while snapping to the pointer's side).
    ///   `false` = swap the image instantly, offset unchanged. **Both directions now use `true`** (owner 2026-08-20 required
    ///   "dragging from the drawer into the strip must be exactly the same as dragging within the strip", reversing the earlier sign-off on how the `false` version felt):
    ///   an instant swap means the 30.8pt drawer icon explodes around its own center in one frame into a 40-168pt card,
    ///   and the pointer's relative grip point jumps along with it.
    func setCarrierSnapshot(_ snapshot: CarrierSnapshot?, reanchor: Bool = false) {
        guard let layer = carrierLayer, draggingPayload != nil,
              let next = snapshot ?? originSnapshot else { return }
        let previousSize = carrierSnapshot?.size ?? layer.bounds.size
        carrierSnapshot = next
        guard reanchor, carrierLifted, previousSize.width > 0, previousSize.height > 0 else {
            Self.instantly { self.apply(next, to: layer) }
            return
        }
        grabOffset = CGSize(width: grabOffset.width * next.size.width / previousSize.width,
                            height: grabOffset.height * next.size.height / previousSize.height)
        let from = layer.position
        let rawTarget = DragCarrierGeometry.carriedCenter(pointer: globalLocation, grabOffset: grabOffset,
                                                       panelFrame: carrierScreenFrame)
        // Implicit bounds animation + contents cross-fade: the bitmap changes look and size over the same duration.
        CATransaction.begin()
        CATransaction.setAnimationDuration(DragLandingPlan.stateChangeDuration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        apply(next, to: layer)
        CATransaction.commit()
        // Position: model value lands directly + additive slide (same as `liftCarrier`), so hand-following is normal and does not fight with an absolute-value animation.
        let target = alignedCenter(rawTarget, on: layer)
        Self.instantly {
            layer.position = target
            if hypot(target.x - from.x, target.y - from.y) > 0.5 {
                let slide = CABasicAnimation(keyPath: "position")
                slide.isAdditive = true
                slide.fromValue = NSValue(point: NSPoint(x: from.x - target.x, y: from.y - target.y))
                slide.toValue = NSValue(point: .zero)
                slide.duration = DragLandingPlan.stateChangeDuration
                slide.timingFunction = CAMediaTimingFunction(name: .easeOut)
                slide.isRemovedOnCompletion = true
                layer.add(slide, forKey: "reanchor")
            }
        }
    }

    private func apply(_ snapshot: CarrierSnapshot, to layer: CALayer) {
        layer.contents = snapshot.image
        layer.contentsScale = snapshot.scale
        layer.bounds = CGRect(origin: .zero, size: snapshot.size)
    }

    /// Landing flight: translation and scale are **in the same transaction**, so there is no such omission as "the fade-out timer was not rescheduled along with the correction"
    /// (the previous version faded the carrier to 0 midway in exactly that way).
    private func flyCarrier(along flight: DragLandingFlight, token: Int) {
        guard let layer = carrierLayer else { return }
        // Start point: if still flying (correction reissue) use the position computed by the timeline, otherwise the model value from when it was held.
        let now = CACurrentMediaTime()
        let start = landingPose(at: now)
            ?? LayerPose(position: layer.position, scale: Self.scale(of: layer.transform))
        landingAnimation &+= 1
        let generation = landingAnimation
        let c = flight.curve   // Each flight carries its own curve (ease-out for near, fast for far); it must not be computed separately from duration
        let timing = CAMediaTimingFunction(controlPoints: Float(c.c0x), Float(c.c0y), Float(c.c1x), Float(c.c1y))
        let destination = alignedCenter(
            DragCarrierGeometry.panelPoint(fromTopLeft: flight.to, panelFrame: carrierScreenFrame), on: layer)
        CATransaction.begin()
        CATransaction.setAnimationDuration(flight.duration)
        CATransaction.setAnimationTimingFunction(timing)
        // CA's completion callback also fires when an animation is **replaced** (correction is a replacement), so it must claim by generation:
        // relying on `token` alone would let the correction end the flight on the spot.
        CATransaction.setCompletionBlock { [weak self] in
            Task { @MainActor in
                guard let self, self.landingAnimation == generation else { return }
                self.finishLanding(token: token)
            }
        }
        // Align the end point to device pixels: the bitmap lands 1:1 on the grid, and the landing frame is as sharp as the card on the strip
        // (`DragCarrierGeometry.pixelAligned`; owner 2026-08-19 reported "the frame before landing is blurry and the last frame suddenly sharp").
        layer.position = destination
        layer.transform = Self.scaleTransform(flight.toScale)
        layer.opacity = flight.toOpacity        // Fly back to slot = 1 (the fade-out of a folder dragged out of the strip must be undone); sucked into the capsule = 0
        CATransaction.commit()
        // Timeline: take-off time is the moment before the transaction begins (`now`). The commit itself is a round trip to WindowServer,
        // and taking it after the commit would run a few ms behind the screen (frame-grab measurement: 3pt backward on regrab); better to estimate slightly ahead --
        // a freeze point one or two pt beyond the screen looks like "moved once more and stopped", while stepping back is a jump.
        flightTimeline = FlightTimeline(beganAt: now, start: start,
                                        destination: LayerPose(position: destination, scale: flight.toScale),
                                        duration: flight.duration, curve: flight.curve)
        scheduleLandingFinish(token: token)
    }

    /// A set of presentation values for the layer: position (panel coordinates) + scale. The carrier has no shadow, so there is no shadow term.
    private struct LayerPose {
        var position: CGPoint
        var scale: CGFloat
    }

    /// The timeline of this flight. **"Where the icon is right now" is computed from it, not read from `presentation()`**: the latter lags the screen by about two frames
    /// (a dozen pt per frame early in the flight), and freezing by it jumps backward (2026-08-19 frame-grab measurement: 15pt); the render server and this code
    /// use the same curve, the same clock and the same beginTime, so computing it ourselves is what matches. On a correction reissue, the start point is the estimate at that time.
    private struct FlightTimeline {
        let beganAt: CFTimeInterval
        let start: LayerPose
        let destination: LayerPose
        let duration: TimeInterval
        let curve: DragLandingCurve
        func pose(at time: CFTimeInterval) -> LayerPose {
            let p = CGFloat(curve.progress(at: (time - beganAt) / duration))
            return LayerPose(position: CGPoint(x: start.position.x + (destination.position.x - start.position.x) * p,
                                               y: start.position.y + (destination.position.y - start.position.y) * p),
                             scale: start.scale + (destination.scale - start.scale) * p)
        }
    }
    private var flightTimeline: FlightTimeline?

    /// The presentation values of the flying icon right now; nil when not flying.
    private func landingPose(at time: CFTimeInterval) -> LayerPose? {
        guard let landing, let timeline = flightTimeline else { return nil }
        // An icon sucked into the capsule does not accept regrab / click: the card it represents is no longer on the strip.
        guard landing.kind == .returnToSlot else { return nil }
        return timeline.pose(at: time)
    }

    private static func scale(of transform: CATransform3D) -> CGFloat { transform.m11 }

    /// Landing accuracy self-check: where the carrier finally stopped and how far it is from the slot. > 0.5pt means a jump will be visible on landing.
    private func recordLandingDelta() {
        guard HoverTrace.isEnabled, let layer = carrierLayer, let flight = landing?.flight else { return }
        let want = DragCarrierGeometry.panelPoint(fromTopLeft: flight.to, panelFrame: carrierScreenFrame)
        let got = layer.presentation()?.position ?? layer.position
        HoverTrace.landingDelta(dx: got.x - want.x, dy: got.y - want.y)
    }

    private static func scaleTransform(_ scale: CGFloat) -> CATransform3D {
        CATransform3DMakeScale(scale, scale, 1)
    }

    /// **Wherever the carrier stops, it must land on the device pixel grid.**
    ///
    /// A bitmap that lands on half a pixel is resampled by the system, which looks like "the icon is a bit blurrier than the card on the strip"
    /// (owner 2026-08-19: "while dragging the icon there is a faint blur that disappears after landing").
    /// Previously only the **end point** of the landing flight was aligned, so the whole hand-following stretch was blurry and became sharp at landing, two halves of the same problem.
    ///
    /// The quantization step is one device pixel (0.5pt on a 2x screen), invisible to the eye, and this is exactly why native dragging stays sharp.
    /// Scaled states (0.82 over the drop zone, 1.023 in the drag-start pose) are resampled anyway, so aligning them is neither harmful nor helpful,
    /// but routing everything through here keeps the two algorithms from drifting apart.
    private func alignedCenter(_ center: CGPoint, on layer: CALayer) -> CGPoint {
        DragCarrierGeometry.pixelAligned(center: center,
                                         size: layer.bounds.size,
                                         scale: carrierSnapshot?.scale ?? 2)
    }

    private func makeCarrierSurface(frame: CGRect) -> CarrierSurface {
        // NonConstrainingPanel: the carrier covers **one screen** (not the union, see `DragCarrierGeometry.screenFrame`);
        // being constrained by the system to the usable area would misplace it, same as the dock / capsule.
        let panel = NonConstrainingPanel(contentRect: frame,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.collectionBehavior = PanelCollectionBehavior.standard
        panel.isFloatingPanel = true
        // **Set after `isFloatingPanel = true`, which silently resets it to `.floating`, and keep it
        // above every panel of ours, the raised drawer included.** At the bar's level the bar's own
        // re-order-fronts (show cycles, screen switches, layout) covered the flying copy whenever it
        // crossed the bar's frame — the card vanished mid-landing. Still below system menus.
        panel.level = PanelLevel.carrier
        panel.isMovable = false
        panel.isOpaque = false
        panel.backgroundColor = NSColor(white: 1.0, alpha: 0.0)
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true          // Pure drawing, does not steal events; the one exception is in `refreshLandingGrabState`
        panel.alphaValue = 1                     // Always 1: there are no more panel-level alpha animations
        // The panel's contentView is a plain full-screen NSView (AGENTS: "panels must not use a hosting view as contentView"),
        // and the carrier is a sublayer attached to its layer. Non-flipped view -> sublayer coordinates have a bottom-left origin with y up.
        let container = CarrierContainerView(frame: CGRect(origin: .zero, size: frame.size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.0).cgColor
        container.autoresizingMask = [.width, .height]
        let layer = CALayer()
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.isOpaque = false
        layer.allowsEdgeAntialiasing = true
        layer.delegate = carrierActionGate
        // **Do not blanket-disable implicit actions here with `layer.actions = [...NSNull]`**: the landing flight and the scaling in/out of the drop zone
        // use exactly the implicit animation of "set a duration in the transaction + assign directly", and disabling everything turns them into teleports (stepped on once, 2026-08-19:
        // after release the icon jumped back to the slot in one frame and the flight was gone). Instantaneous assignments are all wrapped in `instantly`, which turns animation off.
        // **The carrier never has a shadow** (owner 2026-08-19: icons on the strip have no shadow, so the held one has none either).
        // `CALayer` does not draw one by default, so not a single shadow property is set here; once someone sets even half of them,
        // the landing handoff gets the "bitmap's shadow is lighter than the card's" step again (that was the cause of the previous round's +2.85).
        container.layer?.addSublayer(layer)
        // The flight is interruptible: the icon's current frame is the hit region, and a press = continue dragging from the current position (see `regrabLanding`).
        container.grabRegion = { [weak self] in self?.landingIconPanelFrame() }
        container.onGrab = { [weak self] point in self?.regrabLanding(at: point) }
        panel.contentView = container
        return CarrierSurface(panel: panel, container: container, layer: layer, frame: frame)
    }

    /// After a spring-opened drawer, bring the carrier back to the very front: a newly opened drawer after orderFront may cover a carrier created before it (reported by the owner 2026-06-21:
    /// "when dragging into a spring-opened drawer the floating icon disappears"). Only acts while a drag is in progress.
    func bringCarrierToFront() {
        guard draggingPayload != nil, let c = carrierPanel else { return }
        c.orderFrontRegardless()
    }

    // MARK: - Monitors + polling fallback

    private func installMonitors() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] ev in
            guard let self else { return ev }
            let loc = NSEvent.mouseLocation
            if ev.type == .leftMouseUp { self.update(loc); self.endDrag() }
            else { self.update(loc) }
            return ev
        }
        // global measured 0 events throughout (the implicit grab is locked to this app); kept as a cheap fallback.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] ev in
            guard let self else { return }
            let loc = NSEvent.mouseLocation
            if ev.type == .leftMouseUp { self.update(loc); self.endDrag() }
            else { self.update(loc) }
        }
    }

    private func removeMonitors() {
        if let m = localMonitor  { NSEvent.removeMonitor(m); localMonitor  = nil }
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
    }

    private func startPoll() {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.draggingPayload != nil else { return }
                if NSEvent.pressedMouseButtons == 0 { self.endDrag() }
            }
        }
        timer.tolerance = 0.02
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }
}

// The carrier views (DragCarrierView / DrawerDragIconView) are in App/Composition/DragCarrierView.swift --
// they pull in UI dependencies such as ChipView/PinnedFolderChip; splitting them out lets this controller compile locally in the test target.
