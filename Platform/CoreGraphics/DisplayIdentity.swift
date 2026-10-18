import AppKit

/// NSScreen -> display UUID (`CGDisplayCreateUUIDFromDisplayID`, EDID-based,
/// stable across plug/unplug, port changes, and sleep/wake). The persistent identity for the task strip's "pin to a screen" uses it;
/// **never remember a screen by its index in the `NSScreen.screens` array**.
/// The logic comes from the same source as `ManagedSpaceLayoutReader.displayUUIDString(for:)` in `FullscreenIntentMonitor.swift`
/// (the details of that file are frozen by rule, and the implementation is deliberately not shared).
enum DisplayIdentity {
    @MainActor
    static func uuidString(for screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber else { return nil }
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(CGDirectDisplayID(number.uint32Value))
        else { return nil }
        return CFUUIDCreateString(nil, uuid.takeRetainedValue()) as String?
    }

    /// Present-screen table: the Quartz frame of each screen whose UUID can be read + the main screen (`NSScreen.screens.first`, the one with the menu bar;
    /// **not** `NSScreen.main`, which follows the key window). Fed to `WindowDisplayAttribution` / `StripDisplayFilter`.
    /// Computed once when screen parameters change (`DisplayTopologyStore`); do not compute it live on a hot path.
    @MainActor
    static func attributionTable() -> WindowDisplayAttribution.Table {
        attributionTable(screens: NSScreen.screens)
    }

    /// Builds the table from screens the caller already sampled, so one topology transaction
    /// never reads `NSScreen.screens` twice.
    @MainActor
    static func attributionTable(screens: [NSScreen]) -> WindowDisplayAttribution.Table {
        let primaryHeight = screens.first?.frame.maxY ?? 0
        var primaryUUID: String?
        let displays: [WindowDisplayAttribution.Display] = screens.enumerated().compactMap { index, screen in
            guard let uuid = uuidString(for: screen) else { return nil }
            if index == 0 { primaryUUID = uuid }
            return WindowDisplayAttribution.Display(
                uuid: uuid,
                cgFrame: WindowLiftAvoidance.quartzFrame(fromAppKit: screen.frame, primaryScreenHeight: primaryHeight),
                visibleCGFrame: WindowLiftAvoidance.quartzFrame(fromAppKit: screen.visibleFrame,
                                                                primaryScreenHeight: primaryHeight)
            )
        }
        return WindowDisplayAttribution.Table(
            displays: displays,
            primaryUUID: primaryUUID
        )
    }

    /// Derives the physical display count, the ordered UUIDs and the attribution table from a
    /// single read.
    @MainActor
    static func topologySnapshot() -> ScreenTopologySnapshot {
        let screens = NSScreen.screens
        let table = attributionTable(screens: screens)
        return ScreenTopologySnapshot(
            physicalDisplayCount: screens.count,
            identifiedDisplayUUIDs: table.displays.map(\.uuid),
            attributionTable: table
        )
    }

    /// Present screens -> (display UUID, de-duplicated display name). A screen whose UUID cannot be read is left out of the list (it cannot be pinned).
    /// **It does system I/O (`localizedName` reads IODisplay); do not compute it live on the menu-popup path**:
    /// callers should cache a copy when screen parameters change (`StatusMenuController` does exactly that).
    @MainActor
    static func connectedScreenOptions() -> [(uuid: String, title: String)] {
        let identified: [(uuid: String, name: String)] = NSScreen.screens.compactMap { screen in
            guard let uuid = uuidString(for: screen) else { return nil }
            return (uuid, screen.localizedName)
        }
        let titles = TaskbarScreenResolution.displayTitles(names: identified.map(\.name))
        return zip(identified, titles).map { ($0.uuid, $1) }
    }
}
