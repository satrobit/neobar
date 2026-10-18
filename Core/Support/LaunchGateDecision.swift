import Foundation

/// Pure release policy for a launcher bounce session.
///
/// The caller owns all process and window I/O. This type only orders the facts so an
/// early activation-policy sample cannot end the bounce before the launched app has
/// either produced a new real window or proved that it intentionally has no window.
enum LaunchGateDecision {
    static let policySettleDelay: TimeInterval = 1.5
    static let timeout: TimeInterval = 20

    enum ActivationPolicy: Equatable {
        case regular
        case accessory
        case prohibited
        case unknown
    }

    struct ProcessObservation: Equatable {
        let isAlive: Bool
        let generationMatches: Bool
        let activationPolicy: ActivationPolicy
        let isFinishedLaunching: Bool
        let bundleDeclaresNoWindow: Bool

        init(
            isAlive: Bool,
            generationMatches: Bool,
            activationPolicy: ActivationPolicy,
            isFinishedLaunching: Bool,
            bundleDeclaresNoWindow: Bool
        ) {
            self.isAlive = isAlive
            self.generationMatches = generationMatches
            self.activationPolicy = activationPolicy
            self.isFinishedLaunching = isFinishedLaunching
            self.bundleDeclaresNoWindow = bundleDeclaresNoWindow
        }
    }

    struct Observation: Equatable {
        let openFailed: Bool
        let hasNewRealWindow: Bool
        let launchedProcess: ProcessObservation?
        let hasOtherRegularProcess: Bool
        let elapsed: TimeInterval

        init(
            openFailed: Bool,
            hasNewRealWindow: Bool,
            launchedProcess: ProcessObservation?,
            hasOtherRegularProcess: Bool,
            elapsed: TimeInterval
        ) {
            self.openFailed = openFailed
            self.hasNewRealWindow = hasNewRealWindow
            self.launchedProcess = launchedProcess
            self.hasOtherRegularProcess = hasOtherRegularProcess
            self.elapsed = elapsed
        }
    }

    enum ReleaseReason: Equatable {
        case openFailed
        case realWindow
        case processGone
        case accessoryProcess
        case timeout
    }

    enum Verdict: Equatable {
        case hold
        case release(ReleaseReason)
    }

    /// Precedence is part of the contract: explicit open failure wins, then a new real
    /// window, then terminal process facts, and only then the bounded timeout.
    static func evaluate(_ observation: Observation) -> Verdict {
        if observation.openFailed {
            return .release(.openFailed)
        }
        if observation.hasNewRealWindow {
            return .release(.realWindow)
        }

        if let process = observation.launchedProcess {
            let processIsCurrent = process.isAlive && process.generationMatches
            if !processIsCurrent && !observation.hasOtherRegularProcess {
                return .release(.processGone)
            }

            let policyHasSettled = observation.elapsed >= policySettleDelay
                && process.isFinishedLaunching
            if processIsCurrent && policyHasSettled && !observation.hasOtherRegularProcess {
                switch process.activationPolicy {
                case .accessory:
                    return .release(.accessoryProcess)
                case .prohibited where process.bundleDeclaresNoWindow:
                    return .release(.accessoryProcess)
                case .regular, .prohibited, .unknown:
                    break
                }
            }
        }

        if observation.elapsed >= timeout {
            return .release(.timeout)
        }
        return .hold
    }

    /// A launcher tap whose bundle already has a live, finished-launching process that
    /// `evaluate` could only ever release on policy grounds (a menu-bar `.accessory` app,
    /// or a `.prohibited` process of a bundle that declares no window) needs no session:
    /// there is no launch to wait for, and a bounce would just lock the chip for the
    /// settling floor on every click. The caller sends the plain reopen instead.
    static func runningProcessNeedsNoSession(
        activationPolicy: ActivationPolicy,
        isFinishedLaunching: Bool,
        bundleDeclaresNoWindow: Bool
    ) -> Bool {
        guard isFinishedLaunching else { return false }
        switch activationPolicy {
        case .accessory:
            return true
        case .prohibited:
            return bundleDeclaresNoWindow
        case .regular, .unknown:
            return false
        }
    }
}

/// Detects a real window identity that appeared after a launch session began.
///
/// The caller filters both sets to the target bundle. Identities deliberately do not
/// include the process returned by the open completion because some apps expose windows
/// from a different host process.
enum LaunchWindowBaselineDecision {
    static func hasNewWindow<Identity: Hashable>(
        baseline: Set<Identity>,
        current: Set<Identity>
    ) -> Bool {
        !current.subtracting(baseline).isEmpty
    }
}

/// Stores one token-guarded value per bundle ID.
///
/// Tokens make delayed completion and timeout callbacks harmless after a newer launch
/// session has replaced the one they captured. Values are intentionally not observable;
/// callers can publish a cheap projection from `bundleIDs` instead.
struct LaunchSessionTokenRegistry<Value> {
    private struct StoredEntry {
        let token: UInt64
        var value: Value
    }

    private var entries: [String: StoredEntry] = [:]
    private var nextToken: UInt64 = 1

    var bundleIDs: Set<String> {
        Set(entries.keys)
    }

    var currentEntries: [(bundleID: String, token: UInt64, value: Value)] {
        entries.keys.sorted().compactMap { bundleID in
            guard let entry = entries[bundleID] else { return nil }
            return (bundleID: bundleID, token: entry.token, value: entry.value)
        }
    }

    /// Begins only when the bundle has no active session. The factory is not called for
    /// a duplicate begin, which keeps application-opening side effects outside that path.
    mutating func begin(
        bundleID: String,
        makeValue: (UInt64) -> Value
    ) -> UInt64? {
        guard entries[bundleID] == nil else { return nil }

        let token = nextToken
        nextToken = token == UInt64.max ? 1 : token + 1
        entries[bundleID] = StoredEntry(token: token, value: makeValue(token))
        return token
    }

    func entry(for bundleID: String) -> (token: UInt64, value: Value)? {
        guard let entry = entries[bundleID] else { return nil }
        return (token: entry.token, value: entry.value)
    }

    /// Applies a mutation only to the currently active token.
    @discardableResult
    mutating func update(
        bundleID: String,
        token: UInt64,
        _ updateValue: (inout Value) -> Void
    ) -> Bool {
        guard var entry = entries[bundleID], entry.token == token else { return false }
        updateValue(&entry.value)
        entries[bundleID] = entry
        return true
    }

    /// Removes and returns a value only when the supplied token is still current.
    mutating func remove(bundleID: String, token: UInt64) -> Value? {
        guard let entry = entries[bundleID], entry.token == token else { return nil }
        entries.removeValue(forKey: bundleID)
        return entry.value
    }

    /// Clears all sessions. The result is ordered by bundle ID for deterministic cleanup.
    mutating func removeAll() -> [Value] {
        let values = currentEntries.map { $0.value }
        entries.removeAll()
        return values
    }
}
