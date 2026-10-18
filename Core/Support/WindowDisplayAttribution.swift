import CoreGraphics
import Foundation

/// Which screen a window belongs to (the coarse-grained key for multi-screen (4) "each screen shows only its own screen's windows").
///
/// Pure geometry: the screen covering more than half the area; if none exceeds half, the one with the largest overlap; no contact at all / invalid frame / empty screen table -> nil.
/// The criterion reuses `WindowLiftAvoidance.owningContextIndex` (avoidance already assigns cross-screen windows to a screen with the same area method).
/// **It does not fall back to the main screen here**: the inventory layer honestly stores "unknown"; falling back to the main screen is the job of the taskbar projection layer (`StripDisplayFilter`),
/// otherwise, when the main screen is unplugged / changed, the inventory would keep a stale false attribution.
enum WindowDisplayAttribution {
    struct Display: Equatable {
        let uuid: String
        /// Quartz global coordinates (top-left origin, anchored at the screen with the menu bar), the same coordinate system as AX `kAXPosition` / CG `kCGWindowBounds`.
        let cgFrame: CGRect
        /// Usable area after removing the menu bar / system Dock (same coordinate system). Cross-screen window drags (`WindowDisplayMove`) place the window by it;
        /// attribution is still judged by `cgFrame`. Not passed = the whole screen.
        let visibleCGFrame: CGRect

        init(uuid: String, cgFrame: CGRect, visibleCGFrame: CGRect? = nil) {
            self.uuid = uuid
            self.cgFrame = cgFrame
            self.visibleCGFrame = visibleCGFrame ?? cgFrame
        }
    }

    struct Table: Equatable {
        let displays: [Display]
        /// The screen with the menu bar (`NSScreen.screens.first`, **not** `NSScreen.main`).
        let primaryUUID: String?

        static let empty = Table(displays: [], primaryUUID: nil)

        var connectedUUIDs: Set<String> { Set(displays.map(\.uuid)) }
    }

    static func displayUUID(for quartzFrame: CGRect?, table: Table) -> String? {
        guard let frame = quartzFrame,
              let index = WindowLiftAvoidance.owningContextIndex(
                  for: frame,
                  screenCGFrames: table.displays.map(\.cgFrame)
              ) else { return nil }
        return table.displays[index].uuid
    }
}
