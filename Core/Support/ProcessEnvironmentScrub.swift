import Foundation

/// Clear "terminal-flavored" environment variables at process entry (2026-08-23).
///
/// When the strip launches other apps, the system passes our own environment to them as is. A development build started from a terminal (Xcode / Claude Code / Ghostty)
/// carries `LANG=en_US.UTF-8`, and the WeChat it then launches opens with an English UI, with the main window title becoming
/// `Weixin`, so the "title == app name" main-window identification stops working. That is how "WeChat launched from NeoBar is in English" on the owner's machine came about
/// (measured: that WeChat process carried the whole set of terminal variables, while Telegram launched from the Dock had none of them).
/// A taskbar should launch apps **like the Dock does**, no matter how it was launched itself.
///
/// Normal users launch from Launchpad / login items, where these variables don't exist in the first place, so clearing has zero impact.
/// Our own `DOCK_*` switches are not in the list.
enum ProcessEnvironmentScrub {
    static let exactKeys: Set<String> = [
        "LANG", "COLORTERM", "SHELL", "SHLVL",
        "TERM", "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "TERM_SESSION_ID",
    ]
    static let prefixes: [String] = ["LC_", "CLAUDE_", "GHOSTTY_"]

    /// Pure decision: given the environment, which keys should be cleared. Sorting is only for stable output.
    static func keysToUnset(in environment: [String: String]) -> [String] {
        environment.keys
            .filter { key in exactKeys.contains(key) || prefixes.contains(where: { key.hasPrefix($0) }) }
            .sorted()
    }

    /// Call once at the entry, the earlier the better: any app we launch afterwards inherits the environment as of this moment.
    static func apply(environment: [String: String] = ProcessInfo.processInfo.environment) {
        for key in keysToUnset(in: environment) {
            unsetenv(key)
        }
    }
}
