import CoreGraphics
import Foundation
import OSLog
import os.lock

/// Global mouse-wheel reversal (Settings "General · Reverse mouse wheel direction", off by default).
///
/// Structure cloned from `FullscreenIntentEventTapThread`: a dedicated thread, `.cgSessionEventTap` +
/// `.headInsertEventTap` + `.defaultTap`, `.commonModes`, and the same circuit-breaker restart policy
/// (`FullscreenEventTapRecoveryPolicy`). The rules over there froze these details, and here we **deliberately don't extract
/// a common base class** and accept a little duplication; extract only after both taps are stable.
///
/// This is the only place in the whole project that **rewrites** input events: it flips only the six delta fields of discrete wheel events,
/// without reading content, without allocating, and without entering the main thread (the CGEventTap discipline from panels-and-screens).
/// When the switch is off this object doesn't exist (`AppDelegate` builds it only when the setting is on), and the tap doesn't exist with it.
@MainActor
final class ScrollReverserMonitor {
    private var tapThread: ScrollReverserEventTapThread?

    func start() {
        guard tapThread == nil else { return }
        let thread = ScrollReverserEventTapThread(
            logger: Logger(subsystem: "app.neobar.NeoBar", category: "scroll-reverser")
        )
        tapThread = thread
        thread.start()
    }

    func stop() {
        tapThread?.stop()
        tapThread = nil
    }
}

private final class ScrollReverserEventTapThread {
    private let logger: Logger
    private var lifecycleLock = os_unfair_lock_s()
    private var recoveryLock = os_unfair_lock_s()
    private var recoveryPolicy = FullscreenEventTapRecoveryPolicy()
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private var tap: CFMachPort?
    private var stopping = false
    private let finished = DispatchSemaphore(value: 0)

    /// Mechanism probe (`DOCK_SCROLL_REVERSER_TRACE=1`, off by default): prints the continuous flag and delta of the first 10 events,
    /// to confirm on real hardware that "mouse wheel cont=0, trackpad cont=1". Touched only on the tap thread.
    private static let traceEnabled =
        DebugSwitch.scrollReverserTrace.isEnabled(in: ProcessInfo.processInfo.environment)
    private var traceRemaining = 10

    init(logger: Logger) {
        self.logger = logger
    }

    func start() {
        withLifecycleLock {
            guard thread == nil else { return }
            stopping = false
            let thread = Thread { [weak self] in self?.run() }
            thread.name = "app.neobar.scroll-reverser-tap"
            thread.qualityOfService = .userInteractive
            self.thread = thread
            thread.start()
        }
    }

    func stop() {
        let loop: CFRunLoop? = withLifecycleLock {
            stopping = true
            return runLoop
        }
        if let loop {
            CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) { [weak self] in
                guard let self else { return }
                if let tap = self.withLifecycleLock({ self.tap }) {
                    CGEvent.tapEnable(tap: tap, enable: false)
                    CFMachPortInvalidate(tap)
                }
                CFRunLoopStop(loop)
            }
            CFRunLoopWakeUp(loop)
            _ = finished.wait(timeout: .now() + 1)
        }
        withLifecycleLock {
            thread = nil
            runLoop = nil
            tap = nil
        }
    }

    private func run() {
        autoreleasepool {
            let mask = CGEventMask(1) << CGEventType.scrollWheel.rawValue
            guard let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: Self.callback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            ) else {
                logger.error("scroll-tap-create-failed")
                finished.signal()
                return
            }
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            let currentLoop = CFRunLoopGetCurrent()
            let shouldStop = withLifecycleLock {
                self.tap = tap
                runLoop = currentLoop
                return stopping
            }
            guard !shouldStop else {
                CFMachPortInvalidate(tap)
                finished.signal()
                return
            }
            CFRunLoopAddSource(currentLoop, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            finished.signal()
        }
    }

    private static let callback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let owner = Unmanaged<ScrollReverserEventTapThread>.fromOpaque(userInfo).takeUnretainedValue()
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            owner.handleDisabled(type: type)
        } else if type == .scrollWheel {
            owner.reverseIfNeeded(event)
        }
        return Unmanaged.passUnretained(event)
    }

    /// Hot path: read one flag, flip six fields. No allocation, no locks, no logging (trace is off by default and prints only 10 events).
    private func reverseIfNeeded(_ event: CGEvent) {
        let isContinuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
        if Self.traceEnabled, traceRemaining > 0 {
            traceRemaining -= 1
            print("[scrollrev] cont=\(isContinuous ? 1 : 0)"
                + " axis1=\(event.getIntegerValueField(.scrollWheelEventDeltaAxis1))"
                + " point1=\(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))"
                + " fixed1=\(event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1))")
        }
        guard ScrollReverserDecision.shouldReverse(isContinuous: isContinuous) else { return }
        let deltas = ScrollWheelDeltas(
            axis1: event.getIntegerValueField(.scrollWheelEventDeltaAxis1),
            axis2: event.getIntegerValueField(.scrollWheelEventDeltaAxis2),
            pointAxis1: event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1),
            pointAxis2: event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2),
            fixedAxis1: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1),
            fixedAxis2: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
        )
        let reversed = ScrollReverserDecision.reversed(deltas)
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: reversed.axis1)
        event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: reversed.axis2)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: reversed.pointAxis1)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: reversed.pointAxis2)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: reversed.fixedAxis1)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: reversed.fixedAxis2)
    }

    /// The circuit-breaker policy is exactly the same as the fullscreen tap: at most 3 restarts within 60 seconds, after which it stays off (the feature fails silently,
    /// and toggling the switch back on rebuilds it). The system automatically disables a tap on tap timeout / user input storms.
    private func handleDisabled(type: CGEventType) {
        let now = ProcessInfo.processInfo.systemUptime
        let shouldReenable: Bool = withRecoveryLock {
            recoveryPolicy.recordDisable(at: now)
        }
        guard shouldReenable, let tap = withLifecycleLock({ self.tap }) else {
            logger.fault("scroll-tap-fused type=\(type.rawValue, privacy: .public)")
            return
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        logger.error("scroll-tap-reenabled type=\(type.rawValue, privacy: .public)")
    }

    private func withLifecycleLock<T>(_ body: () -> T) -> T {
        os_unfair_lock_lock(&lifecycleLock)
        defer { os_unfair_lock_unlock(&lifecycleLock) }
        return body()
    }

    private func withRecoveryLock<T>(_ body: () -> T) -> T {
        os_unfair_lock_lock(&recoveryLock)
        defer { os_unfair_lock_unlock(&recoveryLock) }
        return body()
    }
}
