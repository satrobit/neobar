import Foundation

// MARK: - Install location

/// Where this copy of the app currently lives.
///
/// macOS Accessibility authorization is bound to the **specific app copy**. For a copy running from a read-only volume (a mounted disk image) or an
/// App Translocation temporary path, the permission will never take effect even if the user ticks it in System Settings --
/// the authorization record points to a copy that disappears on unmount/quit. So for these two locations the user must first be asked to move the app,
/// and we **must never** send a registration request to TCC, so as not to leave a dead record pointing to a temporary copy in the system.
enum AppInstallLocation: String, Equatable {
    case applications
    case readOnlyVolume
    case appTranslocation
    case other

    /// - Parameter isReadOnlyVolume: returning `nil` means the volume info can't be read (e.g. the volume was just unmounted).
    ///   In that case always treat it as writable -- better to miss a block than to lock a user with a normal location onto the move page.
    init(bundleURL: URL, isReadOnlyVolume: (URL) -> Bool?) {
        let url = bundleURL.standardizedFileURL
        let path = url.path

        if path.split(separator: "/").contains("AppTranslocation") {
            self = .appTranslocation
        } else if Self.isUnderApplications(path) {
            self = .applications
        } else if isReadOnlyVolume(url) == true {
            self = .readOnlyVolume
        } else {
            self = .other
        }
    }

    private static func isUnderApplications(_ path: String) -> Bool {
        for root in ["/Applications", NSHomeDirectory() + "/Applications"] {
            if path == root || path.hasPrefix(root + "/") { return true }
        }
        return false
    }

    /// A temporary location must never be allowed to register with TCC.
    var allowsAccessibilityPrompt: Bool { !isTransient }

    /// A temporary copy serves only as a one-shot onboarding shell: it doesn't take over other instances, register global hotkeys, or request permissions.
    var isTransient: Bool {
        switch self {
        case .readOnlyVolume, .appTranslocation:
            return true
        case .applications, .other:
            return false
        }
    }
}

// MARK: - Onboarding steps

/// Which step the onboarding page should currently show.
///
/// ⚠️ `.stalled` only means "we've waited a long time without getting the permission, time to give troubleshooting advice"; it is **not** a judgment that
/// "the old authorization record in the system has become invalid" -- we can't read the TCC database, so we can neither prove
/// whether the user actually turned the switch on, nor prove the old record mismatches. Any copy based on it must be conditional throughout.
enum PermissionOnboardingState: Equatable {
    case moveToApplications(AppInstallLocation)
    case waiting
    case stalled
    case granted

    static func initial(installLocation: AppInstallLocation, isTrusted: Bool) -> Self {
        // Location judgment takes priority over trust judgment: even if a temporary copy is currently trusted, that authorization disappears with the copy.
        guard installLocation.allowsAccessibilityPrompt else {
            return .moveToApplications(installLocation)
        }
        return isTrusted ? .granted : .waiting
    }

    func updated(isTrusted: Bool, elapsed: TimeInterval, stallAfter: TimeInterval) -> Self {
        if case .moveToApplications = self { return self }
        if isTrusted { return .granted }
        return elapsed >= stallAfter ? .stalled : .waiting
    }
}

// MARK: - Runtime loss debounce

/// Debounce decision for permission loss at runtime.
///
/// It decides only **when the user-visible shutdown happens** (collapsing the task strip, showing the recovery onboarding).
/// The snapshot protection of maximize avoidance **doesn't rely on it**: when there is a session / pending-restore state that side still polls every 0.2s,
/// while this runs once every 5s, and the gap in between is covered by `WindowLiftAvoidanceController` self-checking in `poll()`.
struct PermissionLossDetector: Equatable {
    enum Verdict: Equatable {
        /// Permission is fine.
        case stable
        /// Read false once. The user notices nothing, but the window snapshot must be frozen immediately.
        case uncertain
        /// Loss confirmed: false read consecutively, and it has lasted long enough.
        case lost
    }

    /// Minimum duration needed to declare loss. Equals one polling period of the watchdog --
    /// "two consecutive reads" alone isn't enough: a timer tick and `applicationDidBecomeActive`
    /// may arrive back to back within tens of milliseconds, which doesn't prove the permission is really gone.
    static let minimumSustained: TimeInterval = 5

    private var firstFalseAt: TimeInterval?
    private var consecutiveFalse = 0

    init() {}

    /// - Parameter at: a **monotonic** clock (`ProcessInfo.processInfo.systemUptime`), not the wall clock.
    mutating func record(trusted: Bool, at: TimeInterval) -> Verdict {
        guard !trusted else {
            firstFalseAt = nil
            consecutiveFalse = 0
            return .stable
        }

        // The anchor is set only once, at the first false: out-of-order / early-arriving samples must not wind it back,
        // otherwise a series of jittery samples would reset "how long it has lasted" endlessly.
        if firstFalseAt == nil { firstFalseAt = at }
        consecutiveFalse += 1

        let elapsed = max(0, at - (firstFalseAt ?? at))
        if consecutiveFalse >= 2, elapsed >= Self.minimumSustained { return .lost }
        return .uncertain
    }
}

// MARK: - System Settings entry

enum AccessibilitySettingsLink {
    /// Deep link to "Privacy & Security -> Accessibility". Shared by `AppDelegate` and the status menu in this one place;
    /// don't copy the string around separately again.
    static let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
}
