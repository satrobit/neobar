import CoreGraphics
import Foundation
import QuartzCore

/// Feel diagnostics for taskbar interaction. Off by default; turn on with `DOCK_HOVER_TRACE=1`.
/// (The file name keeps `hover-trace.jsonl`: it originally measured only hover, was extended on 2026-08-17 to the click / minimize path,
/// and on 2026-08-18 to dragging. All feel diagnostics share this one switch and one file -- running a separate I/O setup would be pointless.)
///
/// The hover part answers two questions:
/// 1. **When the mouse sweeps at constant speed across a row of icons, did every chip receive a hover callback?** If some are missing, events were coalesced,
///    and the problem is main-thread occupancy, not the bubble itself.
/// 2. **After receiving it, how long did it take to put the bubble in place?** If long, rendering / window calls are slow, and that is the bubble's own problem.
///
/// It also records main-thread **stalls**: a repeating 8ms timer measures how much later than scheduled each actual fire is.
/// This is direct evidence of "events being coalesced" -- the 100ms stickiness in AGENTS "Menus, Panels, And Screens"
/// was identified back then precisely by "main thread idle but events arriving late"; CPU usage alone can't show it.
///
/// Written to `~/Library/Logs/app.neobar.NeoBar/hover-trace.jsonl`.
enum HoverTrace {
    static let isEnabled = DebugSwitch.hoverTrace.isEnabled(in: ProcessInfo.processInfo.environment)
    /// The width probes (`width` / `relayout` / `action`) can be enabled separately: `DOCK_LABEL_PROBE=1` excludes the hover trace's
    /// 8ms stall sampling and pointer polling -- those two keep the main loop awake all the time, which is itself interference when measuring animation.
    static let widthProbesEnabled = isEnabled || DebugSwitch.labelProbe.isEnabled(in: ProcessInfo.processInfo.environment)

    /// A chip reports hover enter / exit.
    static func hover(chipID: String, entered: Bool) {
        guard isEnabled else { return }
        Writer.shared.append("{\"t\":\(stamp()),\"kind\":\"hover\",\"chip\":\(quote(chipID)),\"in\":\(entered)}")
    }

    /// How long the coordinator took to actually place the bubble (including SwiftUI re-layout + setFrame).
    static func present(chipID: String, cold: Bool, elapsed: CFTimeInterval) {
        guard isEnabled else { return }
        Writer.shared.append(
            "{\"t\":\(stamp()),\"kind\":\"present\",\"chip\":\(quote(chipID))," +
            "\"cold\":\(cold),\"ms\":\(round(elapsed * 10000) / 10)}"
        )
    }

    /// Logs one line each time the whole-strip tracking area receives a pointer position, along with the computed ownership.
    ///
    /// **This is the only on-site evidence of whether "hover keeps up".** When this was changed to a single whole-strip tracking area on 2026-08-17,
    /// the first version relied on `NSTrackingArea`'s `.mouseMoved`, and measurement showed only single digits reported per 35 pointer moves
    /// (our panels are never the key window). Without this line we could only guess.
    static func pointer(x: CGFloat, chip: String?) {
        guard isEnabled else { return }
        Writer.shared.append(
            "{\"t\":\(stamp()),\"kind\":\"pointer\",\"x\":\(round(x * 10) / 10)," +
            "\"chip\":\(chip.map(quote) ?? "null")}"
        )
    }

    /// Every callback of an external drag and drop (dragging in from Finder). **Temporary diagnostic**: on 2026-09-08 the owner reported "when dragging an app onto the bar,
    /// the plus sign on the cursor keeps flashing", and the flicker can only come from the drop operation returned by `dropUpdated` alternating. This line puts
    /// "session enter/exit / pasteboard decision / two drop targets / returned operation / gap sequence number" on the same timeline,
    /// making "are we oscillating, or is the system badge itself moving" decidable. Delete after it's figured out.
    static func externalDrop(phase: String, x: CGFloat, isApp: Bool,
                             target: String, fileTarget: String,
                             operation: String, ghostIndex: Int?,
                             frozenWidth: CGFloat?, stripRect: CGRect) {
        guard isEnabled else { return }
        Writer.shared.append(
            "{\"t\":\(stamp()),\"kind\":\"extdrop\",\"phase\":\(quote(phase))," +
            "\"x\":\(round(x * 10) / 10),\"isApp\":\(isApp)," +
            "\"target\":\(quote(target)),\"fileTarget\":\(quote(fileTarget))," +
            "\"op\":\(quote(operation)),\"ghost\":\(ghostIndex.map(String.init) ?? "null")," +
            "\"frozen\":\(frozenWidth.map { String(r1($0)) } ?? "null")," +
            "\"rectX\":\(r1(stripRect.minX)),\"rectW\":\(r1(stripRect.width))}"
        )
    }

    /// Main-thread stall: scheduled to fire at 8ms, actually `lateMs` late. Only records those over 12ms, to avoid spamming itself.
    /// At 60Hz a frame is 16.7ms, so >16.7 basically means at least one dropped frame.
    static func mainLoopStall(lateMs: Double) {
        guard isEnabled, lateMs >= 12 else { return }
        Writer.shared.append("{\"t\":\(stamp()),\"kind\":\"stall\",\"lateMs\":\(round(lateMs * 10) / 10)}")
    }

    // MARK: - Click / minimize path (owner reported on 2026-08-17 "the action after clicking and minimizing stutters")

    /// The taskbar body is evaluated once. **Used to answer "how many times did one click recompute the whole strip"** --
    /// `DockStripView` subscribes to the whole `AppRuntime`, and any `@Published` change knocks the entire strip over.
    static func stripBody(items: Int, surface: String) {
        guard isEnabled else { return }
        Writer.shared.append(
            "{\"t\":\(stamp()),\"kind\":\"stripBody\",\"items\":\(items),\"surface\":\(quote(surface))}"
        )
    }

    /// One geometry / hover input of the strip arrived (`onPreferenceChange`, `ScreenRectReader`, the
    /// hovered-entry write). `changed` separates "the callback fired" from "the value really moved".
    /// Read next to `stripBody`: it is the only way to tell which input a body evaluation followed —
    /// but several inputs can fold into one refresh, so the pairing is a correlation, not a cause.
    static func stripInput(_ name: String, surface: String, changed: @autoclosure () -> Bool) {
        guard isEnabled else { return }   // the comparison behind `changed` runs only when tracing
        Writer.shared.append(
            "{\"t\":\(stamp()),\"kind\":\"stripInput\",\"name\":\(quote(name))," +
            "\"surface\":\(quote(surface)),\"changed\":\(changed())}"
        )
    }

    /// How long one named stretch of main-thread work took (`defer`-friendly: pass the start time,
    /// taken with `HoverTrace.now()` so the clock is not read when tracing is off).
    /// Only recorded above 1ms so a quiet path never floods the file.
    static func now() -> CFTimeInterval { isEnabled ? CACurrentMediaTime() : 0 }
    static func span(_ name: String, since start: CFTimeInterval) {
        guard isEnabled else { return }
        let ms = (CACurrentMediaTime() - start) * 1000
        guard ms >= 1 else { return }
        Writer.shared.append("{\"t\":\(stamp()),\"kind\":\"span\",\"name\":\(quote(name)),\"ms\":\(round(ms * 10) / 10)}")
    }

    /// `DragController` actually published `landing` (its token changed: a flight began or ended).
    /// Mid-flight retargets are `landingRetarget`, not this — they rewrite the flight without publishing.
    static func landingPublish() {
        guard isEnabled else { return }
        Writer.shared.append("{\"t\":\(stamp()),\"kind\":\"landingPublish\"}")
    }

    /// One `relayout`: how long synchronously measuring the whole strip width took, what was measured, whether it changed from last time, and whether it was animated.
    ///
    /// **`changed:false` with `animated:true` is pure waste** -- the width didn't change yet a window size animation still runs,
    /// and every frame of that animation has to redraw the glass backplate and stroke. This was the prime suspect this round.
    static func relayout(measureMs: CFTimeInterval, width: CGFloat, changed: Bool, animated: Bool,
                         timing: String = "standard") {
        guard widthProbesEnabled else { return }
        Writer.shared.append(
            "{\"t\":\(stamp()),\"kind\":\"relayout\",\"measureMs\":\(round(measureMs * 10000) / 10)," +
            "\"width\":\(round(width * 10) / 10),\"changed\":\(changed),\"animated\":\(animated)," +
            "\"timing\":\(quote(timing))}"
        )
    }

    /// Per-frame width probe (outputs only while trace is on): `who` = "panel" (live width of the AppKit window frame) or
    /// "content" (live layout width of the SwiftUI strip content). Viewing the two curves side by side shows whether content and backplate move in sync on the same curve.
    static func width(_ who: String, _ width: CGFloat) {
        guard widthProbesEnabled else { return }
        Writer.shared.append("{\"t\":\(stamp()),\"kind\":\"width\",\"who\":\(quote(who)),\"w\":\(round(width * 10) / 10)}")
    }

    /// Panel frames fully equal -> the whole animation group is skipped. **This is the evidence that the waste above was truly plugged**,
    /// which the `relayout` count alone can't show (the short-circuit happens downstream in `setFrames`).
    static func framesUnchanged() {
        guard isEnabled else { return }
        Writer.shared.append("{\"t\":\(stamp()),\"kind\":\"framesSkipped\"}")
    }

    /// Time-window markers for user actions. Without them, a pile of stalls in the log can't be attributed to anyone.
    static func action(_ kind: String, phase: String) {
        guard widthProbesEnabled else { return }
        Writer.shared.append("{\"t\":\(stamp()),\"kind\":\"action\",\"what\":\(quote(kind)),\"phase\":\(quote(phase))}")
    }

    // MARK: - Dragging (owner reported on 2026-08-18 "dragging from the drawer into the taskbar doesn't easily push other icons apart / two shadows appear")

    /// While a drawer icon is dragged toward the taskbar, logs a line capturing the decision state at **every cursor position update**.
    ///
    /// The reason for this one is the same as `pointer`: the promotion decision is a chain of `guard`s, and if any fails it returns silently,
    /// which from outside all looks like "no reaction". Without this line we can only guess whether it's geometry, mode, or the drop target.
    /// `enter` / `clearlyOut` are the two booleans of that hysteresis box, and `mode` is `DrawerDragOutMode`.
    static func drawerToStrip(x: CGFloat, y: CGFloat,
                              strip: CGRect,
                              enter: Bool, clearlyOut: Bool,
                              mode: String, converted: Bool) {
        guard isEnabled else { return }
        Writer.shared.append(
            "{\"t\":\(stamp()),\"kind\":\"d2s\",\"x\":\(r1(x)),\"y\":\(r1(y))," +
            "\"sx\":\(r1(strip.minX)),\"sy\":\(r1(strip.minY))," +
            "\"sw\":\(r1(strip.width)),\"sh\":\(r1(strip.height))," +
            "\"enter\":\(enter),\"out\":\(clearlyOut),\"mode\":\(quote(mode)),\"conv\":\(converted)}"
        )
    }

    /// Staged drop target at the moment of promotion / rollback. **`target` null = the whole block lands at the end of the live area**,
    /// and since the taskbar width is frozen during promotion, landing at the end is often clipped outside the visible area, which looks like "nothing happened".
    static func drawerToStripStage(bundleID: String, target: String?, after: Bool) {
        guard isEnabled else { return }
        Writer.shared.append(
            "{\"t\":\(stamp()),\"kind\":\"d2sStage\",\"bid\":\(quote(bundleID))," +
            "\"target\":\(target.map(quote) ?? "null"),\"after\":\(after)}"
        )
    }

    /// Who is "the card the carrier draws" and who is "the card hidden on the strip" while in the promoted state.
    /// **Both must have values at the same time**, otherwise the card on the strip is drawn opaque while another is held in hand = two shadows.
    static func carrierRepresentative(rep: String?, hidden: String?) {
        guard isEnabled else { return }
        Writer.shared.append(
            "{\"t\":\(stamp()),\"kind\":\"carrierRep\"," +
            "\"rep\":\(rep.map(quote) ?? "null"),\"hidden\":\(hidden.map(quote) ?? "null")}"
        )
    }

    /// The whole-block continuous reflow after promotion: whether a drop target was found this time. `target` null = the cursor isn't over any
    /// live card (outside the strip, in the messaging area / folder area, or between cards), so **the whole block stays put**.
    static func stripBlockReorder(target: String?, after: Bool, why: String) {
        guard isEnabled else { return }
        Writer.shared.append(
            "{\"t\":\(stamp()),\"kind\":\"blockReorder\",\"target\":\(target.map(quote) ?? "null")," +
            "\"after\":\(after),\"why\":\(quote(why))}"
        )
    }

    /// How long each step took on the frame where the drag starts (owner reported on 2026-08-18 "the first frame of dragging a selected icon stutters").
    /// `carrierCreated` = whether the carrier panel was freshly created this time -- building the panel also builds a SwiftUI host tree,
    /// and only the first drag of the whole session pays that cost; this is what distinguishes "stutters every time" from "only the first time".
    /// `prepared` = whether candidates were prepared at the moment of press (texture already uploaded, released in the drag-start round); false = took the
    /// fallback of "hold the card and wait two display frames" -- in normal dragging it should almost never appear.
    static func dragStart(totalMs: Double, carrierMs: Double, carrierCreated: Bool, prepared: Bool) {
        guard isEnabled else { return }
        Writer.shared.append(
            "{\"t\":\(stamp()),\"kind\":\"dragStart\",\"ms\":\(round(totalMs * 10) / 10)," +
            "\"carrierMs\":\(round(carrierMs * 10) / 10),\"created\":\(carrierCreated)," +
            "\"prepared\":\(prepared)}"
        )
    }

    /// How long capturing one carrier bitmap took and how large it came out.
    ///
    /// At drag start it is captured synchronously on the main thread, so it counts directly toward "does the first frame stutter". The spike measured a median of 0.59ms,
    /// P95 0.87ms (budget 8ms); if it exceeds this on real hardware, move the snapshot to a pre-capture at the mouse-down timing of `chipPressGesture`.
    /// `w`/`h` are the logical size including the outward expansion; `ok:false` = rendering failed, and that drag is rejected outright.
    static func carrierSnapshot(ms: Double, width: CGFloat, height: CGFloat, ok: Bool) {
        guard isEnabled else { return }
        Writer.shared.append(
            "{\"t\":\(stamp()),\"kind\":\"snapshot\",\"ms\":\(round(ms * 10) / 10)," +
            "\"w\":\(r1(width)),\"h\":\(r1(height)),\"ok\":\(ok)}"
        )
    }

    /// Anomalous moments on the drag-start path.
    ///
    /// After the carrier became a bitmap, "when the card on the strip gets hidden" is no longer a race (`beginDrag` synchronously puts the bitmap
    /// exactly in the card's slot), so the former `slotHidden` / `carrierDrawn` moments are gone. Only one value remains:
    /// `noSnapshot` -- the bitmap failed to be captured and that drag is rejected outright (better not to drag than to hold thin air).
    static func dragHandoff(_ what: String, msSinceBegin: Double) {
        guard isEnabled else { return }
        Writer.shared.append(
            "{\"t\":\(stamp()),\"kind\":\"handoff\",\"what\":\(quote(what))," +
            "\"ms\":\(round(msSinceBegin * 10) / 10)}"
        )
    }

    /// Landing precision: how far the carrier's final resting position is from the slot anchor (in carrier-panel coordinates, pt).
    ///
    /// **This is the only quantitative basis for whether the "landing ghosting" is truly cured.** The previous version could not tell "5pt off" from
    /// "motion blur" by eye and could only guess repeatedly; this turns it into a countable fact in the log. Only records > 0.5pt.
    static func landingDelta(dx: CGFloat, dy: CGFloat) {
        guard isEnabled, hypot(dx, dy) > 0.5 else { return }
        Writer.shared.append(
            "{\"t\":\(stamp()),\"kind\":\"landingDelta\",\"dx\":\(r1(dx)),\"dy\":\(r1(dy))}"
        )
    }

    /// The landing anchor is written (`DragController.setLandingAnchor`). **After release the pointer produces no more events,
    /// so this is the only thing that shows "is the anchor still moving, and where did it go"** -- and it does move: after the strip width unfreezes
    /// the whole strip re-centers and the drawer panel slides left with it for 0.22s. `owner` distinguishes whether the taskbar or the drawer wrote it.
    static func landingAnchor(owner: String, rect: CGRect?) {
        guard isEnabled else { return }
        let r = rect.map { "[\(r1($0.minX)),\(r1($0.minY)),\(r1($0.width)),\(r1($0.height))]" } ?? "null"
        Writer.shared.append(
            "{\"t\":\(stamp()),\"kind\":\"landingAnchor\",\"owner\":\"\(owner)\",\"rect\":\(r)}"
        )
    }

    /// Dragging a messaging app from the drawer into the messaging area: **one record per tick**, to be compared with `d2s`.
    /// `stop` is which guard it got stuck on (`ok` = this tick really released), and `zone` is the computed messaging-area range
    /// (`fallback` means the messaging area was empty at that time and fell back to the 56pt box at the head of the strip).
    /// `inSnapshot` / `running` **must be recorded together**: authorization release looks at the window inventory (`runtime.snapshot`),
    /// while the messaging area's visibility and the running dot under the icon look at `RunningApplicationStore` (the NSWorkspace process projection).
    /// They are not the same source of truth, and the divergence is exactly the suspect behind "the icon clearly has a running dot, yet can't be dragged into the messaging area".
    static func drawerToMessaging(bid: String, x: CGFloat, y: CGFloat, zone: CGRect?, fallback: Bool,
                                  mode: String, inSnapshot: Bool, running: Bool,
                                  inZone: Bool, released: Bool, stop: String) {
        guard isEnabled else { return }
        let z = zone.map { "[\(r1($0.minX)),\(r1($0.minY)),\(r1($0.width)),\(r1($0.height))]" } ?? "null"
        Writer.shared.append(
            "{\"t\":\(stamp()),\"kind\":\"d2m\",\"bid\":\"\(bid)\",\"x\":\(r1(x)),\"y\":\(r1(y)),\"zone\":\(z),"
            + "\"fallback\":\(fallback),\"mode\":\"\(mode)\",\"snap\":\(inSnapshot),\"run\":\(running),"
            + "\"inZone\":\(inZone),\"released\":\(released),\"stop\":\"\(stop)\"}"
        )
    }

    /// **Re-targeting the endpoint** mid-flight. The landing anchor keeps updating during flight (the slot/grid make-way animation hasn't finished),
    /// and `retargetLandingIfNeeded` re-issues the animation with the changed endpoint. If changed too far, the user sees a polyline
    /// (owner 2026-08-20: "first floats to the right of the target position, then goes to the target position").
    /// Only this line turns "how many times it re-targeted and by how much each time" into a countable fact in the log -- `landing` is recorded only once at takeoff.
    static func landingRetarget(from: CGPoint, to: CGPoint, previous: CGPoint) {
        guard isEnabled else { return }
        Writer.shared.append(
            "{\"t\":\(stamp()),\"kind\":\"landingRetarget\",\"from\":[\(r1(from.x)),\(r1(from.y))],"
            + "\"to\":[\(r1(to.x)),\(r1(to.y))],\"prev\":[\(r1(previous.x)),\(r1(previous.y))],"
            + "\"shift\":\(r1(hypot(to.x - previous.x, to.y - previous.y)))}"
        )
    }

    /// **Invariant self-check**: the slot on the strip is already empty but the copy isn't on screen -- at this moment the user sees "the icon vanishes into thin air".
    /// Turns "occasionally happens" into a record that can be tallied afterwards, with no more guessing from screenshots.
    static func carrierGap(reason: String, alpha: Double, hostX: CGFloat, hostY: CGFloat) {
        guard isEnabled else { return }
        Writer.shared.append(
            "{\"t\":\(stamp()),\"kind\":\"GAP\",\"why\":\(quote(reason))," +
            "\"alpha\":\(round(alpha * 100) / 100),\"hx\":\(r1(hostX)),\"hy\":\(r1(hostY))}"
        )
    }

    /// Whether the side-effect path `reconcileLiveOrder` got a **fresh** projection this round.
    ///
    /// This is direct evidence of the 2026-08-18 pitfall and deserves to stay: when the old-style `onChange(of:perform:)` fires it
    /// runs the closure installed on the previous frame, so the projection is one generation behind -- rendering already has this card while `sync` doesn't yet,
    /// so the staged drop target of the drawer promotion was never consumed even once. `carried=true` with `has=false` means it has recurred.
    static func orderSync(count: Int, carriedID: String?, hasCarried: Bool) {
        guard isEnabled else { return }
        Writer.shared.append(
            "{\"t\":\(stamp()),\"kind\":\"orderSync\",\"n\":\(count)," +
            "\"carried\":\(carriedID.map(quote) ?? "null"),\"has\":\(hasCarried)}"
        )
    }

    /// The visible order after the ordering layer actually places the card (logged only when drag diagnostics are on). The final basis for deciding "which slot the gap actually opened at".
    static func liveOrder(_ ids: [String]) {
        guard isEnabled else { return }
        Writer.shared.append(
            "{\"t\":\(stamp()),\"kind\":\"liveOrder\",\"ids\":[\(ids.map(quote).joined(separator: ","))]}"
        )
    }

    /// The settle-back flight after release: start, end, and whether an anchor was obtained.
    /// `to` null = no drop anchor, so it takes the instant finish (old behavior).
    static func landing(from: CGPoint, to: CGPoint?, source: String) {
        guard isEnabled else { return }
        let target = to.map { "[\(r1($0.x)),\(r1($0.y))]" } ?? "null"
        Writer.shared.append(
            "{\"t\":\(stamp()),\"kind\":\"landing\",\"from\":[\(r1(from.x)),\(r1(from.y))]," +
            "\"to\":\(target),\"src\":\(quote(source))}"
        )
    }

    /// An outside drag's image swapped over the drawer: the source frame and its icon (receiver
    /// coordinates), the pointer, and the cell frame asked for.
    static func dragImageSwap(source: CGRect, icon: CGRect?, pointer: CGPoint, target: CGRect, validItems: Int) {
        guard isEnabled else { return }
        func rect(_ r: CGRect) -> String { "[\(r1(r.minX)),\(r1(r.minY)),\(r1(r.width)),\(r1(r.height))]" }
        Writer.shared.append(
            "{\"t\":\(stamp()),\"kind\":\"extswap\",\"source\":\(rect(source)),\"icon\":\(icon.map(rect) ?? "null")," +
            "\"pointer\":[\(r1(pointer.x)),\(r1(pointer.y))],\"target\":\(rect(target)),\"valid\":\(validItems)}"
        )
    }

    private static func r1(_ value: CGFloat) -> Double { (Double(value) * 10).rounded() / 10 }

    private static func stamp() -> Double { round(CACurrentMediaTime() * 10000) / 10 }

    private static func quote(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    private final class Writer {
        static let shared = Writer()
        private let queue = DispatchQueue(label: "app.neobar.NeoBar.hovertrace")

        func append(_ line: String) {
            queue.async { [self] in
                guard let fileURL, let data = (line + "\n").data(using: .utf8) else { return }
                if let handle = try? FileHandle(forWritingTo: fileURL) {
                    defer { try? handle.close() }
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                } else {
                    try? data.write(to: fileURL)
                }
            }
        }

        private lazy var fileURL: URL? = {
            let fm = FileManager.default
            guard let base = fm.urls(for: .libraryDirectory, in: .userDomainMask).first else { return nil }
            let dir = base.appendingPathComponent("Logs/app.neobar.NeoBar", isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir.appendingPathComponent("hover-trace.jsonl")
        }()
    }
}
