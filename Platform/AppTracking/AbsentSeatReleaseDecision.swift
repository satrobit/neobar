import ApplicationServices
import CoreGraphics
import Foundation

/// Absence fallback for a window an app hides without a destroy notification (Bilibili 1.18 hides its
/// player window this way: it leaves `AXWindows`, stays in the CG list, keeps its cgID for reuse,
/// and no `AXUIElementDestroyed` ever reaches us — so the seat used to be held until the app quit).
///
/// The evidence (macOS 27, `Docs/05`): only an app-side `orderOut` / `close()` kills the window's
/// AX element. A minimized window stays in `AXWindows` with a live element, and a window on another
/// Space keeps a live element answering `min == false` — which is why a cached element's
/// `kAXMinimizedAttribute == false` must never release a seat. A dead element is also exactly the
/// case where AppKit posts the destroy notification, so this releases the same class of windows
/// the tombstone path already releases for apps whose notification does arrive.
///
/// Release needs two "hidden" probes 2–10s apart for the same cgID and subscription instance; any
/// other probe result, a reappearance, or a minimize / hide / create / destroy event in between
/// restarts the confirmation.
enum AbsentSeatReleaseDecision {
    static let confirmMinInterval: TimeInterval = 2
    static let confirmMaxInterval: TimeInterval = 10
    static let maxProbesPerRead = 4

    /// Delay to the next probe after the `probeCount`-th dispatch: 2s, 5s, 15s, then every 60s.
    static func backoff(afterDispatch probeCount: Int) -> TimeInterval {
        switch probeCount {
        case ...1: return 2
        case 2: return 5
        case 3: return 15
        default: return 60
        }
    }

    enum ElementState: Equatable {
        /// The element answered exactly `kAXErrorInvalidUIElement`.
        case dead
        case alive(minimized: Bool?)
        /// Any other error or a timeout: no information.
        case unknown(errorCode: Int32)
    }

    enum SpaceClass: String, Equatable {
        case unknown
        /// The window belongs to no Space (long hidden).
        case none
        case onlyCurrent
        case includesNonCurrent

        static func classify(windowSpaceIDs: [Int]?, currentSpaceIDs: Set<Int>?) -> SpaceClass {
            guard let windowSpaceIDs, let currentSpaceIDs else { return .unknown }
            if windowSpaceIDs.isEmpty { return .none }
            return Set(windowSpaceIDs).isSubset(of: currentSpaceIDs) ? .onlyCurrent : .includesNonCurrent
        }
    }

    struct Input {
        /// The evidence was taken for this seat token, this active cgID and the ledger instance the
        /// seat is subscribed with right now.
        var evidenceMatchesSeat: Bool
        var element: ElementState
        var spaces: SpaceClass
        var firstHidden: AbsentSeatProbeState.FirstHiddenMark?
        var cgWindowID: CGWindowID
        var instanceID: UInt64
        var now: TimeInterval
    }

    enum NotHiddenReason: String, Equatable {
        case evidenceMismatch
        case elementAlive
        case elementUnknown
        case spaceUnknown
        case onNonCurrentSpace
    }

    enum Verdict: Equatable {
        case release
        /// First "hidden" probe of a confirmation (or a restart after the window expired).
        case markFirst
        /// Hidden again, but too soon after the first mark to confirm; keep the mark.
        case holdMark
        case notHidden(NotHiddenReason)
    }

    static func verdict(_ input: Input) -> Verdict {
        guard input.evidenceMatchesSeat else { return .notHidden(.evidenceMismatch) }
        switch input.element {
        case .dead: break
        case .alive: return .notHidden(.elementAlive)
        case .unknown: return .notHidden(.elementUnknown)
        }
        switch input.spaces {
        case .none, .onlyCurrent: break
        case .unknown: return .notHidden(.spaceUnknown)
        case .includesNonCurrent: return .notHidden(.onNonCurrentSpace)
        }
        guard let first = input.firstHidden,
              first.cgWindowID == input.cgWindowID,
              first.instanceID == input.instanceID else { return .markFirst }
        let age = input.now - first.uptime
        if age < confirmMinInterval { return .holdMark }
        if age > confirmMaxInterval { return .markFirst }
        return .release
    }
}

/// Per-seat state of the absence fallback; lives on `WindowEntry`, never in `seatSignature`.
/// A seat rebuilt from a fresh AX snapshot (`make()`) starts without it.
struct AbsentSeatProbeState: Equatable {
    struct FirstHiddenMark: Equatable {
        let uptime: TimeInterval
        let cgWindowID: CGWindowID
        let instanceID: UInt64
    }

    var nextProbeUptime: TimeInterval
    /// Dispatches, not completed probes: the budget is charged when a read carries the probe.
    var probeCount: Int = 0
    var firstHidden: FirstHiddenMark?
}

/// One probe a single-pid event read carries to the background.
struct AbsentSeatProbeRequest {
    let cgWindowID: CGWindowID
    let seatToken: String
    let element: AXUIElement
    let instanceID: UInt64
    let probeCount: Int
}

struct AbsentSeatProbeEvidence {
    let request: AbsentSeatProbeRequest
    let element: AbsentSeatReleaseDecision.ElementState
    let windowSpaceIDs: [Int]?
    let currentSpaceIDs: Set<Int>?

    var spaces: AbsentSeatReleaseDecision.SpaceClass {
        .classify(windowSpaceIDs: windowSpaceIDs, currentSpaceIDs: currentSpaceIDs)
    }
}

protocol AbsentSeatProbing: Sendable {
    func probe(_ request: AbsentSeatProbeRequest, messagingTimeout: TimeInterval) -> AbsentSeatProbeEvidence
}

struct LiveAbsentSeatProber: AbsentSeatProbing {
    func probe(_ request: AbsentSeatProbeRequest, messagingTimeout: TimeInterval) -> AbsentSeatProbeEvidence {
        AXUIElementSetMessagingTimeout(request.element, Float(messagingTimeout))
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(request.element, kAXMinimizedAttribute as CFString, &value)
        let element: AbsentSeatReleaseDecision.ElementState
        switch error {
        case .success: element = .alive(minimized: value as? Bool)
        case .invalidUIElement: element = .dead
        default: element = .unknown(errorCode: error.rawValue)
        }
        return AbsentSeatProbeEvidence(
            request: request,
            element: element,
            windowSpaceIDs: Self.spaceIDs(of: request.cgWindowID),
            currentSpaceIDs: Self.currentSpaceIDs()
        )
    }

    // Own SkyLight loading rather than `WindowSpaceMembershipReader` / `ManagedSpaceLayoutReader`:
    // those live in `FullscreenIntentMonitor.swift`, which the test target does not compile.
    private typealias MainConnectionIDFn = @convention(c) () -> Int32
    private typealias CopySpacesForWindowsFn = @convention(c) (Int32, Int32, CFArray) -> CFArray?
    private typealias CopyManagedDisplaySpacesFn = @convention(c) (Int32) -> CFArray?

    private static let symbols: (cid: Int32, forWindows: CopySpacesForWindowsFn, managed: CopyManagedDisplaySpacesFn)? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let cidSym = dlsym(handle, "SLSMainConnectionID"),
              let forWindowsSym = dlsym(handle, "SLSCopySpacesForWindows"),
              let managedSym = dlsym(handle, "SLSCopyManagedDisplaySpaces") else { return nil }
        return (
            unsafeBitCast(cidSym, to: MainConnectionIDFn.self)(),
            unsafeBitCast(forWindowsSym, to: CopySpacesForWindowsFn.self),
            unsafeBitCast(managedSym, to: CopyManagedDisplaySpacesFn.self)
        )
    }()

    /// Selector `0x7` = every Space, as Dock uses it. Nil = unreadable (unknown, not "no Space").
    private static func spaceIDs(of cgWindowID: CGWindowID) -> [Int]? {
        guard cgWindowID > 0, let symbols,
              let raw = symbols.forWindows(symbols.cid, 0x7, [NSNumber(value: cgWindowID)] as CFArray) as? [NSNumber]
        else { return nil }
        return raw.map(\.intValue)
    }

    /// Every display's current Space.
    private static func currentSpaceIDs() -> Set<Int>? {
        guard let symbols, let displays = symbols.managed(symbols.cid) as? [[String: Any]] else { return nil }
        let ids = displays.compactMap { display -> Int? in
            guard let current = display["Current Space"] as? [String: Any] else { return nil }
            return (current["ManagedSpaceID"] as? Int) ?? (current["id64"] as? Int)
        }
        return ids.isEmpty ? nil : Set(ids)
    }
}
