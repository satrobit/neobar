import ApplicationServices
import CoreGraphics
import Foundation

/// The four per-window AX notifications a seat subscribes to. Order is registration order:
/// the two that decide seat release / retention come first.
enum WindowSubscriptionItem: Int, CaseIterable, Comparable {
    case destroyed
    case miniaturized
    case deminiaturized
    case titleChanged

    /// Attempted even after an earlier item in the same attempt timed out (the pre-ledger code sent
    /// all four unconditionally; skipping `miniaturized` after a `destroyed` timeout would lose a
    /// minimize the app could still have reported).
    var isCritical: Bool { self == .destroyed || self == .miniaturized }

    var logName: String {
        switch self {
        case .destroyed: return "destroyed"
        case .miniaturized: return "miniaturized"
        case .deminiaturized: return "deminiaturized"
        case .titleChanged: return "titleChanged"
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

enum WindowSubscriptionItemState: Equatable {
    case pending
    case done
    case unsupported
    case failed
}

enum WindowSubscriptionAttemptKind: String, Codable, Equatable {
    /// No record for this cgID yet (new seat, or the previous element's destroy removed it).
    case initial
    /// The window answered with a different AX element than the one we subscribed: AppKit vends a
    /// new element every time a window is ordered out and back in, and the old one never fires again.
    case renewal
    /// Same element, some item still pending or failed, backoff elapsed.
    case retry
}

enum WindowSubscriptionStop: String, Codable, Equatable {
    case completed
    /// A timeout happened; non-critical items left for a retry.
    case timeoutSkippedRest
    /// A retry used up its time budget before the next call.
    case retryTimeLimit
    /// The element answered `kAXErrorInvalidUIElement`.
    case dead
}

/// Per-window AX notification bookkeeping, keyed by cgWindowID and **by element**.
///
/// Why it exists: a window that is ordered out and back in gets a brand-new AX element (same
/// cgWindowID); the old element fires its destroy notification once and is dead from then on. The
/// old registry was keyed by cgWindowID only and a continuing seat never re-registered, so after
/// such a "blink" the next real order-out went unnoticed and the seat was held for the app's
/// lifetime. A registration whose `AXObserverAddNotification` failed was also recorded as done and
/// never retried. This type only does bookkeeping; it never touches AX and never releases a seat.
struct WindowSubscriptionLedger<Element: Hashable> {
    struct Record {
        var element: Element
        var instanceID: UInt64
        var items: [WindowSubscriptionItem: WindowSubscriptionItemState]
        var step: Int
        var retryAt: TimeInterval
        var isDead: Bool
    }

    /// Retry delays after a failed attempt; the last value repeats. Never gives up: a transient
    /// timeout must not freeze into a permanently missing subscription.
    static var backoff: [TimeInterval] { [1, 5, 15, 60] }

    private(set) var records: [CGWindowID: Record] = [:]
    private var cgIDByElement: [Element: CGWindowID] = [:]
    /// Shared across every ledger of the session so an instance id is never reused, even when a
    /// process's observer is dropped and recreated (non-regular eviction, re-admission).
    private let instanceIDs: WindowSubscriptionInstanceIDs

    init(instanceIDs: WindowSubscriptionInstanceIDs = WindowSubscriptionInstanceIDs()) {
        self.instanceIDs = instanceIDs
    }

    func attemptKind(cgWindowID: CGWindowID, element: Element, now: TimeInterval) -> WindowSubscriptionAttemptKind? {
        guard let record = records[cgWindowID] else { return .initial }
        // A new element is renewed at once, never delayed: the old element's subscription may never
        // have succeeded, and if the window is hidden again before the renewal it is held forever.
        if record.element != element { return .renewal }
        if record.isDead || Self.isCovered(record) { return nil }
        return now >= record.retryAt ? .retry : nil
    }

    func isCovered(cgWindowID: CGWindowID) -> Bool {
        records[cgWindowID].map(Self.isCovered) ?? false
    }

    func record(for cgWindowID: CGWindowID) -> Record? { records[cgWindowID] }

    func cgWindowID(forElement element: Element) -> CGWindowID? { cgIDByElement[element] }

    /// Starts an attempt. `.initial` / `.renewal` (re)create the record with a fresh, never-reused
    /// instance id; `.retry` keeps it. Returns the items still to register, in order.
    mutating func beginAttempt(
        cgWindowID: CGWindowID,
        element: Element,
        kind: WindowSubscriptionAttemptKind,
        now: TimeInterval
    ) -> (instanceID: UInt64, previousInstanceID: UInt64?, items: [WindowSubscriptionItem]) {
        var previousInstanceID: UInt64?
        if kind != .retry || records[cgWindowID] == nil {
            if let old = records[cgWindowID] {
                previousInstanceID = old.instanceID
                cgIDByElement.removeValue(forKey: old.element)
            }
            records[cgWindowID] = Record(
                element: element,
                instanceID: instanceIDs.next(),
                items: Dictionary(uniqueKeysWithValues: WindowSubscriptionItem.allCases.map { ($0, .pending) }),
                step: 0,
                retryAt: now,
                isDead: false
            )
            cgIDByElement[element] = cgWindowID
        }
        let record = records[cgWindowID]!
        let items = WindowSubscriptionItem.allCases.filter {
            let state = record.items[$0] ?? .pending
            return state == .pending || state == .failed
        }
        return (record.instanceID, previousInstanceID, items)
    }

    /// Classifies one `AXObserverAddNotification` result.
    mutating func record(cgWindowID: CGWindowID, item: WindowSubscriptionItem, result: AXError) {
        guard records[cgWindowID] != nil else { return }
        switch result {
        case .success, .notificationAlreadyRegistered:
            records[cgWindowID]?.items[item] = .done
        case .notificationUnsupported:
            records[cgWindowID]?.items[item] = .unsupported
        case .invalidUIElement:
            records[cgWindowID]?.items[item] = .failed
            records[cgWindowID]?.isDead = true
        default:
            records[cgWindowID]?.items[item] = .failed
        }
    }

    /// Ends an attempt. A new failure backs off; a retry cut by its time budget (no new failure)
    /// stays due immediately — every attempt completes at least one call, so it converges.
    mutating func finishAttempt(cgWindowID: CGWindowID, now: TimeInterval, sawFailure: Bool) {
        guard var record = records[cgWindowID] else { return }
        if record.isDead || Self.isCovered(record) {
            record.step = 0
            record.retryAt = now
        } else if sawFailure {
            let delays = Self.backoff
            record.retryAt = now + delays[min(record.step, delays.count - 1)]
            record.step += 1
        } else {
            record.retryAt = now
        }
        records[cgWindowID] = record
    }

    /// A destroy notification arrived for `element`. Removes the record only when it is still the
    /// current one: during an order-out/order-in blink the old element's destroy can land after the
    /// new element was registered, and must not wipe that registration.
    mutating func noteDestroyed(element: Element) -> (cgWindowID: CGWindowID, removedInstanceID: UInt64?)? {
        guard let cgWindowID = cgIDByElement.removeValue(forKey: element) else { return nil }
        guard let record = records[cgWindowID], record.element == element else {
            return (cgWindowID, nil)
        }
        records.removeValue(forKey: cgWindowID)
        return (cgWindowID, record.instanceID)
    }

    /// Drops records whose cgWindowID is not in `keep`; returns what was dropped.
    mutating func retain(keep: Set<CGWindowID>) -> [(cgWindowID: CGWindowID, instanceID: UInt64)] {
        var dropped: [(cgWindowID: CGWindowID, instanceID: UInt64)] = []
        for (cgWindowID, record) in records where !keep.contains(cgWindowID) {
            dropped.append((cgWindowID, record.instanceID))
            records.removeValue(forKey: cgWindowID)
            cgIDByElement.removeValue(forKey: record.element)
        }
        return dropped.sorted { $0.cgWindowID < $1.cgWindowID }
    }

    mutating func removeAll() {
        records.removeAll()
        cgIDByElement.removeAll()
    }

    private static func isCovered(_ record: Record) -> Bool {
        !record.isDead && record.items.values.allSatisfy { $0 == .done || $0 == .unsupported }
    }
}

/// What to do with the next item of an attempt.
enum WindowSubscriptionAttemptPolicy {
    enum Step: Equatable {
        case send
        case skip
        case stop(WindowSubscriptionStop?)
    }

    /// Initial / renewal (`timeLimit == nil`): always send the two critical items, even after a
    /// timeout, exactly as the pre-ledger code did; after a timeout skip the rest for a retry.
    /// Retry: stop at the first timeout, and before any call after the first once `elapsed`
    /// exceeds `timeLimit`.
    static func step(
        item: WindowSubscriptionItem,
        index: Int,
        sawTimeout: Bool,
        elapsed: TimeInterval,
        timeLimit: TimeInterval?
    ) -> Step {
        if let timeLimit {
            if sawTimeout { return .stop(nil) }
            if index > 0, elapsed > timeLimit { return .stop(.retryTimeLimit) }
            return .send
        }
        if sawTimeout, !item.isCritical { return .skip }
        return .send
    }
}

/// Session-wide subscription instance ids (diagnostics only).
final class WindowSubscriptionInstanceIDs {
    private var last: UInt64 = 0

    init() {}

    func next() -> UInt64 {
        last &+= 1
        return last
    }
}

/// A due retry found while a seat was placed with its current element. Retries never run inside
/// reconcile: they are collected and at most one runs after the main-thread turn (see
/// `WindowSubscriptionRetryScheduler`).
struct WindowSubscriptionRetryCandidate<Element: Hashable>: Equatable {
    let pid: pid_t
    let cgWindowID: CGWindowID
    let element: Element
    let retryAt: TimeInterval
}

enum WindowSubscriptionRetryScheduler {
    /// Earliest `retryAt` first across every pid in the turn, skipping candidates that are no longer
    /// valid (observer gone, element replaced, already covered). Fixed seat or pid order would let a
    /// window that keeps failing take the single slot forever.
    static func pick<Element>(
        _ candidates: [WindowSubscriptionRetryCandidate<Element>],
        isValid: (WindowSubscriptionRetryCandidate<Element>) -> Bool
    ) -> (picked: WindowSubscriptionRetryCandidate<Element>?, skippedInvalid: Int) {
        let ordered = candidates.sorted {
            if $0.retryAt != $1.retryAt { return $0.retryAt < $1.retryAt }
            if $0.pid != $1.pid { return $0.pid < $1.pid }
            return $0.cgWindowID < $1.cgWindowID
        }
        var skipped = 0
        for candidate in ordered {
            if isValid(candidate) { return (candidate, skipped) }
            skipped += 1
        }
        return (nil, skipped)
    }
}
