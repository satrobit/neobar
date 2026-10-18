import ApplicationServices
import Foundation

/// The I/O layer for the accessibility permission. All three entry points are injectable, so onboarding logic can be unit tested independent of system state.
///
/// Note: this file is also compiled into the window-lab target, which has no `AccessibilityPermissionDecision.swift`,
/// so only the raw fact "is the volume read-only" is provided here, and classifying the install location is left to the caller to compose.
struct PermissionService {
    private let trustCheck: () -> Bool
    private let promptRequest: () -> Bool
    private let readOnlyVolumeCheck: (URL) -> Bool?

    init(
        trustCheck: @escaping () -> Bool = { AXIsProcessTrusted() },
        promptRequest: @escaping () -> Bool = {
            AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        },
        readOnlyVolumeCheck: @escaping (URL) -> Bool? = PermissionService.systemReadOnlyVolumeCheck
    ) {
        self.trustCheck = trustCheck
        self.promptRequest = promptRequest
        self.readOnlyVolumeCheck = readOnlyVolumeCheck
    }

    func hasRequiredPermissions() -> Bool {
        trustCheck()
    }

    /// Show the system-native request dialog, and also register this app in the accessibility list.
    /// **Call only from a stable install location**: calling it from a temporary copy leaves a dead record in the system pointing at that copy.
    @discardableResult
    func requestAccessibilityPermission() -> Bool {
        promptRequest()
    }

    /// `nil` = volume info cannot be read (the volume was just unmounted, and the like).
    func isReadOnlyVolume(_ url: URL) -> Bool? {
        readOnlyVolumeCheck(url)
    }

    static func systemReadOnlyVolumeCheck(_ url: URL) -> Bool? {
        (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly
    }
}
