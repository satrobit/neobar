import Foundation

// MARK: - Inputs and outputs

enum PermissionActivationPolicy: Equatable {
    /// Normal running state with no Dock icon.
    case accessory
    /// Regular app: used only when the onboarding window needs to be brought to the front.
    case regular
}

enum PermissionEpisodePurpose: Equatable {
    case initialLaunch
    case runtimeRecovery
}

/// Overall phase related to permissions.
///
/// Every entry into "waiting for authorization" allocates a new `episode`, and an async completion must carry it when it comes back --
/// setting the phase alone can't stop a task already inside an `await` (the event loop is still running while `applicationShouldTerminate` returns
/// `.terminateLater`); callbacks with a mismatched generation must be discarded.
enum PermissionPhase: Equatable {
    case idle
    /// One-shot onboarding shell for a temporary copy (read-only volume / App Translocation); terminal state.
    case transientShell(AppInstallLocation)
    case onboarding(episode: UInt64)
    case running
    /// The watchdog read false for the first time. No UI change, but the window snapshot is already frozen.
    case uncertain
    case suspended(episode: UInt64)
    case restoringWindows(episode: UInt64)
    case relaunching(episode: UInt64)
    case relaunchFailed(episode: UInt64, message: String)
    case terminating
}

enum PermissionEvent: Equatable {
    case launched(location: AppInstallLocation, trusted: Bool)
    case trustVerdict(PermissionLossDetector.Verdict)
    case grantObserved(episode: UInt64)
    case windowsRestored(episode: UInt64)
    case relaunchSucceeded(episode: UInt64)
    case relaunchFailed(episode: UInt64, message: String)
    case retryRequested
    case recheckRequested
    case quitRequested
    case terminationRequested
}

enum PermissionEffect: Equatable {
    case startApp
    case setActivationPolicy(PermissionActivationPolicy)
    case showGuide
    case updateGuide
    case closeGuide
    case startPermissionEpisode(purpose: PermissionEpisodePurpose, episode: UInt64)
    case stopPermissionEpisode
    case requestSystemPrompt
    case recheckNow
    case startWatchdog
    case stopWatchdog
    case freezeLift
    case unfreezeLift
    case restoreLiftedWindows(episode: UInt64)
    case suspendPanelsAndStores
    case releaseHotKey
    case registerHotKey
    case launchNewInstance(episode: UInt64)
    case cancelRecoveryTask
    case terminateSelf
}

/// What the onboarding window should display. `nil` means there should be no window.
///
/// The troubleshooting copy for first-time authorization and runtime recovery **must be kept separate**: when first-time authorization succeeds the current process simply continues to
/// `startApp()`, with no "automatic restart" and no leftover lifted windows from this round.
enum PermissionPresentation: Equatable {
    case moveToApplications(AppInstallLocation)
    case waiting
    case stalled
    case recoveryWaiting
    case recoveryStalled
    case restoringWindows
    case relaunching
    case relaunchFailed(message: String)
}

// MARK: - State machine

/// Pure state machine: doesn't touch AppKit; side effects are returned only as `PermissionEffect` and executed by the coordinator.
struct PermissionRecoveryMachine: Equatable {
    private(set) var phase: PermissionPhase = .idle
    private var episodeCounter: UInt64 = 0

    init() {}

    mutating func handle(_ event: PermissionEvent) -> [PermissionEffect] {
        // The terminal state swallows everything: once quitting is decided, no late recovery event may spawn a new instance again.
        if case .terminating = phase { return [] }

        switch event {
        case .terminationRequested:
            phase = .terminating
            return [.stopWatchdog, .cancelRecoveryTask, .stopPermissionEpisode]

        case .quitRequested:
            phase = .terminating
            return [.stopWatchdog, .cancelRecoveryTask, .stopPermissionEpisode, .terminateSelf]

        case let .launched(location, trusted):
            return handleLaunched(location: location, trusted: trusted)

        case let .trustVerdict(verdict):
            return handleTrustVerdict(verdict)

        case let .grantObserved(episode):
            return handleGrantObserved(episode: episode)

        case let .windowsRestored(episode):
            guard case let .restoringWindows(current) = phase, current == episode else { return [] }
            phase = .relaunching(episode: current)
            return [.updateGuide, .releaseHotKey, .launchNewInstance(episode: current)]

        case let .relaunchSucceeded(episode):
            guard case let .relaunching(current) = phase, current == episode else { return [] }
            return [.terminateSelf]

        case let .relaunchFailed(episode, message):
            guard case let .relaunching(current) = phase, current == episode else { return [] }
            phase = .relaunchFailed(episode: current, message: message)
            // If spawning the new instance fails, the old instance must keep living, and the hotkey must be given back.
            return [.registerHotKey, .updateGuide]

        case .retryRequested:
            guard case let .relaunchFailed(current, _) = phase else { return [] }
            phase = .relaunching(episode: current)
            // A retry must likewise release the hotkey first, and can't skip it because "it was already released last time" --
            // the failure branch has already re-registered it.
            return [.updateGuide, .releaseHotKey, .launchNewInstance(episode: current)]

        case .recheckRequested:
            switch phase {
            case .onboarding, .suspended:
                return [.recheckNow]
            default:
                return []
            }
        }
    }

    private mutating func handleLaunched(
        location: AppInstallLocation,
        trusted: Bool
    ) -> [PermissionEffect] {
        guard case .idle = phase else { return [] }

        if location.isTransient {
            // Temporary copy: don't request the permission (so as not to write a dead record pointing at a temporary copy into TCC),
            // and don't poll either -- as long as it stays in this location it can never truly get the permission.
            phase = .transientShell(location)
            return [.setActivationPolicy(.regular), .showGuide]
        }

        if trusted {
            phase = .running
            return [.setActivationPolicy(.accessory), .startApp, .startWatchdog]
        }

        let episode = nextEpisode()
        phase = .onboarding(episode: episode)
        return [
            .setActivationPolicy(.regular),
            .showGuide,
            .startPermissionEpisode(purpose: .initialLaunch, episode: episode),
            .requestSystemPrompt,
        ]
    }

    private mutating func handleTrustVerdict(
        _ verdict: PermissionLossDetector.Verdict
    ) -> [PermissionEffect] {
        switch verdict {
        case .stable:
            guard case .uncertain = phase else { return [] }
            phase = .running
            return [.unfreezeLift]

        case .uncertain:
            guard case .running = phase else { return [] }
            phase = .uncertain
            return [.freezeLift]

        case .lost:
            switch phase {
            case .running, .uncertain:
                let episode = nextEpisode()
                phase = .suspended(episode: episode)
                return [
                    .stopWatchdog,
                    // When jumping from `.running` straight to `.lost` it hasn't been frozen yet; freezing is idempotent.
                    .freezeLift,
                    .suspendPanelsAndStores,
                    .setActivationPolicy(.regular),
                    .showGuide,
                    .startPermissionEpisode(purpose: .runtimeRecovery, episode: episode),
                    // After `tccutil reset` this instance may no longer be in the Accessibility list,
                    // and polling alone leaves the user nothing to tick -- it must register again.
                    .requestSystemPrompt,
                ]
            default:
                return []
            }
        }
    }

    private mutating func handleGrantObserved(episode: UInt64) -> [PermissionEffect] {
        switch phase {
        case let .onboarding(current) where current == episode:
            phase = .running
            return [
                .stopPermissionEpisode,
                .closeGuide,
                .setActivationPolicy(.accessory),
                .startApp,
                .startWatchdog,
            ]

        case let .suspended(current) where current == episode:
            // Restoration is deferred to this moment: the permission has just come back, so AX can write to the lifted windows.
            phase = .restoringWindows(episode: current)
            return [.stopPermissionEpisode, .updateGuide, .restoreLiftedWindows(episode: current)]

        default:
            return []
        }
    }

    private mutating func nextEpisode() -> UInt64 {
        episodeCounter &+= 1
        return episodeCounter
    }

    // MARK: Presentation state

    static func presentation(
        phase: PermissionPhase,
        onboarding: PermissionOnboardingState
    ) -> PermissionPresentation? {
        switch phase {
        case .idle, .running, .uncertain, .terminating:
            return nil

        case let .transientShell(location):
            return .moveToApplications(location)

        case .onboarding:
            switch onboarding {
            case let .moveToApplications(location): return .moveToApplications(location)
            case .waiting, .granted: return .waiting
            case .stalled: return .stalled
            }

        case .suspended:
            switch onboarding {
            case let .moveToApplications(location): return .moveToApplications(location)
            case .waiting, .granted: return .recoveryWaiting
            case .stalled: return .recoveryStalled
            }

        case .restoringWindows:
            return .restoringWindows

        case .relaunching:
            return .relaunching

        case let .relaunchFailed(_, message):
            return .relaunchFailed(message: message)
        }
    }
}
