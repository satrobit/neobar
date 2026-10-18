import CoreGraphics
import Foundation

/// Decides who gets the foreground before minimizing the foreground window (2026-08-23).
///
/// Rule (decided by the owner 2026-08-02, landed 2026-08-23): **whoever is underneath the target is next in line, including windows of the same app.**
/// Scan down the CG on-screen z-order from just after the target; the first window **that is in the strip snapshot** is the answer:
/// - same pid → `.siblingTakesOver`: do nothing, since AppKit's native promotion for a foreground App is exactly that;
/// - different pid → `.switchTo`: hand the foreground to that App before minimizing; B is no longer the foreground App, so AppKit won't promote B2.
///
/// Only snapshot members count, **the CG title is not read**: `kCGWindowName` needs the screen recording permission, which the product never requests; the original implementation relied on it for
/// the guard "an untitled invisible window can't be a handoff target", and on installed builds every candidate was blocked and the handoff never took effect (measured 2026-08-23).
/// Snapshot membership is a stronger guard: windows not adopted by the strip (Feishu's top-hugging invisible bar and the like) are simply not in the snapshot.
enum MinimizeHandoffTarget {
    struct ZOrderedWindow: Equatable {
        let pid: Int32
        let cgWindowID: CGWindowID
    }

    /// Both "has a successor" branches carry the successor window's snapshot identity (2026-08-26): the successor becomes the focus right away,
    /// but the snapshot takes 0.5–1s to catch up; during that window, clicking the successor's card gets misjudged as "not the focus" and planned as an empty
    /// activate (owner: "after collapsing window 1, quickly clicking window 2 can't collapse it"). The identity is handed to the optimistic layer to write an .active prediction.
    enum Verdict: Equatable {
        case switchTo(pid: Int32, cgWindowID: CGWindowID, windowID: WindowID)
        case siblingTakesOver(windowID: WindowID)
        case none
    }

    /// - Parameters:
    /// - zOrder: CG on-screen layer-0 windows, front→back, with its own process already excluded.
    /// - target: the window record about to be minimized.
    /// - snapshot: the current strip snapshot.
    static func select(zOrder: [ZOrderedWindow], target: WindowRecord, snapshot: DockSnapshot) -> Verdict {
        var start = 0
        if let targetWID = target.cgWindowID,
           let index = zOrder.firstIndex(where: { $0.cgWindowID == targetWID }) {
            start = index + 1
        }
        var recordsByWID: [CGWindowID: WindowRecord] = [:]
        for record in snapshot.windows.values {
            guard let wid = record.cgWindowID, record.id != target.id else { continue }
            recordsByWID[wid] = record
        }
        for entry in zOrder[start...] {
            guard let record = recordsByWID[entry.cgWindowID] else { continue }
            guard record.status != .minimized, record.status != .hidden else { continue }
            if record.pid == target.pid {
                return .siblingTakesOver(windowID: record.id)
            }
            return .switchTo(pid: entry.pid, cgWindowID: entry.cgWindowID, windowID: record.id)
        }
        return .none
    }
}
