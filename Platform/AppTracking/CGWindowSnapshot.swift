import CoreGraphics
import Foundation

struct AppTrackerCGWindowSnapshot: Equatable {
    let allWindowIDs: Set<CGWindowID>
    let onScreenWindowIDs: Set<CGWindowID>
    /// Layer-0 window ids grouped by owner pid (for the shadow tab pool: CG(pid) - the AX-exposed set = order-out background tabs).
    let windowIDsByPID: [pid_t: Set<CGWindowID>]
    /// The AX inventory has no opacity attribute; it is filled in by the same-round CG window id, for use by admission's alpha=0 filter.
    let alphaByWindowID: [CGWindowID: Double]
    /// `kCGWindowBounds` of layer-0 windows (Quartz global coordinates). The 5s tick of multi-screen mode 4 uses it to recompute "which screen" for **all** seats
    /// -- including pids skipped by the skip-read gate and having no AX read. It only does screen attribution and does not replace AX frames.
    let boundsByWindowID: [CGWindowID: CGRect]
    /// Windows below the normal layer (`kCGWindowLayer < 0`): desktop widgets, wallpaper surfaces.
    /// A veto-only set for admission — none of these ids appear in the layer-0 fields above.
    /// Empty on a failed capture, so that round cannot veto anything.
    let belowNormalLayerWindowIDs: Set<CGWindowID>
    /// The CG query itself failed (returned nil). This is different from "there really are no layer-0 windows": any gate that uses this snapshot as a
    /// "nothing changed" criterion (periodic skip-read, rescan gate) must abandon skipping and take the full path when it sees this flag.
    /// Existing consumers do not read it, and downstream behavior on failure is bit-for-bit the same as before.
    let captureFailed: Bool

    init(
        allWindowIDs: Set<CGWindowID>,
        onScreenWindowIDs: Set<CGWindowID>,
        windowIDsByPID: [pid_t: Set<CGWindowID>],
        alphaByWindowID: [CGWindowID: Double],
        boundsByWindowID: [CGWindowID: CGRect] = [:],
        belowNormalLayerWindowIDs: Set<CGWindowID> = [],
        captureFailed: Bool = false
    ) {
        self.allWindowIDs = allWindowIDs
        self.onScreenWindowIDs = onScreenWindowIDs
        self.windowIDsByPID = windowIDsByPID
        self.alphaByWindowID = alphaByWindowID
        self.boundsByWindowID = boundsByWindowID
        self.belowNormalLayerWindowIDs = belowNormalLayerWindowIDs
        self.captureFailed = captureFailed
    }

    static var failed: AppTrackerCGWindowSnapshot {
        AppTrackerCGWindowSnapshot(
            allWindowIDs: [],
            onScreenWindowIDs: [],
            windowIDsByPID: [:],
            alphaByWindowID: [:],
            boundsByWindowID: [:],
            captureFailed: true
        )
    }

    static func capture() -> AppTrackerCGWindowSnapshot {
        guard let windowInfo = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
            return .failed
        }
        return parse(windowInfo)
    }

    static func captureOnScreenWindowIDs() -> Set<CGWindowID> {
        guard let windowInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }
        return layerZeroWindowIDs(in: windowInfo)
    }

    static func parse(_ windowInfo: [[String: Any]]) -> AppTrackerCGWindowSnapshot {
        var allWindowIDs: Set<CGWindowID> = []
        var onScreenWindowIDs: Set<CGWindowID> = []
        var windowIDsByPID: [pid_t: Set<CGWindowID>] = [:]
        var alphaByWindowID: [CGWindowID: Double] = [:]
        var boundsByWindowID: [CGWindowID: CGRect] = [:]
        var belowNormalLayerWindowIDs: Set<CGWindowID> = []

        for info in windowInfo {
            if let layer = info[kCGWindowLayer as String] as? Int, layer < 0 {
                if let number = info[kCGWindowNumber as String] as? Int {
                    belowNormalLayerWindowIDs.insert(CGWindowID(number))
                }
                continue
            }
            guard let windowID = layerZeroWindowID(in: info) else { continue }
            allWindowIDs.insert(windowID)
            if info[kCGWindowIsOnscreen as String] as? Bool == true {
                onScreenWindowIDs.insert(windowID)
            }
            if let ownerPID = info[kCGWindowOwnerPID as String] as? Int {
                windowIDsByPID[pid_t(ownerPID), default: []].insert(windowID)
            }
            if let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue {
                alphaByWindowID[windowID] = alpha
            }
            if let dict = info[kCGWindowBounds as String] as? NSDictionary,
               let rect = CGRect(dictionaryRepresentation: dict) {
                boundsByWindowID[windowID] = rect
            }
        }

        return AppTrackerCGWindowSnapshot(
            allWindowIDs: allWindowIDs,
            onScreenWindowIDs: onScreenWindowIDs,
            windowIDsByPID: windowIDsByPID,
            alphaByWindowID: alphaByWindowID,
            boundsByWindowID: boundsByWindowID,
            belowNormalLayerWindowIDs: belowNormalLayerWindowIDs
        )
    }

    private static func layerZeroWindowIDs(in windowInfo: [[String: Any]]) -> Set<CGWindowID> {
        Set(windowInfo.compactMap(layerZeroWindowID(in:)))
    }

    private static func layerZeroWindowID(in info: [String: Any]) -> CGWindowID? {
        guard let layer = info[kCGWindowLayer as String] as? Int,
              layer == 0,
              let number = info[kCGWindowNumber as String] as? Int else {
            return nil
        }
        return CGWindowID(number)
    }
}
