import Foundation

/// **Admission capability** of the messaging zone, a pure decision layer: which apps currently have a recognizable main window.
///
/// The messaging zone's model is "one icon = the app's main-window card", so "can the main window be recognized" is itself this zone's
/// capability test. `MessagingAppStore.autoRegister` uses it as the threshold for auto-marking: looking like a messaging app is not enough,
/// it must also **be correctly representable in this zone**.
///
/// This threshold blocks apps that are "never recognizable": Apple Messages is a Mac Catalyst app whose window title is a
/// UIScene session number, never equal to the app name; terminals such as Ghostty have the command name as the window title, yet get wrongly marked because the App Store
/// category is "Social Networking". Once in the messaging zone they would only get a launcher icon that "can only summon, not collapse",
/// and since their windows are not absorbed, they would also be shown twice.
///
/// **The caller must use it only at first registration**: this decision reflects whether recognition works "right now", not a stable property. When WeChat's main window
/// is closed only the "Notes" window remains, which likewise cannot be recognized at that moment; rechecking every round would kick it out of the messaging zone and have it jump back in when reopened.
/// Once passed, it is permanently on the list and never rechecked.
enum MessagingZoneAdmission {
    /// A window read model from the snapshot (taking only the three fields the decision needs, with no dependency on UI-layer types).
    struct WindowFact: Equatable {
        let bundleID: String
        let title: String
        let isAppLevelFallback: Bool

        init(bundleID: String, title: String, isAppLevelFallback: Bool) {
            self.bundleID = bundleID
            self.title = title
            self.isAppLevelFallback = isAppLevelFallback
        }
    }

    /// - Parameter titleMatchesAppName: `(title, bundleID) -> Bool`, injected as a closure, leaving the impure parts (querying
    ///   `NSRunningApplication` / reading disk plists / static caches) on the caller side.
    /// - Returns: the bundleIDs for which a real window currently exists whose "title equals the app name".
    static func mainWindowIdentifiableBundleIDs(
        windows: [WindowFact],
        titleMatchesAppName: (String, String) -> Bool
    ) -> Set<String> {
        var result: Set<String> = []
        for window in windows {
            // An app-* fallback item is not a real window and cannot be used to prove the main window is recognizable.
            guard !window.isAppLevelFallback, !window.bundleID.isEmpty else { continue }
            guard !result.contains(window.bundleID) else { continue }
            if titleMatchesAppName(window.title, window.bundleID) {
                result.insert(window.bundleID)
            }
        }
        return result
    }
}
