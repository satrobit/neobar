import SwiftUI

// MARK: - Pure decisions

/// The pure decision layer for press feedback. Time enters only through parameters, and `ChipPressFeedbackTests` locks it down here.
///
/// **Why there is a press-down edge** (owner 2026-08-11 reported "pressing feels sticky"): the old implementation hung the rebound on
/// `.onTapGesture`, and SwiftUI's TapGesture fires on **mouse-up**, so at the moment of pressing the screen had zero change,
/// and the scaling began only after release. The whole "press" happened after the click had already ended, which read as latency. It is now driven by
/// `onChanged` of `DragGesture(minimumDistance: 0)` at the instant of press.
enum ChipPressDecision {
    /// Scale while pressed. Exactly the same as the pre-change `isTapPressed ? 0.93 : 1.0`, deliberately untouched.
    static let pressedScale: CGFloat = 0.93

    /// Minimum duration to keep the pressed state after lift. If an extremely fast click (only a few milliseconds from down to up) bounced back immediately,
    /// that scaling would be invisible; this is the original purpose of the 90ms timer in the old implementation, kept as is.
    static let minimumHold: TimeInterval = 0.09

    /// Fallback cap. SwiftUI **cancels** the gesture when reordering moves a chip (see the comments on the `DockStripView` message-area reorder and
    /// the `DrawerView` drawer reorder), in which case `onEnded` may never come. Without this gate,
    /// the chip would stay at 0.93 forever.
    static let maximumHold: TimeInterval = 1.0

    /// How much longer to keep holding after lift before allowing the bounce back (0 = bounce back immediately).
    ///
    /// - `pressedAt` is nil: the press wasn't recorded (e.g. force-touch, which has only a pulse path), so make up the whole duration.
    /// - Lift earlier than press (clock anomaly): likewise make up the whole duration, never returning a negative.
    static func holdAfterRelease(pressedAt: TimeInterval?, releasedAt: TimeInterval) -> TimeInterval {
        guard let pressedAt, releasedAt >= pressedAt else { return minimumHold }
        return max(0, minimumHold - (releasedAt - pressedAt))
    }
}

/// Feedback on press-down is the default. `DOCK_CHIP_PRESS_DOWN=0` reverts to the old behavior (a single pulse plays only on mouse-up).
///
/// The reason for keeping this switch: a `minimumDistance: 0` gesture has to coexist with the existing 8pt reorder drag. In the repo
/// `simultaneousGesture` + `onTapGesture` + `nativeContextMenu` coexisting already has precedent
/// (`DockStripView.chipWithReorder`), but should it affect the drag or the click itself on real hardware,
/// the owner can revert immediately without waiting for a repackage.
enum ChipPressSwitches {
    static let pressDownEnabled = DebugSwitch.chipPressDown.isEnabled(in: ProcessInfo.processInfo.environment)
}

enum ChipPressAnimation {
    /// Press-down must "sink fast". The old implementation shared one spring (damping 0.5) between both edges, so the press overshot too;
    /// that wasn't very noticeable when played after lift, but it is obvious when played instantly on press.
    static let down = Animation.easeOut(duration: 0.08)

    /// The rebound keeps the old parameters, not a word changed: this is a feel the owner has already signed off on.
    static let up = Animation.spring(response: 0.22, dampingFraction: 0.5)
}

// MARK: - View integration

extension View {
    /// Visual only: press scale + each of the two edges' own curve.
    ///
    /// Being **two separate modifiers** from the gesture is deliberate: the drawer capsule's press applies only to the 2x2 grid inside while the outer frame stays still
    /// (decided by the owner 2026-06-21), so the scaling and the gesture must be attachable at different levels.
    func chipPressScale(_ isPressed: Bool) -> some View {
        scaleEffect(isPressed ? ChipPressDecision.pressedScale : 1.0)
            .animation(isPressed ? ChipPressAnimation.down : ChipPressAnimation.up, value: isPressed)
    }

    /// Drives state only, changes no geometry. Placed **after** `.contentShape(...)`, so the press hit area
    /// is exactly the same as the click's.
    ///
    /// - Parameters:
    ///   - isPressed: the `@State` held by the caller (keeping the old `isTapPressed` position).
    ///   - pulseNonce: an external pulse for force-touch / middle-click preview. That path has no mouse-up and needs an automatic down+up once.
    ///   - isEnabled: when off, it neither installs the gesture nor responds to pulses (`LauncherChip` uses it during a launch session,
    ///     when a click is a no-op anyway and giving press feedback would be a lie).
    ///   - onEvent: a pure diagnostic outlet (`ChipAnimationTrace`). **Never feeds the planner / frontmost axis** (AGENTS).
    func chipPressGesture(
        isPressed: Binding<Bool>,
        pulseNonce: Int = 0,
        isEnabled: Bool = true,
        onEvent: @escaping (Bool) -> Void = { _ in }
    ) -> some View {
        modifier(ChipPressGestureModifier(
            isPressed: isPressed,
            pulseNonce: pulseNonce,
            isEnabled: isEnabled,
            onEvent: onEvent
        ))
    }
}

private struct ChipPressGestureModifier: ViewModifier {
    @Binding var isPressed: Bool
    let pulseNonce: Int
    let isEnabled: Bool
    let onEvent: (Bool) -> Void

    @State private var pressedAt: TimeInterval?
    @State private var releaseWork: DispatchWorkItem?
    @State private var watchdogWork: DispatchWorkItem?

    func body(content: Content) -> some View {
        content
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard isEnabled, ChipPressSwitches.pressDownEnabled else { return }
                        beginPress()
                    }
                    .onEnded { _ in
                        guard isEnabled else { return }
                        if ChipPressSwitches.pressDownEnabled {
                            endPress()
                        } else {
                            // Old behavior: a full down + up plays only on lift.
                            firePulse()
                        }
                    }
            )
            .onChange(of: pulseNonce) { _ in
                guard isEnabled else { return }
                firePulse()
            }
            .onDisappear {
                cancelPending()
                setPressed(false)
            }
    }

    private func beginPress() {
        guard !isPressed else { return }
        cancelPending()
        pressedAt = ProcessInfo.processInfo.systemUptime
        setPressed(true)
        scheduleWatchdog()
    }

    private func endPress() {
        guard isPressed else { return }
        let hold = ChipPressDecision.holdAfterRelease(
            pressedAt: pressedAt,
            releasedAt: ProcessInfo.processInfo.systemUptime
        )
        if hold <= 0 {
            cancelPending()
            setPressed(false)
        } else {
            scheduleRelease(after: hold)
        }
    }

    /// Paths without mouse-up (force-touch / middle-click preview / compatibility behavior when the press-down level is off).
    private func firePulse() {
        cancelPending()
        pressedAt = ProcessInfo.processInfo.systemUptime
        setPressed(true)
        scheduleRelease(after: ChipPressDecision.minimumHold)
    }

    private func scheduleRelease(after delay: TimeInterval) {
        // Once the release countdown has begun, the watchdog is pointless (it only guards against "onEnded never comes").
        watchdogWork?.cancel()
        watchdogWork = nil
        releaseWork?.cancel()
        let work = DispatchWorkItem {
            releaseWork = nil
            setPressed(false)
        }
        releaseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func scheduleWatchdog() {
        watchdogWork?.cancel()
        let work = DispatchWorkItem {
            watchdogWork = nil
            setPressed(false)
        }
        watchdogWork = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + ChipPressDecision.maximumHold,
            execute: work
        )
    }

    private func cancelPending() {
        releaseWork?.cancel()
        releaseWork = nil
        watchdogWork?.cancel()
        watchdogWork = nil
    }

    private func setPressed(_ value: Bool) {
        guard isPressed != value else { return }
        isPressed = value
        onEvent(value)
    }
}
