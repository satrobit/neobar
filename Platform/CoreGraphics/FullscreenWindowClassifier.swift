import ApplicationServices
import CoreGraphics

// Pure decision on whether the focused window is fullscreen and whether it belongs to this display. Platform layer: `FullscreenIntentMonitor` calls it on the event-tap
// thread, and `PanelCoordinator`'s async AX probe calls it too; no AX calls / AppKit / logging are allowed here.
// Moved from App/Composition/PanelVisibilityState.swift on 2026-09-05, removing the only Platform→App reverse dependency.

// Pure decision for the async AX fullscreen probe (called by PanelCoordinator.detectFullscreenViaAX).
// The role gate is a hard constraint: Finder keeps a desktop pseudo-window (role=AXScrollArea, frame exactly equal to the whole screen),
// which becomes AXFocusedWindow the instant a minimized window is restored — without the gate it hits the frame≈whole-screen fallback and the taskbar is wrongly hidden.
/// Three-state ruling of the focused window relative to **this display** (multi-display taskbar, 2026-09-02).
/// `.notOnThisScreen` = the focused window's bulk is on another display — for this display's bar it is **not evidence**:
/// this display may currently be showing another app's fullscreen space, in which case ask SkyLight for this display's current space type instead
/// (`PanelCoordinator.triggerAsyncFullscreenCheck`), rather than treating it as "not fullscreen" and letting the bar out.
enum FullscreenAXVerdict: Equatable {
    case fullscreen
    case windowed
    case notOnThisScreen
}

enum FullscreenWindowClassifier {
    static let frameTolerance: CGFloat = 8

    /// The Boolean form is kept for single-display callers (`FullscreenIntentMonitor.readAXState`, the probe copy):
    /// true only for `.fullscreen` — verbatim equivalent to before the three states were introduced.
    static func isFullscreen(
        role: String?,
        isAXFullscreen: Bool,
        windowFrame: CGRect?,
        windowLayer: Int?,
        screenCGFrame: CGRect
    ) -> Bool {
        classify(
            role: role,
            isAXFullscreen: isAXFullscreen,
            windowFrame: windowFrame,
            windowLayer: windowLayer,
            screenCGFrame: screenCGFrame
        ) == .fullscreen
    }

    /// `windowLayer` is the focused window's CG layer (`kCGWindowLayer`); nil = not read / unknown.
    /// No default on purpose: a caller that omits it silently loses the desktop-overlay guard below.
    static func classify(
        role: String?,
        isAXFullscreen: Bool,
        windowFrame: CGRect?,
        windowLayer: Int?,
        screenCGFrame: CGRect
    ) -> FullscreenAXVerdict {
        guard role == kAXWindowRole else { return .windowed }

        if isAXFullscreen {
            guard let wf = windowFrame else { return .fullscreen }
            // Ownership criterion (the bulk of the area is on this display), not a width criterion. The old `width > screen × 0.7` doubled as
            // a multi-display guard, but it **wrongly rejected the half-width tile of a full-screen tiling (true split view)** — measured on 2026-08-30
            // (macOS 26.5.2, `scratch/space-probe-20260830-2106.log`): a split-view tile reports
            // AXFullScreen=true, frame=(0,40 1278×1400), and 1278 < 2560×0.7 got it rejected, so the taskbar
            // covered the split-view content (0.9.10 feedback `02525cc5`). Area ownership preserves the intent of the guard:
            // the same day, a fullscreen window on another display was measured not to intersect this display, and is still blocked.
            return mostlyBelongsToScreen(wf, screenCGFrame) ? .fullscreen : .notOnThisScreen
        }

        // Fallback: frame ≈ full screen (games / HTML5 that skip the AXFullScreen flag)
        if let wf = windowFrame {
            let t = frameTolerance
            if abs(wf.width  - screenCGFrame.width)  < t
                && abs(wf.height - screenCGFrame.height) < t
                && abs(wf.minX   - screenCGFrame.minX)   < t
                && abs(wf.minY   - screenCGFrame.minY)   < t {
                // A screen-sized window *below* the normal layer is a desktop overlay — wallpaper /
                // desktop-widget helpers own one and take focus when the desktop is clicked — not
                // fullscreen content. Without this the bar hides for as long as the desktop has focus.
                // An unknown layer keeps the fullscreen verdict (borderless games must still hide it).
                if let windowLayer, windowLayer < 0 { return .windowed }
                return .fullscreen
            }
            return mostlyBelongsToScreen(wf, screenCGFrame) ? .windowed : .notOnThisScreen
        }

        return .windowed
    }

    /// A window counts as "belonging to this display" only if more than half of its area falls on this display. Pure CGRect math —
    /// `FullscreenIntentMonitor.readAXState` also calls this decision, and the result is consumed on the event-tap thread,
    /// so no AX / AppKit / logging is allowed here (see the panels-and-screens rules).
    /// It is the same area method as the private same-named method in `WindowLiftAvoidance`, deliberately not shared —
    /// the avoidance copy is frozen in its own rules file, and coupling the two would make changes riskier.
    private static func mostlyBelongsToScreen(_ frame: CGRect, _ screen: CGRect) -> Bool {
        let frameArea = frame.width * frame.height
        guard frameArea > 0 else { return false }
        let overlap = frame.intersection(screen)
        guard !overlap.isNull, !overlap.isEmpty else { return false }
        return overlap.width * overlap.height >= frameArea * 0.5
    }
}
