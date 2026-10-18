import AppKit
import SwiftUI

/// The window's root view. The scrollbar normally doesn't appear -- the window height is determined by the content's natural height,
/// and scrolling is truly needed only when truncated by the screen height.
struct PermissionOnboardingWindowContent: View {
    @ObservedObject var coordinator: PermissionRecoveryCoordinator

    var body: some View {
        ScrollView(.vertical) {
            PermissionOnboardingView(coordinator: coordinator)
        }
        .frame(width: PermissionOnboardingView.contentWidth)
    }
}

struct PermissionOnboardingView: View {
    /// The view observes only this one source.
    @ObservedObject var coordinator: PermissionRecoveryCoordinator

    /// Fixed content width: the window height is decided by `fittingSize`, and the width must not jitter with the copy length.
    static let contentWidth: CGFloat = 520

    private var presentation: PermissionPresentation {
        coordinator.presentation ?? .waiting
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.secondary)
            if let troubleshooting {
                troubleshootingBox(troubleshooting)
            }
            HStack(spacing: 8) {
                Spacer()
                actions
            }
        }
        .padding(28)
        .frame(width: Self.contentWidth, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: symbolName)
                .font(.system(size: 28))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title3.weight(.semibold))
                Text(subtitle)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func troubleshootingBox(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Switch already on but nothing happens?")
                .font(.callout.weight(.semibold))
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.1))
        )
    }

    // MARK: - Copy

    private var symbolName: String {
        switch presentation {
        case .moveToApplications: return "folder.badge.plus"
        case .waiting, .stalled: return "lock.shield"
        case .recoveryWaiting, .recoveryStalled: return "exclamationmark.shield"
        case .restoringWindows, .relaunching: return "arrow.clockwise"
        case .relaunchFailed: return "xmark.octagon"
        }
    }

    private var title: String {
        switch presentation {
        case .moveToApplications: return String(localized: "Move NeoBar to Applications")
        case .waiting, .stalled: return String(localized: "Turn On Accessibility Permission")
        case .recoveryWaiting, .recoveryStalled: return String(localized: "Accessibility Permission Was Revoked")
        case .restoringWindows: return String(localized: "Restoring Windows…")
        case .relaunching: return String(localized: "Restarting NeoBar…")
        case .relaunchFailed: return String(localized: "Restart Failed")
        }
    }

    private var subtitle: String {
        switch presentation {
        case .moveToApplications: return String(localized: "This copy is running from a temporary or read-only location.")
        case .waiting, .stalled: return String(localized: "NeoBar needs this permission to read and manage your windows.")
        case .recoveryWaiting, .recoveryStalled: return String(localized: "NeoBar will restart itself once you grant it again.")
        case .restoringWindows: return String(localized: "Putting the windows it moved back where they were.")
        case .relaunching: return String(localized: "This will only take a moment.")
        case .relaunchFailed: return String(localized: "NeoBar is still running. You can try again.")
        }
    }

    private var message: String {
        switch presentation {
        case .moveToApplications:
            return String(localized: """
            macOS ties Accessibility permission to one specific copy of an app. This copy is running from a \
            temporary or read-only location, so turning the switch on will not take effect — and the permission \
            record stays behind in System Settings after the disk image is ejected. \
            Drag NeoBar to your Applications folder and open it from there.
            """)
        case .waiting, .stalled:
            return String(format: String(localized: "Turn on NeoBar in %@. This window closes by itself once you do, and the taskbar finishes starting."), settingsPath)
        case .recoveryWaiting, .recoveryStalled:
            return String(format: String(localized: "NeoBar just lost its Accessibility permission, so the taskbar has been put away. Turn NeoBar back on in %@."), settingsPath)
        case .restoringWindows, .relaunching:
            return String(localized: "Nothing to do here — just a moment.")
        case let .relaunchFailed(message):
            return String(format: String(localized: "Couldn’t start a new instance of NeoBar: %@\n\nYou can click Retry, or quit and open it manually from your Applications folder."), message)
        }
    }

    /// "Delete the old entry and add it again" is only a **conditional troubleshooting suggestion**: we can't read the system's authorization database,
    /// so we can prove neither that the user has turned the switch on, nor that the old record has become mismatched. The copy must keep an uncertain tone,
    /// and must not presuppose the signing method either -- authorization for a package signed with a fixed certificate is valid across versions.
    private var troubleshooting: String? {
        let steps = String(localized: """
        If the switch is already on and nothing happens, a permission record left by an older version may no \
        longer match this copy of NeoBar. You can reset it:

        1. Quit NeoBar first — while it is running, the minus button in the list is greyed out and the \
        entry cannot be removed.
        2. In Privacy & Security > Accessibility, select NeoBar in the list and remove it with the minus \
        button. There may be more than one entry; remove them all.
        3. Open NeoBar again from your Applications folder, then add it and turn the switch on when prompted.
        """)
        switch presentation {
        case .stalled:
            return steps
        case .recoveryStalled:
            return steps + String(localized: """


            If simply turning the switch back on works, NeoBar restarts itself and there is nothing else \
            to do; going through the cleanup above means reopening it manually afterwards.
            Also, windows the taskbar had moved out of its way may sit one taskbar height short — maximizing \
            them once puts them back.
            """)
        default:
            return nil
        }
    }

    private var settingsPath: String {
        if #available(macOS 13, *) {
            return String(localized: "System Settings > Privacy & Security > Accessibility")
        }
        return String(localized: "System Preferences > Security & Privacy > Privacy > Accessibility")
    }

    // MARK: - Buttons

    @ViewBuilder
    private var actions: some View {
        switch presentation {
        case .moveToApplications:
            quitButton
            Button("Open Applications Folder") { coordinator.openApplications() }
                .keyboardShortcut(.defaultAction)

        case .waiting, .recoveryWaiting:
            quitButton
            Button("Open System Settings") { coordinator.openSettings() }
                .keyboardShortcut(.defaultAction)

        case .stalled, .recoveryStalled:
            quitButton
            Button("Check Again") { coordinator.recheck() }
            Button("Open System Settings") { coordinator.openSettings() }
                .keyboardShortcut(.defaultAction)

        case .restoringWindows, .relaunching:
            ProgressView()
                .controlSize(.small)

        case .relaunchFailed:
            quitButton
            Button("Retry") { coordinator.retryRelaunch() }
                .keyboardShortcut(.defaultAction)
        }
    }

    private var quitButton: some View {
        Button("Quit") { coordinator.quit() }
            .keyboardShortcut(.cancelAction)
    }
}
