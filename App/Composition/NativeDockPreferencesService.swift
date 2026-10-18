import AppKit
import Foundation
import Security

typealias ShellRunner = @MainActor (_ executable: String, _ arguments: [String]) throws -> Void
typealias URLOpener = @MainActor (URL) -> Bool

/// Snapshot of the system Dock's actual auto-hide state. delay of nil = the autohide-delay key doesn't exist (system default).
struct NativeDockAutohideState: Equatable {
    var enabled: Bool
    var delay: Double?
}

/// Writing the system Dock now has only the single path `apply(delay:)` (owner decided 2026-08-01): the show/hide commands in the menu have been removed,
/// and the whole group is expressed by a slider + confirm row -- the slider can express every state (always shown / seconds / no wake), so the commands were redundant,
/// and since they only toggle `autohide` without touching `autohide-delay`, the literal promise of "hide" exceeded the actual effect, which was misleading.
/// One-key show/hide is handed back to the system's own ⌥⌘D (held by macOS, always effective, and it reuses the delay tier written here).
@MainActor
protocol NativeDockPreferencesServicing {
    var isAvailable: Bool { get }
    func apply(delay: Double) throws
    /// One-time write for the first-run guide screen: each of the three items is optional, and **the whole batch restarts the Dock only once** (the screen flashes once).
    func apply(recommendations: NativeDockRecommendations) throws
    /// The system Dock's current auto-hide state. nil = unreadable (sandbox etc.); the caller falls back to deriving from the locally stored value.
    /// The actual system value must be read: the user can change it at any time via ⌥⌘D / System Settings, so the locally stored value goes stale.
    func currentAutohideState() async -> NativeDockAutohideState?
    /// Only opens the Dock page in System Settings; does not modify preferences, and is not subject to the sandbox gate on the write path.
    func openSystemSettings() -> Bool
}

struct SandboxEnvironment {
    var isSandboxed: Bool

    static var current: SandboxEnvironment {
        let key = "com.apple.security.app-sandbox" as CFString
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, key, nil) else {
            return SandboxEnvironment(isSandboxed: false)
        }
        return SandboxEnvironment(isSandboxed: (value as? Bool) == true)
    }
}

@MainActor
final class NativeDockPreferencesService: NativeDockPreferencesServicing {
    /// The system Dock's "no wake" value. Deliberately uses 999 rather than an extreme float, since the Dock's preference parsing of the latter is unstable.
    static let noWakeDelay = 999.0

    private let sandbox: SandboxEnvironment
    private let runner: ShellRunner
    private let autohideReader: @Sendable () -> NativeDockAutohideState?
    private let urlOpener: URLOpener
    private let readerQueue = DispatchQueue(label: "app.neobar.NeoBar.native-dock-reader", qos: .userInitiated)

    init(sandbox: SandboxEnvironment = .current,
         runner: @escaping ShellRunner = NativeDockPreferencesService.runProcess,
         autohideReader: @escaping @Sendable () -> NativeDockAutohideState? = { NativeDockPreferencesService.readAutohideStateFromSystem() },
         urlOpener: @escaping URLOpener = NativeDockPreferencesService.openURL) {
        self.sandbox = sandbox
        self.runner = runner
        self.autohideReader = autohideReader
        self.urlOpener = urlOpener
    }

    var isAvailable: Bool { !sandbox.isSandboxed }

    func currentAutohideState() async -> NativeDockAutohideState? {
        guard isAvailable else { return nil }
        let autohideReader = autohideReader
        let readerQueue = readerQueue
        return await withCheckedContinuation { continuation in
            readerQueue.async {
                continuation.resume(returning: autohideReader())
            }
        }
    }

    /// Monterey uses "Dock & Menu Bar", while Ventura and later map to "Desktop & Dock".
    /// When the deep link fails, hand off to the system to open Dock.prefPane; neither path launches a subprocess.
    func openSystemSettings() -> Bool {
        if let primary = URL(string: "x-apple.systempreferences:com.apple.preference.dock"),
           urlOpener(primary) {
            return true
        }
        return urlOpener(URL(fileURLWithPath: "/System/Library/PreferencePanes/Dock.prefPane"))
    }

    private static func openURL(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }

    nonisolated static func readAutohideStateFromSystem() -> NativeDockAutohideState? {
        let domain = "com.apple.dock" as CFString
        // External changes (⌥⌘D / System Settings / killall Dock) don't automatically enter this process's CFPreferences cache,
        // so a sync is required before every read, otherwise stale values may be returned indefinitely.
        return readAutohideState(
            synchronize: { CFPreferencesAppSynchronize(domain) },
            valueForKey: { key in
                CFPreferencesCopyAppValue(key as CFString, domain)
            }
        )
    }

    /// Injects the sync and fetch actions, which both isolates CFPreferences I/O and lets branches such as sync failure be unit-tested directly.
    nonisolated static func readAutohideState(
        synchronize: () -> Bool,
        valueForKey: (String) -> Any?
    ) -> NativeDockAutohideState? {
        guard synchronize() else { return nil }
        return decodeAutohideState(
            autohideValue: valueForKey("autohide"),
            delayValue: valueForKey("autohide-delay")
        )
    }

    /// Pure decoding rules: a missing autohide key means off; present but not a boolean means the whole snapshot is unreadable.
    /// When on, a missing delay key means the system default and a bad type means unreadable; when off, delay doesn't affect the switch's truth value.
    nonisolated static func decodeAutohideState(
        autohideValue: Any?,
        delayValue: Any?
    ) -> NativeDockAutohideState? {
        let enabled: Bool
        if let autohideValue {
            guard let decoded = strictBooleanValue(autohideValue) else { return nil }
            enabled = decoded
        } else {
            enabled = false
        }

        if !enabled {
            let delay = delayValue.flatMap { finiteNumericValue($0) }
            return NativeDockAutohideState(enabled: false, delay: delay)
        }

        let delay: Double?
        if let delayValue {
            guard let decoded = finiteNumericValue(delayValue) else { return nil }
            delay = decoded
        } else {
            delay = nil
        }
        return NativeDockAutohideState(enabled: enabled, delay: delay)
    }

    /// Slider: writes the whole tier. The always-shown tier only turns off `autohide` and writes no delay -- delay is meaningless then, and writing it would overwrite the user's original value.
    func apply(delay: Double) throws {
        guard isAvailable else { throw NativeDockPreferencesError.sandboxed }
        for command in Self.commands(for: delay) {
            try runner(command.executable, command.arguments)
        }
    }

    func apply(recommendations: NativeDockRecommendations) throws {
        guard isAvailable else { throw NativeDockPreferencesError.sandboxed }
        for command in Self.commands(for: recommendations) {
            try runner(command.executable, command.arguments)
        }
    }

    static let restartDockCommand: (executable: String, arguments: [String]) = ("/usr/bin/killall", ["Dock"])

    static func commands(for delay: Double) -> [(executable: String, arguments: [String])] {
        autohideWriteCommands(for: delay) + [restartDockCommand]
    }

    /// The guide screen: each of the three items is optional, and commands are ordered autohide -> mineffect -> minimize-to-application,
    /// **with just one `killall Dock` appended at the end**. Restarting after each write would make the user see the screen flash three times in a row.
    /// If nothing is ticked, return an empty array -- no write, no restart, no flash.
    static func commands(for recommendations: NativeDockRecommendations) -> [(executable: String, arguments: [String])] {
        guard !recommendations.isEmpty else { return [] }

        var commands: [(executable: String, arguments: [String])] = []
        if let delay = recommendations.autoHideDelay {
            commands += autohideWriteCommands(for: delay)
        }
        if recommendations.minimizeEffectScale {
            commands.append(("/usr/bin/defaults", ["write", "com.apple.dock", "mineffect", "-string", "scale"]))
        }
        if recommendations.minimizeIntoAppIcon {
            commands.append(("/usr/bin/defaults", ["write", "com.apple.dock", "minimize-to-application", "-bool", "true"]))
        }
        return commands + [restartDockCommand]
    }

    /// Only the write part, without `killall`, so that multiple groups of writes can be merged into a single restart.
    private static func autohideWriteCommands(enabled: Bool) -> [(executable: String, arguments: [String])] {
        [("/usr/bin/defaults", ["write", "com.apple.dock", "autohide", "-bool", enabled ? "true" : "false"])]
    }

    private static func autohideWriteCommands(for delay: Double) -> [(executable: String, arguments: [String])] {
        if delay <= AppSettingsStore.neverHideDelay {
            return autohideWriteCommands(enabled: false)
        }

        let effectiveDelay = delay >= AppSettingsStore.neverWakeDelay
            ? noWakeDelay
            : AppSettingsStore.snapDelay(delay, fallbackForNonFinite: AppSettingsStore.defaultNativeDockAutoHideDelay)
        return [
            ("/usr/bin/defaults", ["write", "com.apple.dock", "autohide", "-bool", "true"]),
            ("/usr/bin/defaults", ["write", "com.apple.dock", "autohide-delay", "-float", String(format: "%.1f", effectiveDelay)]),
        ]
    }

    private static func runProcess(executable: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NativeDockPreferencesError.commandFailed(executable: executable, status: process.terminationStatus)
        }
    }

    nonisolated private static func strictBooleanValue(_ value: Any) -> Bool? {
        DefaultsValueParsing.strictBooleanValue(value)
    }

    nonisolated private static func finiteNumericValue(_ value: Any) -> Double? {
        DefaultsValueParsing.finiteNumericValue(value)
    }
}

/// Frozen keys: the "fully hide" of `d08e8d6` once used these three keys to record the exact delay before hiding. After the slider came back, this set of snapshots
/// is no longer needed, but is **not read, not written, and not deleted** -- existing users' machines may hold exact old values (such as 0.75, which the slider's 0.1 step
/// can't express anyway); deleting would both lose values and break the data boundary of `git revert d08e8d6`. Left as orphan keys, harmless.
/// Any lossy migration must be cleared with the owner first. Only the names are kept here, to prevent future key collisions.
///
/// - `app.neobar.nativeDock.restoreDelay.captured`
/// - `app.neobar.nativeDock.restoreDelay.present`
/// - `app.neobar.nativeDock.restoreDelay.value`

enum NativeDockPreferencesError: LocalizedError {
    case sandboxed
    case commandFailed(executable: String, status: Int32)

    var errorDescription: String? {
        switch self {
        case .sandboxed:
            return String(localized: "Dock settings can’t be changed directly from a sandboxed environment.")
        case .commandFailed(let executable, let status):
            return String(format: String(localized: "%@ failed (status code %d)."), executable, status)
        }
    }
}
