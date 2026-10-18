import ApplicationServices
import CoreGraphics

enum PanelVisibilityReason: Hashable {
    case fullscreen
    case fullscreenTransitionPending
    case edgeAutoHide
}

enum FullscreenSpaceHoldDisposition: Equatable {
    case apply
    case hold
    case stale
}

enum FullscreenSpaceHoldDecision {
    static let postSpaceConfirmationDelay: TimeInterval = 0.12
    static let activationFallbackDelay: TimeInterval = 0.5

    static func shouldBegin(isFullscreen: Bool, hasInputIntent: Bool) -> Bool {
        isFullscreen && !hasInputIntent
    }

    static func disposition(
        isFullscreenVerdict: Bool,
        expectedGeneration: UInt64?,
        activeGeneration: UInt64?,
        isFinalWindowedConfirmation: Bool
    ) -> FullscreenSpaceHoldDisposition {
        guard let activeGeneration else {
            return expectedGeneration == nil ? .apply : .stale
        }
        guard expectedGeneration == activeGeneration else { return .stale }
        // While the hold is alive, **no non-final verdict is let through**, not even true. The original wording
        // (true means .apply) would let a false true, reported by CG lagging 0.4~0.8s at the instant of exiting fullscreen,
        // destroy the 120ms confirmation hold at the root; the correct AX false that follows would then be judged .stale because the hold is dead
        // and silently dropped, leaving the strip to wait for the 5-second reconcile fallback: "the strip takes 2~3 seconds to come back after leaving fullscreen" (2026-08-30
        // measured; fingerprint: no space-ax line after space-cg true, the reveal line is 5.098s after the previous ax line,
        // `Docs/05`). During the hold the state is already .fullscreen, so true has nothing to do; endure 120ms
        // and let the final CG+AX verdict decide. A fullscreen-to-fullscreen switch just confirms 120ms later, and the strip is hidden during that time anyway.
        if isFinalWindowedConfirmation { return .apply }
        return .hold
    }
}

/// A hide decided by the frame≈screen fallback (a screen-covering overlay without the AXFullScreen
/// flag, e.g. LaunchOS's full-screen launcher) has no event that ends it: the app may order the window
/// out without changing the active application, so the bar would otherwise wait for the 5s reconcile.
/// While hidden that way the window is watched through one single-window CG query per tick; the moment
/// it is gone, off screen or no longer covering the screen, the AX verdict is re-run.
enum OverlayWindowWatch {
    static let tickInterval: TimeInterval = 0.25

    /// `isOnscreen == nil` means the window no longer exists.
    static func shouldRecheck(isOnscreen: Bool?, bounds: CGRect?, screenCGFrame: CGRect) -> Bool {
        guard let isOnscreen, isOnscreen, let bounds else { return true }
        let t = FullscreenWindowClassifier.frameTolerance
        return abs(bounds.width - screenCGFrame.width) >= t
            || abs(bounds.height - screenCGFrame.height) >= t
            || abs(bounds.minX - screenCGFrame.minX) >= t
            || abs(bounds.minY - screenCGFrame.minY) >= t
    }
}

/// Membership repair for "Show on all desktops" (issue #19).
///
/// macOS, **at the moment a fullscreen space is destroyed, re-attaches the `.canJoinAllSpaces` window that is hidden at that time
/// to only the current desktop**, and the other desktops can no longer see it. Reproduced on 2026-08-28 with an 80-line standalone experiment
/// unrelated to this project (`scratch/space_membership_lab2.swift`), so this is not a NeoBar bug,
/// but the victim is exactly our "orderOut on entering fullscreen / orderFrontRegardless on exiting fullscreen" make-way mechanism.
///
/// Approaches that fail to restore it (all tested): `orderFrontRegardless`, assigning the same `collectionBehavior`
/// again, `orderOut` + reset + `orderFront`. **The only shape that works is: change to another value → let it pass one round of
/// runloop → assign it back**, and **a single attempt isn't guaranteed to succeed** (1 of 3 experiment rounds needed two repairs), so it must be
/// verified by reading back + retrying; it can't be a one-shot.
enum AllSpacesMembership {
    static let maxRepairAttempts = 3
    /// How long to wait after assigning back before reading back to verify. Measured: 120ms is enough for WindowServer to settle.
    static let verifyDelay: TimeInterval = 0.12

    /// Which ordinary desktops this window is still missing (fullscreen spaces don't count: the window shouldn't be pinned to someone else's fullscreen space anyway).
    /// Empty array = healthy. With fewer than 2 `desktopSpaceIDs` it always returns empty: with a single desktop there is no "lost desktop".
    static func missingSpaceIDs(windowSpaceIDs: [Int], desktopSpaceIDs: [Int]) -> [Int] {
        guard desktopSpaceIDs.count > 1 else { return [] }
        let owned = Set(windowSpaceIDs)
        return desktopSpaceIDs.filter { !owned.contains($0) }.sorted()
    }

    static func shouldRetry(attempt: Int) -> Bool { attempt < maxRepairAttempts }
}

enum EdgeAutoHideInhibitor: Hashable {
    case dragging
    case drawerOpen
    case folderPopupOpen
    /// The NeoBar menu (the one popped up from the status bar icon or the strip's right-click) is open.
    /// Without blocking, in the auto-hide tiers the idle timer keeps running and the strip would shrink away from under the menu.
    case taskbarMenuOpen
    /// A height drag is in progress on this unit's bar. Past the top clamp the pointer leaves
    /// the panel rect while the button is still down; without this the idle-hide timer
    /// hides the bar out from under the drag. Set only on the unit being dragged: an
    /// inhibitor also clears an existing auto-hide, so putting it on every unit would wake
    /// bars that other screens had hidden.
    case interactiveResize
}

struct PanelVisibilityState: Equatable {
    var hideReasons: Set<PanelVisibilityReason> = []
    var autoHideInhibitors: Set<EdgeAutoHideInhibitor> = []
    private(set) var fullscreenTransitionGeneration: UInt64?

    var isVisible: Bool { hideReasons.isEmpty }

    mutating func setFullscreen(_ active: Bool) {
        setReason(.fullscreen, active: active)
    }

    mutating func beginFullscreenTransition(generation: UInt64) {
        fullscreenTransitionGeneration = generation
        hideReasons.insert(.fullscreenTransitionPending)
    }

    @discardableResult
    mutating func confirmFullscreenTransition(generation: UInt64) -> Bool {
        guard fullscreenTransitionGeneration == generation else { return false }
        fullscreenTransitionGeneration = nil
        hideReasons.remove(.fullscreenTransitionPending)
        hideReasons.insert(.fullscreen)
        return true
    }

    @discardableResult
    mutating func timeoutFullscreenTransition(generation: UInt64) -> Bool {
        guard fullscreenTransitionGeneration == generation else { return false }
        fullscreenTransitionGeneration = nil
        hideReasons.remove(.fullscreenTransitionPending)
        return true
    }

    mutating func setEdgeAutoHidden(_ active: Bool) {
        setReason(.edgeAutoHide, active: active)
    }

    mutating func setInhibitor(_ inhibitor: EdgeAutoHideInhibitor, active: Bool) {
        if active {
            autoHideInhibitors.insert(inhibitor)
        } else {
            autoHideInhibitors.remove(inhibitor)
        }
    }

    mutating func reconcileEdgeAutoHide(isEnabled: Bool) {
        if !isEnabled || !autoHideInhibitors.isEmpty {
            hideReasons.remove(.edgeAutoHide)
        }
    }

    private mutating func setReason(_ reason: PanelVisibilityReason, active: Bool) {
        if active {
            hideReasons.insert(reason)
        } else {
            hideReasons.remove(reason)
        }
    }
}

@MainActor
enum EdgeAutoHideRuntimeRules {
    static let fixedIdleHideDelay: Double = 0.2

    static func canArmWake(state: PanelVisibilityState, delay: Double) -> Bool {
        state.hideReasons.contains(.edgeAutoHide)
            && !state.hideReasons.contains(.fullscreen)
            && !state.hideReasons.contains(.fullscreenTransitionPending)
            && state.autoHideInhibitors.isEmpty
            && delay != AppSettingsStore.neverHideDelay
            && delay < AppSettingsStore.neverWakeDelay
    }

    static func canArmIdleHide(state: PanelVisibilityState, delay: Double) -> Bool {
        !state.hideReasons.contains(.edgeAutoHide)
            && !state.hideReasons.contains(.fullscreen)
            && !state.hideReasons.contains(.fullscreenTransitionPending)
            && state.autoHideInhibitors.isEmpty
            && delay != AppSettingsStore.neverHideDelay
    }

    static func idleHideInterval(for delay: Double) -> Double? {
        guard delay > AppSettingsStore.neverHideDelay else { return nil }
        return fixedIdleHideDelay
    }

    /// Whether the bottom-edge wake hot zone (running along the whole bottom edge of the screen) should hold off idle-hide and keep the hide timer from arming.
    /// It holds only with a "finite wake delay" (0.1–3.0s): in that range both wake and idle-hide are running, and when the mouse rests inside the hot zone
    /// but outside the strip rect the two fight each other (wake→hide→wake…), so the hot zone itself must also count as "didn't leave".
    /// 999 (`neverWakeDelay`, auto-hide without wake) has no wake action, so there is no such fight and hiding should proceed as usual;
    /// -1 (`neverHideDelay`, always shown) never hides anyway, so it makes no difference whether we hold or not.
    static func bottomHotZoneSuppressesIdleHide(delay: Double) -> Bool {
        delay != AppSettingsStore.neverHideDelay && delay < AppSettingsStore.neverWakeDelay
    }
}
