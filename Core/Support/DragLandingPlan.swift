import CoreGraphics
import Foundation

/// The single flight of the floating copy "flying back into its slot" after release. Coordinates are all **inside the carrier panel** (top-left origin, y down),
/// because the carrier is the only place that draws it.
struct DragLandingFlight: Equatable {
    let from: CGPoint
    let to: CGPoint
    let fromScale: CGFloat
    let toScale: CGFloat
    /// **This flight's** duration. Computed from distance, not a global constant; see `DragLandingPlan.duration(travel:)`.
    let duration: TimeInterval
    /// **This flight's** curve. Also computed from distance (gentle for near, fast for far); see `DragLandingPlan.curve(travel:)`.
    let curve: DragLandingCurve
    /// Opacity on landing: flying back to the slot = 1; absorbed into the capsule = 0 (`DragLandingPlan.stashFlight`).
    var toOpacity: Float = 1

    /// Mid-flight correction after takeoff: **swap only the endpoint; start / duration / curve / opacity are kept as is.**
    /// The flight is already running; swapping in a new duration and curve would restart from this moment and ease to a stop again. When the anchor drifts frame by frame (the strip unfreezes
    /// and re-centers, the drawer panel slides along for 0.22s), restarting every frame produces a "stutter" (2026-09-03 trace:
    /// 11 resends within 0.22s, the endpoint moving 1-3pt each time). Sliding the endpoint along the same timeline makes the eye see one smooth path.
    func sliding(to newTo: CGPoint, toScale newToScale: CGFloat) -> DragLandingFlight {
        DragLandingFlight(from: from, to: newTo, fromScale: fromScale, toScale: newToScale,
                          duration: duration, curve: curve, toOpacity: toOpacity)
    }

    /// A "hold in place" flight (`DragLandingPlan.holdingFlight`): displacement below `minimumTravel`.
    /// If it is still this at takeoff, settle immediately rather than making the carrier idle in place for a full duration.
    var isStationary: Bool {
        hypot(to.x - from.x, to.y - from.y) < DragLandingPlan.minimumTravel
    }
}

/// A fixed-duration cubic Bezier curve (the four numbers of `CAMediaTimingFunction(controlPoints:)`).
struct DragLandingCurve: Equatable {
    let c0x: Double
    let c0y: Double
    let c1x: Double
    let c1y: Double

    /// Progress (0...1) at normalized time `t` (0...1): solve x(s) = t, then take y(s); the same algorithm as CA / CSS timing functions.
    /// **The controller uses it to compute "where the flying icon is right now"** (`DragController.landingPose`);
    /// `CALayer.presentation()` lags what is actually drawn on screen by about two frames, and the start of a flight moves a dozen-plus pt per frame,
    /// so freezing at it would jump backwards (2026-08-19 frame-grab measured 15pt); computing it ourselves from the same curve and the same clock is what matches the render server.
    func progress(at t: Double) -> Double {
        if t <= 0 { return 0 }
        if t >= 1 { return 1 }
        var lo = 0.0, hi = 1.0, s = t
        for _ in 0..<48 {
            let x = Self.bezier(s, c0x, c1x)
            if abs(x - t) < 1e-7 { break }
            if x < t { lo = s } else { hi = s }
            s = (lo + hi) / 2
        }
        return Self.bezier(s, c0y, c1y)
    }

    private static func bezier(_ s: Double, _ p1: Double, _ p2: Double) -> Double {
        let u = 1 - s
        return 3 * u * u * s * p1 + 3 * u * s * s * p2 + s * s * s
    }
}

/// Pure decision logic for the landing flight (owner 2026-08-18: "the animation when the icon snaps back on release isn't as graceful and unhurried as the native Dock").
///
/// **Before this rework this phase did not exist at all**: in `endDrag()`, `orderOut` on the carrier and `draggingPayload = nil` happened in the same frame,
/// so the floating copy in hand vanished instantly and the card on the strip went from opacity 0 to 1 instantly. The distance from the cursor to the slot center,
/// and the 1.05 -> 1.0 size difference, were all **jumped** across. The native Dock flies the icon back into its slot.
///
/// The reason the decision is split out is the same as for `DragConversionPlan` / `StripHoverResolution`:
/// coordinate conversion is the easiest thing to get wrong (the screen has a bottom-left origin, the carrier panel a top-left origin), and unit tests can pin it down.
enum DragLandingPlan {
    /// The two ends of the flight duration. **Duration depends on distance; it is not a fixed value** (owner 2026-08-18: "no native animation feels this graceful and unhurried").
    ///
    /// The problem with a fixed duration: the same 0.26 seconds makes a 20pt short snap feel hurried and a 200pt long trip feel rushed.
    /// Much of the native "unhurried" feel comes from farther distances taking longer. A square root is used to converge rather than a linear mapping:
    /// short distances don't get so short as to be invisible, and long distances don't drag.
    /// The owner settled these round by round: 0.16/0.34 -> 0.22/0.46 -> 0.30/0.62 -> 0.60/0.90 (2026-08-18)
    /// -> **0.32/0.50** (2026-08-19: "much slower than native").
    ///
    /// **This is not a regression; the premise changed.** 0.60/0.90 was settled when the carrier was still a semi-transparent SwiftUI copy and the curve was still the long-distance
    /// fast-out slow-stop one: that curve covers 61% in 17% of the time, and for most of the remainder the eye can barely see motion,
    /// so 0.6 seconds read as "unhurried" back then. After 2026-08-19 swapped the short-distance curve for a standard ease-out, the same duration
    /// has much more "visible displacement", so it felt sluggish. The curve stays; only the duration is scaled back proportionally.
    ///
    /// Tuning these two numbers needs no reinstall: `DOCK_DRAG_FLIGHT_MS=320,500` (see `DragLandingSwitches.flightDurations`).
    static let minimumDuration: TimeInterval = DragLandingSwitches.flightDurations?.minimum ?? 0.32
    static let maximumFlightDuration: TimeInterval = DragLandingSwitches.flightDurations?.maximum ?? 0.50
    /// At this displacement the full duration is used; going farther adds nothing.
    static let referenceTravel: CGFloat = 300

    /// **Below this displacement there is no flight; settle directly.** It only blocks sub-pixel moves: the landing point is already rounded to device pixels
    /// (`DragCarrierGeometry.pixelAligned`), and a flight of less than 1pt shows nothing.
    ///
    /// It used to be 12pt, set for "hand shake on click": the drag-start threshold is 8pt, so a shaky hand is a tiny drag, and at that time
    /// the carrier was still a semi-transparent SwiftUI copy, so swinging back for 0.6s in place left a visible ghost (owner 2026-08-18:
    /// "clicking an icon leaves a ghost on the icon next to it, up and down"). Once the carrier became a bitmap that reason went away: the copy is opaque,
    /// pixel-for-pixel equal to the slot, and hover isn't re-evaluated after landing, so flying back only looks better than jumping. Conversely, 12pt is exactly the most common landing
    /// spot for in-strip reordering (icon spacing is 42pt, so at release the slot center and carrier differ by 0-21pt, over half within 12pt),
    /// and all of those jumped into place instantly, which is half of what the owner reported on 2026-08-19 as "short distances feel too fast".
    /// Now even an 8-12pt hand shake still flies, sliding back like the native Dock rather than jumping back.
    static let minimumTravel: CGFloat = 1

    /// Fallback / baseline duration (a nominal value used by the retarget gate and unit tests). For how long each flight really takes, see `duration(travel:)`.
    static let duration: TimeInterval = 0.26

    static func duration(travel: CGFloat) -> TimeInterval {
        minimumDuration + (maximumFlightDuration - minimumDuration) * travelFactor(travel)
    }

    /// Distance -> a progress number in 0...1: reaches 1 at `referenceTravel`, adds nothing beyond; square root (more generous for short distances).
    /// **Both duration and curve use it**; a single number decides "how long-distance this flight is".
    static func travelFactor(_ travel: CGFloat) -> Double {
        min(1, max(0, Double(travel) / Double(referenceTravel))).squareRoot()
    }

    /// **The curve also depends on distance: gentle for near, fast for far, with a continuous transition** (owner 2026-08-19: "the short-distance flight animation is too fast").
    ///
    /// The duration already had a 0.60s floor, yet short trips still looked fast, because the long-distance curve (`curve`) is too front-loaded:
    /// it covers 61% in 17% of the time and 84% in 31%. For a 300pt long trip, the remaining 48pt slowly settles in the second half,
    /// which reads as "unhurried"; a 30pt short trip's visible displacement finishes within 0.15-0.2s, and the last few pt crawl through
    /// 0.4s, which is effectively no animation. So short trips switch to a gentler ease-out: `shortCurve` is Penner's
    /// easeOutQuad, 53% at 30% of the time and 77% at 50%, so the first 0.4s of 0.6s is a **visible** slide.
    /// Between the two ends, the four control points are linearly interpolated by `travelFactor`; no threshold switch is used, since flights on either side of
    /// a threshold would look different. At `referenceTravel` and above it is the original curve, and the long trips the owner approved are unchanged.
    static func curve(travel: CGFloat) -> DragLandingCurve {
        let f = travelFactor(travel)
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * f }
        return DragLandingCurve(c0x: mix(shortCurve.c0x, curve.c0x),
                                c0y: mix(shortCurve.c0y, curve.c0y),
                                c1x: mix(shortCurve.c1x, curve.c1x),
                                c1y: mix(shortCurve.c1y, curve.c1y))
    }

    /// The short-distance end's curve (Penner easeOutQuad). Still fast-out slow-stop, and still ends exactly on time at `duration`.
    static let shortCurve = DragLandingCurve(c0x: 0.25, c0y: 0.46, c1x: 0.45, c1y: 0.94)

    /// Parsing of `DOCK_DRAG_FLIGHT_MS` (a pure function, covered by unit tests). `"320,500"` -> 0.32s / 0.50s.
    /// Anything invalid is `nil`: **half-applied is worse than not applied**; if only the lower bound were honored, the two ends of the curve would be reversed.
    static func parseFlightDurations(_ raw: String) -> (minimum: TimeInterval, maximum: TimeInterval)? {
        let parts = raw.split(separator: ",", omittingEmptySubsequences: false)
            .map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2, let lo = parts[0], let hi = parts[1],
              lo > 0, hi > 0, lo <= hi else { return nil }
        return (lo / 1000, hi / 1000)
    }

    /// After the carrier reaches its target, wait a little longer before actually tearing it down, leaving slack for the last frame to commit.
    static let settleMargin: TimeInterval = 0.03

    /// Mid-flight correction pushes back the moment the carrier is torn down (each correction restarts a leg). This is the hard cap on the whole flight,
    /// so the carrier doesn't hang around when the slot keeps moving. It is normally never needed: no reordering happens on release, so the slot is stationary.
    static let maximumDuration: TimeInterval = 2.00

    /// When less than one full duration remains before the flight cap, stop correcting: restarting a leg then would inevitably be truncated by the cap,
    /// producing exactly the jump we are trying to cure.
    static func allowsRetarget(remainingBeforeDeadline: TimeInterval,
                               flightDuration: TimeInterval = duration) -> Bool {
        remainingBeforeDeadline > flightDuration + settleMargin
    }

    /// **Must be a fixed-duration curve, not a spring** (owner 2026-08-18 spotted at a glance that "landing still jitters").
    ///
    /// `spring(response: 0.26)` has **not stopped at all** at 0.26 seconds; response is only its natural period,
    /// and truly coming to rest takes 2-3 times as long. The timer that tears down the carrier is cut at `duration`, so the icon would be
    /// chopped off mid-flight, and the remaining distance would be covered in one step by "carrier disappears, strip card appears", which looks like a jitter.
    ///
    /// The control points take the existing "fast-out slow-stop" curve in the repo (same as `PopoverAnimation.curve()`):
    /// fast start and gentle finish, exactly the feel of the native Dock landing, and it **really does end at `duration`**.
    /// This is the **long-distance** end; each actual flight uses `curve(travel:)` to pick between it and `shortCurve` by distance.
    static let curve = DragLandingCurve(c0x: 0.2, c0y: 0.9, c1x: 0.3, c1y: 1.0)

    /// **Lift**: how long the carrier takes at drag start to slide from the slot's original position to under the pointer.
    ///
    /// The drag-start threshold is `DragGesture(minimumDistance: 8)`, so if the carrier were placed directly under the pointer the moment it appears,
    /// the icon would **jump** there; half of the "stutter on the first frame of dragging a selected icon" the owner reported on 2026-08-18 was this jump.
    /// The displacement animation is additive (`isAdditive`), so the mouse can keep moving during the lift without a fight: the model value changes every frame,
    /// and the additive offset decays to 0 on its own.
    static let liftDuration: TimeInterval = 0.12

    /// After the card is hidden and before the lift, the short stretch (two display frames) in which the carrier sits still at the slot's original position, pressed to the slot pose.
    /// Carrier changes are explicit transactions, committed on the spot; hiding the card waits for the SwiftUI/AppKit display cycle.
    /// When the main thread is busy the two can differ by a frame or two, and if the carrier has already left the slot by then you get a double image, so let it wait first;
    /// during those two overlapping frames the two are pixel-identical (`DragController.armCarrier`).
    static let liftDelay: TimeInterval = 0.034

    /// With **no prepared candidate**, how long the carrier sits on the slot's original position pressing the card before "hide card + lift".
    ///
    /// The bitmap's first frame is one display frame later than SwiftUI hiding the card (texture upload, measured). The first version waited "one run loop turn",
    /// but on real hardware a mouse delivers an event every 1-8ms, so the next turn is often still in the same frame -> a one-frame gap = "occasionally vanishes".
    /// Waiting two display frames by time (33ms at 60Hz) is what lines up with the display; on ProMotion 120Hz that is four frames,
    /// and the extra wait only overlaps a few more frames, which is not noticeable. **The normal path doesn't go through here**: after prepare-on-press (`prepareCandidate`)
    /// the texture was uploaded long ago, so drag start is let through in the same turn.
    static let pickUpSettle: TimeInterval = 0.034

    /// After release, how long the landing flight **holds before taking off** (only for flying back to a slot/cell; absorption into the capsule doesn't wait).
    ///
    /// At the moment of release the landing anchor is still the frame from **before settling**: the drawer grid has to wait for the layout after this drop commits to know
    /// which column this cell finally lands in. Taking off without waiting makes CA fly toward the old cell first, and a few milliseconds later `retargetLandingIfNeeded`
    /// yanks the endpoint back, which shows on screen as a broken line (owner 2026-08-20: "it first drifts to the right of the target, then goes to the target").
    ///
    /// **Wait by time, not by run loop turns**, for the same reason as `pickUpSettle`: on real hardware a mouse delivers an event every 1-8ms,
    /// so the next turn is often still in the same frame. Two display frames are enough to wait for that layout; during this time the carrier sits at the release position,
    /// and the flight itself is 320-500ms, so these extra two frames are not noticeable.
    static let landingSettle: TimeInterval = 0.034

    /// Opacity of the carrier layer while preparing on press. **Not 0**: a fully transparent layer is culled from the render tree and its texture isn't uploaded,
    /// making the warm-up pointless; 0.01 is invisible to the eye but really does go through an upload.
    static let candidateOpacity: Float = 0.01

    /// After re-grabbing mid-flight, if the pointer moves less than this before release = a **click** (wake / minimize that card); more = a drag.
    /// The same number as the chip drag-start threshold `DragGesture(minimumDistance: 8)`.
    static let regrabClickSlop: CGFloat = 8

    /// Upper bound of the post-landing hover-hold period. Normally it ends as soon as the pointer moves; this is the fallback for "the user releases and doesn't move at all",
    /// so the 60Hz polling doesn't hang around forever.
    static let hoverHoldMaximum: TimeInterval = 3.0

    /// Duration of state switches during a drag (entering/leaving the drop zone, a folder dragged out of the strip).
    static let stateChangeDuration: TimeInterval = 0.12

    /// How a folder chip looks when dragged out of the strip's visible range: fades out + scales up slightly, giving "release to remove the pin"
    /// real-time feedback (owner 2026-07-06). It used to be hard-coded in the carrier view and moved here after the carrier became a bitmap.
    static let folderRemovalScale: CGFloat = 1.1
    static let folderRemovalOpacity: Float = 0.35

    /// Scale factor while held in hand (the resident state of `DragCarrierView`).
    /// **1.0, no enlargement** (2026-08-19; it was 1.05): neither the native Dock nor BestDock enlarges on pick-up
    /// (BestDock's preview window is literally named `dragPreviewLockedSize`); no scaling = the bitmap is never resampled,
    /// staying as sharp as the card on the strip from drag start to landing, so the last frame of landing has no "sudden sharpening".
    static let carriedScale: CGFloat = 1.0
    /// Scale to shrink to when hovering over a drop zone (capsule / strip).
    static let dropZoneScale: CGFloat = 0.82
    /// On landing it is immediately the same size as the card on the strip.
    static let landedScale: CGFloat = 1.0

    /// **Releasing on the capsule to stash = absorbed into the capsule** (owner 2026-08-19 screenshot: after stashing, the icon drifted toward the strip's end and then vanished).
    /// Once the stash commits, that cell on the strip is gone; flying back to a position that no longer exists would just vanish out of thin air. Changed to fly to the capsule center,
    /// shrink to `stashScale`, and fade to 0. Duration is fixed: this is not the unhurried return "back to its place", it is "being sucked in".
    static let stashScale: CGFloat = 0.3
    static let stashDuration: TimeInterval = 0.35

    /// The flight absorbed into the capsule. `targetScreenRect` = the capsule's visible frame; `nil` = the capsule's location is unknown -> no flight (finish instantly).
    static func stashFlight(from: CGPoint,
                            fromScale: CGFloat,
                            targetScreenRect: CGRect?,
                            carrierScreenFrame: CGRect) -> DragLandingFlight? {
        guard let rect = targetScreenRect,
              rect.width > 0, rect.height > 0,
              carrierScreenFrame.width > 0, carrierScreenFrame.height > 0 else { return nil }
        let to = CGPoint(x: rect.midX - carrierScreenFrame.minX,
                         y: carrierScreenFrame.maxY - rect.midY)
        return DragLandingFlight(from: from, to: to,
                                 fromScale: fromScale, toScale: stashScale,
                                 duration: stashDuration, curve: shortCurve, toOpacity: 0)
    }

    /// **At release the landing anchor isn't available yet, but it is about to arrive** (release outside the strip after drag-out-and-close: the empty slot only reopens at this moment,
    /// and the strip can't report that cell's frame until the next SwiftUI commit; for a cross-screen window drag it is another strip drawing this card for the first time):
    /// returns a hold-in-place flight, taking the hold-period (`landingSettle`) path; once the anchor arrives, correction **replaces the whole leg** with the real flight.
    /// If it is still this at takeoff (the anchor never came) -> settle directly (`isStationary`). Previously this case finished instantly,
    /// which on cross-screen was the "icon vanishes on release and flashes on strip B" the owner reported on 2026-09-03.
    static func holdingFlight(at point: CGPoint, scale: CGFloat) -> DragLandingFlight {
        DragLandingFlight(from: point, to: point, fromScale: scale, toScale: landedScale,
                          duration: minimumDuration, curve: shortCurve)
    }

    /// Screen rect (bottom-left origin) -> center point inside the carrier panel (top-left origin).
    ///
    /// - Parameter anchorScreenRect: which cell on screen this item will finally land in. `nil` = unknown -> no flight,
    ///   take the pre-rework instant finish (the zero-risk fallback). The branch that promotes into the taskbar is exactly this case: release unfreezes the taskbar width,
    ///   the whole strip re-centers, and the landing point still drifts during the flight.
    static func flight(from: CGPoint,
                       fromScale: CGFloat,
                       anchorScreenRect: CGRect?,
                       carrierScreenFrame: CGRect) -> DragLandingFlight? {
        guard let rect = anchorScreenRect,
              rect.width > 0, rect.height > 0,
              carrierScreenFrame.width > 0, carrierScreenFrame.height > 0 else { return nil }
        let to = CGPoint(x: rect.midX - carrierScreenFrame.minX,
                         y: carrierScreenFrame.maxY - rect.midY)
        // Sub-pixel -> no flight (reason in `minimumTravel`).
        let travel = hypot(to.x - from.x, to.y - from.y)
        guard travel >= minimumTravel else { return nil }
        return DragLandingFlight(from: from, to: to,
                                 fromScale: fromScale, toScale: landedScale,
                                 duration: duration(travel: travel),
                                 curve: curve(travel: travel))
    }
}

/// Switch for the landing flight. New feel always comes with a way out (same as `ChipPressSwitches`): should it fight with reordering or
/// cross-panel stashing on real hardware, the owner can immediately revert to instant finish without waiting for a repackage.
enum DragLandingSwitches {
    static let enabled = DebugSwitch.dragLanding.isEnabled(in: ProcessInfo.processInfo.environment)

    /// On-site speed knob for the landing flight duration: `DOCK_DRAG_FLIGHT_MS=<min>,<max>` (milliseconds, e.g. `320,500`).
    ///
    /// The reason it exists is practical: the owner has set these two numbers back and forth over five rounds, and each round meant "edit constant -> rebuild -> reinstall ->
    /// feel it again", over two minutes a round. With this, changing an environment variable and restarting converges in seconds (same precedent as `DOCK_PANEL_MATERIAL`).
    /// **The default value is still written in `DragLandingPlan`**; with the variable unset, behavior is exactly the same as the hard-coded constant.
    ///
    /// Invalid parsing (half missing, non-numeric, non-positive, min > max) is treated as unset, never half-applied.
    static let flightDurations: (minimum: TimeInterval, maximum: TimeInterval)? =
        DebugSwitch.dragFlightMs.value(in: ProcessInfo.processInfo.environment)
            .flatMap(DragLandingPlan.parseFlightDurations)
}
