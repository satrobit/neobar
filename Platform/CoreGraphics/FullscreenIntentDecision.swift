import CoreGraphics
import Foundation
import os.lock

enum FullscreenIntentSource: String, Equatable {
    case greenButton
    case keyboardShortcut
}

struct FullscreenIntentSnapshot: Equatable {
    let generation: UInt64
    let pid: pid_t
    let focusedWindowID: CGWindowID
    let buttonFrame: CGRect
    let windowFrame: CGRect
    let screenCGFrame: CGRect
    /// Displays that have a task strip (multiple under routes 3/4). If the display of the focused window isn't among them -> there's no strip to hide, so no request is sent.
    /// **Can't use `Set<CGRect>`**: `CGRect`'s `Hashable` is a macOS 15+ conformance (`AGENTS.md` iron rule).
    let panelScreenCGFrames: [CGRect]
    let isFullscreen: Bool
    let buttonEnabled: Bool
}

struct FullscreenIntentRequest: Equatable {
    let source: FullscreenIntentSource
    let cacheGeneration: UInt64
    let pid: pid_t
    let focusedWindowID: CGWindowID
    let screenCGFrame: CGRect
}

enum FullscreenIntentDecision {
    static let ansiFKeyCode = CGKeyCode(3)

    private static let intentModifiers: CGEventFlags = [
        .maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn, .maskHelp,
        .maskNumericPad
    ]

    static func normalizedModifiers(_ flags: CGEventFlags) -> CGEventFlags {
        flags.intersection(intentModifiers)
    }

    static func greenButtonRequest(
        location: CGPoint,
        flags: CGEventFlags,
        snapshot: FullscreenIntentSnapshot?
    ) -> FullscreenIntentRequest? {
        guard let snapshot,
              snapshot.buttonEnabled,
              !snapshot.isFullscreen,
              snapshot.panelScreenCGFrames.contains(snapshot.screenCGFrame),
              normalizedModifiers(flags).isEmpty,
              snapshot.buttonFrame.contains(location) else {
            return nil
        }
        return request(source: .greenButton, snapshot: snapshot)
    }

    static func shortcutRequest(
        keyCode: CGKeyCode,
        flags: CGEventFlags,
        isRepeat: Bool,
        snapshot: FullscreenIntentSnapshot?
    ) -> FullscreenIntentRequest? {
        guard let snapshot,
              snapshot.buttonEnabled,
              !snapshot.isFullscreen,
              snapshot.panelScreenCGFrames.contains(snapshot.screenCGFrame),
              !isRepeat,
              keyCode == ansiFKeyCode,
              normalizedModifiers(flags) == [.maskCommand, .maskControl] else {
            return nil
        }
        return request(source: .keyboardShortcut, snapshot: snapshot)
    }

    static func isEnabled(
        settingEnabled: Bool,
        environment: [String: String]
    ) -> Bool {
        settingEnabled && DebugSwitch.fullscreenIntent.isEnabled(in: environment)
    }

    private static func request(
        source: FullscreenIntentSource,
        snapshot: FullscreenIntentSnapshot
    ) -> FullscreenIntentRequest {
        FullscreenIntentRequest(
            source: source,
            cacheGeneration: snapshot.generation,
            pid: snapshot.pid,
            focusedWindowID: snapshot.focusedWindowID,
            screenCGFrame: snapshot.screenCGFrame
        )
    }
}

enum SpaceSwitchDirection: String, Equatable {
    case left
    case right
}

/// Snapshot of the Space layout on one display (a pure-data projection of SkyLight `SLSCopyManagedDisplaySpaces`).
struct SpaceLayoutSnapshot: Equatable {
    /// Space ids in Mission Control's left-to-right order.
    let orderedSpaceIDs: [Int]
    /// Set of ids of fullscreen Spaces (`type == 4`).
    let fullscreenSpaceIDs: Set<Int>
    let currentSpaceID: Int

    static let fullscreenSpaceType = 4

    /// Whether the adjacent Space in the target direction is a fullscreen Space. **This gate is the premise of the whole predictive hide**:
    /// without it, switching between two ordinary desktops would also hide the task strip briefly, where there was never any problem.
    /// The precondition "currently not in a fullscreen Space" was added 2026-08-31: fullscreen -> fullscreen has nothing to hide
    /// (the strip is already hidden), and is left to the existing hold mechanism.
    ///
    /// **The reverse (predictive reveal for fullscreen -> desktop) was built and then withdrawn** (2026-08-31, owner's call: "stability first"):
    /// it relies on guessing the gesture, and in a fullscreen Space three-finger gestures are far more than "swipe back to desktop" -- a wrong guess made the strip pop up on a fullscreen picture out of nowhere,
    /// and when the AX read failed it could get stuck without retracting. Swiping back to the desktop = after arrival, a stable fade-in (~0.5s) after the hold's final review, no prediction.
    /// Condition for reconsidering: the system provides a **pre-switch notification** for Space changes (a real signal, not a guessed gesture).
    func neighborIsFullscreen(_ direction: SpaceSwitchDirection) -> Bool {
        guard !fullscreenSpaceIDs.contains(currentSpaceID),
              let index = orderedSpaceIDs.firstIndex(of: currentSpaceID) else { return false }
        let neighbor = direction == .right ? index + 1 : index - 1
        guard orderedSpaceIDs.indices.contains(neighbor) else { return false }
        return fullscreenSpaceIDs.contains(orderedSpaceIDs[neighbor])
    }

    var hasAnyFullscreenNeighbor: Bool {
        neighborIsFullscreen(.left) || neighborIsFullscreen(.right)
    }
}

/// Directory of Space layouts for all displays (multi-display task strip, 2026-09-02). Space switches happen per display: a three-finger swipe acts on
/// the display under the cursor, Control+←/→ acts on the display with keyboard focus; predictive hide must first locate that display.
struct SpaceLayoutDirectory: Equatable {
    struct Entry: Equatable {
        let displayUUID: String
        /// AppKit coordinates (`NSScreen.frame`), used to locate the display by `NSEvent.mouseLocation`.
        let appKitFrame: CGRect
        let layout: SpaceLayoutSnapshot
    }

    let entries: [Entry]

    /// Fast path on the event thread: only continue if any display has a fullscreen Space on either side.
    var hasAnyFullscreenNeighbor: Bool {
        entries.contains { $0.layout.hasAnyFullscreenNeighbor }
    }

    func entry(containing point: CGPoint) -> Entry? {
        entries.first { $0.appKitFrame.contains(point) }
    }

    func entry(forDisplayUUID uuid: String) -> Entry? {
        entries.first { $0.displayUUID == uuid }
    }

    /// Displays whose adjacent Space in the target direction is a fullscreen Space (candidates for the Control+←/→ path).
    func displays(withFullscreenNeighbor direction: SpaceSwitchDirection) -> [Entry] {
        entries.filter { $0.layout.neighborIsFullscreen(direction) }
    }

    /// Which display Control+←/→ lands on: if there's a single candidate it is that one; with multiple candidates take the one under the mouse (the keyboard-focus display can't be read,
    /// the mouse is the best approximation); if none contains the mouse take the first; no candidates -> nil (gate closed).
    func arrowTarget(_ direction: SpaceSwitchDirection, mouseLocation: CGPoint) -> Entry? {
        let candidates = displays(withFullscreenNeighbor: direction)
        guard !candidates.isEmpty else { return nil }
        if candidates.count == 1 { return candidates[0] }
        return candidates.first { $0.appKitFrame.contains(mouseLocation) } ?? candidates[0]
    }
}

/// Pure state machine for a three-finger horizontal swipe. Feed it once per gesture event in the event stream; it emits a direction when the conditions are met.
///
/// The criteria come from measurements on 2026-08-09 (samples in the diagnostics archive): **>=3 fingers + horizontal displacement > threshold + horizontal displacement dominating vertical displacement**.
/// - Using only "horizontal > threshold" falsely hits three-finger up/down swipes (1 in 10); adding "horizontal > vertical" excluded all of them, 10/10.
/// - Thresholds 0.03 / 0.05 / 0.08 give identical results -- the signal separates on its own and isn't something tuned into place.
/// - Everyday two-finger scrolls / clicks / cursor moves (about a 45-second sample) never trigger it: they can't muster three fingers.
struct SpaceSwipeTracker: Equatable {
    static let minimumTouches = 3
    static let horizontalThreshold = 0.05
    /// If no valid sample arrives for longer than this interval, re-anchor. **It is required**: about a third of gesture events
    /// (magnify and the like) carry no touch data at all, and "no data in this one" must not be treated as "fingers lifted",
    /// otherwise a swipe sequence would be interrupted over and over, the anchor reset forever, and the criteria would never hold.
    static let burstGap: TimeInterval = 0.4

    private var anchorX: Double?
    private var anchorY: Double?
    private var lastSampleAt: TimeInterval?
    private var firedInThisBurst = false

    mutating func reset() {
        anchorX = nil
        anchorY = nil
        lastSampleAt = nil
        firedInThisBurst = false
    }

    /// - Parameter naturalScrolling: the system "natural scrolling". Measured (14/14 consistent): with natural scrolling
    ///   **swiping fingers left goes to the Space on the right**, so direction is opposite to the displacement sign; with natural scrolling off the signs match.
    mutating func consume(
        touches: Int,
        x: Double,
        y: Double,
        at now: TimeInterval,
        naturalScrolling: Bool
    ) -> SpaceSwitchDirection? {
        if let last = lastSampleAt, now - last > Self.burstGap { reset() }
        guard touches >= Self.minimumTouches else {
            reset()
            return nil
        }
        lastSampleAt = now
        guard let ax = anchorX, let ay = anchorY else {
            anchorX = x
            anchorY = y
            return nil
        }
        guard !firedInThisBurst else { return nil }
        let dx = x - ax
        let dy = y - ay
        guard abs(dx) > Self.horizontalThreshold, abs(dx) > abs(dy) else { return nil }
        firedInThisBurst = true
        let movesRight = naturalScrolling ? (dx < 0) : (dx > 0)
        return movesRight ? .right : .left
    }
}

/// Predictive hide for Control+←/→ Space switching. **Promoted, on by default**; turn it off with `DOCK_SPACE_INTENT=0`
/// (decided in `spaceSwitchEnabled` of `FullscreenIntentMonitor`).
///
/// ⚠️ This section long said "experimental, `DOCK_SPACE_INTENT_EXPERIMENT=1`, off by default, doesn't check the adjacent Space".
/// That was the description when the project was started on 2026-08-09 and **has long been void**: no code anywhere in the repo reads that environment variable,
/// and the adjacent-Space gate has since been added and is a hard condition. Corrected 2026-08-19 -- a comment this stale would lead the next person
/// investigating "fullscreen switch flicker" straight to the wrong conclusion that "this feature isn't enabled at all".
///
/// The question to answer when the project started: arrow key presses come about `548–575ms` before the Space actually switches (measured and archived); is that lead time
/// enough to eliminate the flicker of "ordinary desktop -> fullscreen Space". The two routes measured to be dead ends are the managed-space prediction
/// (only about 30ms early) and the fast AX probe (0.2–1ms after the Space notification), both later than WindowServer's transition snapshot.
///
/// **The adjacent-Space gate is a hard condition**: predict only if the adjacent Space in the target direction really is a fullscreen Space; otherwise pressing arrow keys between two ordinary desktops
/// would hide the strip for nothing. This gate is already decided in `FullscreenIntentMonitor`
/// (`SLSCopyManagedDisplaySpaces`, matched by display UUID, never by array order).
enum FullscreenSpaceSwitchDecision {
    static let leftArrowKeyCode = CGKeyCode(123)
    static let rightArrowKeyCode = CGKeyCode(124)

    /// **A physical arrow key inherently carries the three flags `Fn + numeric keypad + nonCoalesced`** (measured and archived 2026-08-09),
    /// even when the user presses no additional key. So the normalization of `FullscreenIntentDecision` can't be reused here
    /// (it counts Fn / numeric keypad as user modifiers) -- it would never match, producing a
    /// "triggers nothing" false negative, which is very easily read as "the lead time isn't enough, this route is a dead end".
    private static let userModifiers: CGEventFlags = [
        .maskCommand, .maskControl, .maskAlternate, .maskShift, .maskHelp
    ]

    static func normalizedModifiers(_ flags: CGEventFlags) -> CGEventFlags {
        flags.intersection(userModifiers)
    }

    static func arrowDirection(
        keyCode: CGKeyCode,
        flags: CGEventFlags,
        isRepeat: Bool
    ) -> SpaceSwitchDirection? {
        guard !isRepeat, normalizedModifiers(flags) == [.maskControl] else { return nil }
        switch keyCode {
        case leftArrowKeyCode: return .left
        case rightArrowKeyCode: return .right
        default: return nil
        }
    }

    static func isSpaceSwitchArrow(
        keyCode: CGKeyCode,
        flags: CGEventFlags,
        isRepeat: Bool
    ) -> Bool {
        arrowDirection(keyCode: keyCode, flags: flags, isRepeat: isRepeat) != nil
    }
}

struct FullscreenIntentRefreshCoalescer: Equatable {
    enum Completion: Equatable {
        case ignored
        case idle
        case start(UInt64)
    }

    private(set) var activeToken: UInt64?
    private(set) var needsTrailingRefresh = false
    private var nextToken: UInt64 = 0

    mutating func request() -> UInt64? {
        guard activeToken == nil else {
            needsTrailingRefresh = true
            return nil
        }
        return begin()
    }

    mutating func complete(token: UInt64) -> Completion {
        guard activeToken == token else { return .ignored }
        if needsTrailingRefresh {
            needsTrailingRefresh = false
            let trailingToken = begin()
            return .start(trailingToken)
        }
        activeToken = nil
        return .idle
    }

    mutating func reset() {
        activeToken = nil
        needsTrailingRefresh = false
    }

    private mutating func begin() -> UInt64 {
        nextToken &+= 1
        activeToken = nextToken
        return nextToken
    }
}

enum FullscreenIntentCacheDecision {
    static func shouldApplyRefresh(
        started: Bool,
        expectedObservation: UInt64,
        currentObservation: UInt64,
        expectedCache: UInt64,
        currentCache: UInt64,
        requestedPID: pid_t,
        activePID: pid_t?
    ) -> Bool {
        started
            && expectedObservation == currentObservation
            && expectedCache == currentCache
            && requestedPID == activePID
    }

    static func isCurrentRequest(
        _ request: FullscreenIntentRequest,
        snapshot: FullscreenIntentSnapshot?,
        activePID: pid_t?,
        started: Bool
    ) -> Bool {
        guard started, activePID == request.pid, let snapshot else { return false }
        return snapshot.generation == request.cacheGeneration
            && snapshot.pid == request.pid
            && snapshot.focusedWindowID == request.focusedWindowID
            && snapshot.screenCGFrame == request.screenCGFrame
    }
}

struct FullscreenEventTapRecoveryPolicy: Equatable {
    static let window: TimeInterval = 60
    static let maximumReenables = 3

    private(set) var disableTimes: [TimeInterval] = []
    private(set) var isFused = false

    mutating func recordDisable(at now: TimeInterval) -> Bool {
        guard !isFused else { return false }
        disableTimes.removeAll { now - $0 > Self.window }
        guard disableTimes.count < Self.maximumReenables else {
            isFused = true
            return false
        }
        disableTimes.append(now)
        return true
    }
}

final class FullscreenIntentHandoffGate {
    enum State: Equatable {
        case pending
        case executing
        case completed
        case cancelled
    }

    private var lock = os_unfair_lock_s()
    private var state: State = .pending

    func beginExecution() -> Bool {
        withLock {
            guard state == .pending else { return false }
            state = .executing
            return true
        }
    }

    func complete() {
        withLock {
            guard state == .executing else { return }
            state = .completed
        }
    }

    @discardableResult
    func cancelIfPending() -> Bool {
        withLock {
            guard state == .pending else { return false }
            state = .cancelled
            return true
        }
    }

    var currentState: State { withLock { state } }

    private func withLock<T>(_ body: () -> T) -> T {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return body()
    }
}
