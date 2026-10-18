import Foundation
import ServiceManagement

enum LaunchAtLoginState: Equatable {
    /// The system's login-items list can't be opened (only macOS 12's legacy API ends up here).
    /// No longer means "system version too old" -- 12 and 13+ each have their own integration path.
    case unsupported
    case off
    case on
    case requiresApproval
}

struct LaunchAtLoginMenuPresentation: Equatable {
    var title: String
    var isEnabled: Bool
    var isChecked: Bool
    var showsSettingsItem: Bool

    init(title: String, isEnabled: Bool, isChecked: Bool, showsSettingsItem: Bool) {
        self.title = title
        self.isEnabled = isEnabled
        self.isChecked = isChecked
        self.showsSettingsItem = showsSettingsItem
    }

    init(state: LaunchAtLoginState) {
        switch state {
        case .unsupported:
            title = String(localized: "Open at Login (Unavailable)")
            isEnabled = false
            isChecked = false
            showsSettingsItem = false
        case .off:
            title = String(localized: "Open at Login")
            isEnabled = true
            isChecked = false
            showsSettingsItem = false
        case .on:
            title = String(localized: "Open at Login")
            isEnabled = true
            isChecked = true
            showsSettingsItem = false
        case .requiresApproval:
            title = String(localized: "Open at Login (Pending Approval)")
            isEnabled = true
            isChecked = false
            showsSettingsItem = true
        }
    }
}

enum LaunchAtLoginMenuModel {
    static func requestedEnabledValue(afterSelecting state: LaunchAtLoginState) -> Bool? {
        switch state {
        case .unsupported:
            return nil
        case .off, .requiresApproval:
            return true
        case .on:
            return false
        }
    }
}

@MainActor
protocol LaunchAtLoginServicing {
    func currentState() async -> LaunchAtLoginState
    func setEnabled(_ enabled: Bool) throws
    func openSystemSettings()
}

/// The layer that actually touches the system, one of two depending on system version: macOS 13+ uses `SMAppService` (`ModernLoginItemBackend`),
/// macOS 12 uses the legacy login-items list (`LegacyLoginItemBackend`).
///
/// `readState()` is called on `LaunchAtLoginService`'s background queue (the menu path must not do system I/O on the main thread),
/// so implementations must not depend on the main thread; `setEnabled` / `openSettings` are still called on the main thread.
protocol LaunchAtLoginBackend: Sendable {
    func readState() -> LaunchAtLoginState
    func setEnabled(_ enabled: Bool) throws
    func openSettings()
}

@MainActor
final class LaunchAtLoginService: LaunchAtLoginServicing {
    private let backend: any LaunchAtLoginBackend
    private let readerQueue = DispatchQueue(label: "app.neobar.NeoBar.launch-at-login-reader", qos: .userInitiated)

    init(backend: any LaunchAtLoginBackend = LaunchAtLoginService.systemBackend()) {
        self.backend = backend
    }

    func currentState() async -> LaunchAtLoginState {
        let backend = backend
        let readerQueue = readerQueue
        return await withCheckedContinuation { continuation in
            readerQueue.async {
                continuation.resume(returning: backend.readState())
            }
        }
    }

    func setEnabled(_ enabled: Bool) throws {
        try backend.setEnabled(enabled)
    }

    func openSystemSettings() {
        backend.openSettings()
    }

    /// Both paths register the **currently running bundle**: ticking it on a development build pins the login item to `build/DerivedData/...`
    /// (see `.claude/rules/build-and-release.md` for the rule).
    nonisolated static func systemBackend() -> any LaunchAtLoginBackend {
        if #available(macOS 13.0, *) {
            return ModernLoginItemBackend()
        }
        return LegacyLoginItemBackend(list: SharedFileListLoginItems(), bundleURL: Bundle.main.bundleURL)
    }
}

/// macOS 13+: `SMAppService.mainApp`. After `register()` it may stay at `.requiresApproval`,
/// which needs the user to approve it in "System Settings -> General -> Login Items & Extensions"; this is not a failure.
@available(macOS 13.0, *)
struct ModernLoginItemBackend: LaunchAtLoginBackend {
    func readState() -> LaunchAtLoginState {
        Self.mapStatus(SMAppService.mainApp.status)
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private static func mapStatus(_ status: SMAppService.Status) -> LaunchAtLoginState {
        switch status {
        case .enabled:
            return .on
        case .requiresApproval:
            return .requiresApproval
        case .notRegistered, .notFound:
            return .off
        @unknown default:
            return .off
        }
    }
}

enum LaunchAtLoginError: LocalizedError {
    /// The login-items list can't be opened (the legacy API returned nil).
    case unsupported
    /// Insert / delete was rejected by the system.
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .unsupported:
            return String(localized: "Open at Login isn’t available on this Mac.")
        case .writeFailed:
            return String(localized: "Couldn’t update the Login Items list.")
        }
    }
}
