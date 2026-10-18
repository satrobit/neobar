import Foundation

/// Coalescing throttle for mouse-move events (pure decision). Global/local `.mouseMoved` monitors call back hundreds of times per second while moving,
/// whereas the consumers (multi-screen hover switching needs a 350ms dwell, edge-wake hot-zone checks) are completely insensitive to 33ms granularity.
/// Semantics = leading + trailing: an expired event runs immediately; events inside the window attach **one** trailing call (when movement happens to stop
/// inside the throttle window, the last position must not be lost -- hot-zone enter/exit decisions depend on it); if a trailing call is already attached, discard.
struct HoverPollThrottle {
    let minInterval: TimeInterval
    private(set) var lastRunAt: TimeInterval = -.infinity
    private(set) var trailingScheduled = false

    enum Verdict: Equatable {
        case run
        case scheduleTrailing(after: TimeInterval)
        case drop
    }

    mutating func eventArrived(now: TimeInterval) -> Verdict {
        let elapsed = now - lastRunAt
        if elapsed >= minInterval {
            lastRunAt = now
            return .run
        }
        if trailingScheduled { return .drop }
        trailingScheduled = true
        return .scheduleTrailing(after: minInterval - elapsed)
    }

    mutating func trailingFired(now: TimeInterval) {
        trailingScheduled = false
        lastRunAt = now
    }

    /// Reset when the monitor is removed/reinstalled, so the previous segment's pending state doesn't leak into the next one.
    mutating func reset() {
        lastRunAt = -.infinity
        trailingScheduled = false
    }
}
