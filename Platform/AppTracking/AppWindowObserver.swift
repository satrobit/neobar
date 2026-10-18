import ApplicationServices
import Foundation

struct AXElementKey: Hashable {
    let e: AXUIElement
    static func == (l: AXElementKey, r: AXElementKey) -> Bool { CFEqual(l.e, r.e) }
    func hash(into h: inout Hasher) { h.combine(CFHash(e)) }
}

@MainActor
final class AppWindowObserver {
    let pid: pid_t
    private var observer: AXObserver?
    /// Per-window subscriptions, keyed by cgWindowID **and element** (`WindowSubscriptionLedger`).
    private var subscriptions = WindowSubscriptionLedger<AXElementKey>(instanceIDs: AppWindowObserver.instanceIDs)
    private static let instanceIDs = WindowSubscriptionInstanceIDs()
    private let clock: () -> TimeInterval

    /// AXObserverCreate may fail (the observer was never built at all). The periodic reconcile's skip-read gate uses it to tell
    /// whether this pid has event coverage: a pid without coverage is never skip-read.
    var isActive: Bool { observer != nil }

    var onWindowCreated: ((pid_t) -> Void)?
    var onWindowDestroyed: ((pid_t, CGWindowID) -> Void)?
    var onWindowMinimized: ((pid_t, CGWindowID) -> Void)?
    var onWindowDeminiaturized: ((pid_t, CGWindowID) -> Void)?
    var onFocusedWindowChanged: ((pid_t) -> Void)?
    var onTitleChanged: ((pid_t, CGWindowID) -> Void)?
    /// Diagnostics only: a destroy notification matched a subscription (`removedInstanceID` nil when
    /// it was a replaced element whose newer registration was kept).
    var onSubscriptionDestroyNotified: ((pid_t, CGWindowID, UInt64?) -> Void)?

    enum Registration {
        case none
        case attempted(WindowSubscriptionAttemptReport)
        case retryDue(WindowSubscriptionRetryCandidate<AXElementKey>)
    }

    /// Wall-clock budget for one retry attempt, checked before every call after the first.
    static let retryTimeLimit: TimeInterval = 0.05

    private static let dropsDestroyNotifications = DebugSwitch.simulateNoDestroy.isEnabled()

    init(pid: pid_t, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.pid = pid
        self.clock = clock
    }

    deinit {
        MainActor.assumeIsolated { stop() }
    }

    func start() {
        guard observer == nil, AXIsProcessTrusted() else { return }

        var obs: AXObserver?
        let result = AXObserverCreate(pid, appWindowObserverCallback, &obs)
        guard result == .success, let obs else { return }

        let appElement = AXUIElementCreateApplication(pid)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        AXObserverAddNotification(obs, appElement, kAXWindowCreatedNotification as CFString, selfPtr)
        AXObserverAddNotification(obs, appElement, kAXFocusedWindowChangedNotification as CFString, selfPtr)

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        observer = obs
    }

    func stop() {
        if let obs = observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
            observer = nil
        }
        subscriptions.removeAll()
    }

    /// Subscribes `element` for `cgWindowID`, or renews the subscription when the window now answers
    /// with a different element. Called from **every** path that places a seat with an AX element in
    /// hand, including a seat that simply continues — that continuation call is what keeps the
    /// destroy subscription alive after an order-out/order-in blink.
    ///
    /// Initial and renewal attempts run now (same timing as the old new-seat registration); a due
    /// retry is only returned as a candidate, never run here (`performRetry`).
    func registerWindow(_ element: AXUIElement, cgWindowID: CGWindowID) -> Registration {
        guard let obs = observer else { return .none }
        let key = AXElementKey(e: element)
        let now = clock()
        guard let kind = subscriptions.attemptKind(cgWindowID: cgWindowID, element: key, now: now) else {
            return .none
        }
        if kind == .retry {
            let retryAt = subscriptions.record(for: cgWindowID)?.retryAt ?? now
            return .retryDue(WindowSubscriptionRetryCandidate(
                pid: pid, cgWindowID: cgWindowID, element: key, retryAt: retryAt
            ))
        }
        return .attempted(perform(obs, key: key, cgWindowID: cgWindowID, kind: kind, timeLimit: nil))
    }

    func isRetryValid(_ candidate: WindowSubscriptionRetryCandidate<AXElementKey>) -> Bool {
        guard observer != nil, candidate.pid == pid else { return false }
        return subscriptions.attemptKind(
            cgWindowID: candidate.cgWindowID, element: candidate.element, now: clock()
        ) == .retry
    }

    func performRetry(_ candidate: WindowSubscriptionRetryCandidate<AXElementKey>) -> WindowSubscriptionAttemptReport? {
        guard let obs = observer, isRetryValid(candidate) else { return nil }
        return perform(
            obs, key: candidate.element, cgWindowID: candidate.cgWindowID, kind: .retry,
            timeLimit: Self.retryTimeLimit
        )
    }

    func isCovered(cgWindowID: CGWindowID) -> Bool {
        subscriptions.isCovered(cgWindowID: cgWindowID)
    }

    /// The element this window is subscribed with and its instance, for the absence probe
    /// (`AbsentSeatReleaseDecision`). Nil when the window was never registered.
    func subscribedElement(cgWindowID: CGWindowID) -> (element: AXUIElement, instanceID: UInt64)? {
        subscriptions.record(for: cgWindowID).map { ($0.element.e, $0.instanceID) }
    }

    /// Drops subscriptions whose window is in none of `keep`; returns them for diagnostics.
    func retainSubscriptions(keep: Set<CGWindowID>) -> [(cgWindowID: CGWindowID, instanceID: UInt64)] {
        subscriptions.retain(keep: keep)
    }

    private func perform(
        _ obs: AXObserver,
        key: AXElementKey,
        cgWindowID: CGWindowID,
        kind: WindowSubscriptionAttemptKind,
        timeLimit: TimeInterval?
    ) -> WindowSubscriptionAttemptReport {
        let start = clock()
        let begun = subscriptions.beginAttempt(cgWindowID: cgWindowID, element: key, kind: kind, now: start)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        var results: [WindowSubscriptionItem: AXError] = [:]
        var sawTimeout = false
        var sawFailure = false
        var stop: WindowSubscriptionStop = .completed
        attempt: for (index, item) in begun.items.enumerated() {
            switch WindowSubscriptionAttemptPolicy.step(
                item: item, index: index, sawTimeout: sawTimeout,
                elapsed: clock() - start, timeLimit: timeLimit
            ) {
            case .send: break
            case .skip: continue attempt
            case .stop(let reason):
                if let reason { stop = reason }
                break attempt
            }
            let result = AXObserverAddNotification(obs, key.e, item.notificationName, selfPtr)
            results[item] = result
            subscriptions.record(cgWindowID: cgWindowID, item: item, result: result)
            if result == .invalidUIElement { stop = .dead; break attempt }
            if result == .cannotComplete { sawTimeout = true }
            switch result {
            case .success, .notificationAlreadyRegistered, .notificationUnsupported: break
            default: sawFailure = true
            }
        }
        if stop == .completed, sawTimeout { stop = .timeoutSkippedRest }
        let end = clock()
        subscriptions.finishAttempt(cgWindowID: cgWindowID, now: end, sawFailure: sawFailure)
        return WindowSubscriptionAttemptReport(
            pid: pid,
            cgWindowID: cgWindowID,
            kind: kind,
            instanceID: begun.instanceID,
            previousInstanceID: begun.previousInstanceID,
            results: results,
            stop: stop,
            covered: subscriptions.isCovered(cgWindowID: cgWindowID),
            durationMs: (end - start) * 1_000
        )
    }

    fileprivate func handleNotification(element: AXUIElement, notification: CFString) {
        let notifStr = notification as String
        if notifStr == (kAXWindowCreatedNotification as String) {
            onWindowCreated?(pid)
        } else if notifStr == (kAXFocusedWindowChangedNotification as String) {
            onFocusedWindowChanged?(pid)
        } else if notifStr == (kAXUIElementDestroyedNotification as String) {
            if Self.dropsDestroyNotifications { return }
            // A destroyed element can no longer resolve its window id (`_AXUIElementGetWindow`
            // fails), so the subscription ledger is the lookup.
            if let hit = subscriptions.noteDestroyed(element: AXElementKey(e: element)) {
                onSubscriptionDestroyNotified?(pid, hit.cgWindowID, hit.removedInstanceID)
                onWindowDestroyed?(pid, hit.cgWindowID)
            }
        } else if notifStr == (kAXWindowMiniaturizedNotification as String) {
            // Ledger fallback: a dropped minimize would leave `seat.isMinimized` false, and the
            // absence fallback relies on that flag for subscribed windows.
            if let cgID = AXWindowReader.cgWindowID(for: element)
                ?? subscriptions.cgWindowID(forElement: AXElementKey(e: element)) {
                onWindowMinimized?(pid, cgID)
            }
        } else if notifStr == (kAXWindowDeminiaturizedNotification as String) {
            if let cgID = AXWindowReader.cgWindowID(for: element)
                ?? subscriptions.cgWindowID(forElement: AXElementKey(e: element)) {
                onWindowDeminiaturized?(pid, cgID)
            }
        } else if notifStr == (kAXTitleChangedNotification as String) {
            if let cgID = AXWindowReader.cgWindowID(for: element)
                ?? subscriptions.cgWindowID(forElement: AXElementKey(e: element)) {
                onTitleChanged?(pid, cgID)
            }
        }
    }
}

/// Outcome of one subscription attempt, for diagnostics.
struct WindowSubscriptionAttemptReport {
    let pid: pid_t
    let cgWindowID: CGWindowID
    let kind: WindowSubscriptionAttemptKind
    let instanceID: UInt64
    let previousInstanceID: UInt64?
    let results: [WindowSubscriptionItem: AXError]
    let stop: WindowSubscriptionStop
    let covered: Bool
    let durationMs: Double
}

private extension WindowSubscriptionItem {
    var notificationName: CFString {
        switch self {
        case .destroyed: return kAXUIElementDestroyedNotification as CFString
        case .miniaturized: return kAXWindowMiniaturizedNotification as CFString
        case .deminiaturized: return kAXWindowDeminiaturizedNotification as CFString
        case .titleChanged: return kAXTitleChangedNotification as CFString
        }
    }
}

private let appWindowObserverCallback: AXObserverCallback = { _, element, notification, refcon in
    guard let refcon else { return }
    let obs = Unmanaged<AppWindowObserver>.fromOpaque(refcon).takeUnretainedValue()
    let notif = notification
    let el = element
    DispatchQueue.main.async { [weak obs] in
        MainActor.assumeIsolated {
            obs?.handleNotification(element: el, notification: notif)
        }
    }
}
