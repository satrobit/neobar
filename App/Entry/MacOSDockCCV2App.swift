import SwiftUI

@main
struct MacOSDockCCV2App: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        // The earlier the better: any app we launch afterwards inherits the environment as of this moment. See `ProcessEnvironmentScrub` for the rationale.
        ProcessEnvironmentScrub.apply()
    }

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    appDelegate.openSettings(nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
