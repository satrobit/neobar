import ApplicationServices
import CoreGraphics
import Foundation

/// A side-channel cache of `pid + cgWindowID -> AXUIElement`.
///
/// **What it solves** (the owner pointed out on 2026-08-11 that "clicking a minimized window back is slowest"): `AppTracker` reads the full `AXWindows` in the background every 0.5 seconds and
/// on every AX event, so it **already holds** each window's AX element; but the action
/// path re-asks the target app for the handle on every click: the fast path caps at 100ms, and if it fails it turns to a 500ms-timeout
/// full enumeration. Minimized windows especially hit the slow path (they are neither focused nor the main window, so the fast path must
/// go all the way to the full `AXWindows` step), and an app with minimized windows is often napping, which makes the AX query itself slow.
///
/// **Why it is not put into `DockSnapshot` / `WindowRecord`**: the equality of those two types is the gate for task-strip rendering
/// (AGENTS "Taskbar Interaction Performance", "`DockSnapshot` publications are equality-gated").
/// Putting an `AXUIElement` that changes every round into them would break the equality gate and turn the whole task strip into a re-render every 0.5 seconds,
/// the very illness `4120119` just fixed. So it goes through a side channel: not a single snapshot field needs to change.
///
/// **The invalidation rules deliberately match the seat-release rules** (AGENTS "Taskbar Trust And Placement"):
/// - Window destroyed (destroy notification) -> delete that entry
/// - Process gone / app entry deleted -> delete all entries of that pid
/// - Each reconcile round intersects with the full CG list -> delete cgIDs absent from CG
///
/// **Never delete just because "it can no longer be read from AX"**: Safari-style windows vanish entirely from `AXWindows` once minimized
/// (the premise of AGENTS's ghost-seat self-healing rule), and that is exactly the moment this cache matters most: the element stored in the cache
/// before minimizing still points at the same window, and `setMinimized(false)` can use it.
final class AXElementCache: @unchecked Sendable {
    static let shared = AXElementCache()

    /// `DOCK_AX_ELEMENT_CACHE=0` turns off the fastest tier, returning to the existing two tiers fast / fallback.
    static let isEnabled = DebugSwitch.axElementCache.isEnabled(in: ProcessInfo.processInfo.environment)

    struct Key: Hashable {
        let pid: pid_t
        let cgWindowID: CGWindowID
    }

    private let lock = NSLock()
    private var elements: [Key: AXUIElement] = [:]

    init() {}

    func store(pid: pid_t, cgWindowID: CGWindowID, element: AXUIElement) {
        guard pid > 0, cgWindowID != 0 else { return }
        lock.lock()
        elements[Key(pid: pid, cgWindowID: cgWindowID)] = element
        lock.unlock()
    }

    func element(pid: pid_t, cgWindowID: CGWindowID) -> AXUIElement? {
        guard pid > 0, cgWindowID != 0 else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return elements[Key(pid: pid, cgWindowID: cgWindowID)]
    }

    func remove(pid: pid_t, cgWindowID: CGWindowID) {
        lock.lock()
        elements.removeValue(forKey: Key(pid: pid, cgWindowID: cgWindowID))
        lock.unlock()
    }

    func removeAll(pid: pid_t) {
        lock.lock()
        elements = elements.filter { $0.key.pid != pid }
        lock.unlock()
    }

    /// Intersect with the full CG list: a window no longer in CG has certainly been truly closed, and the cache drops it as well.
    /// This is the gate against cgWindowID reuse, from the same source as the hygiene rule for `formerCgIDs`.
    func retain(pid: pid_t, liveCGWindowIDs: Set<CGWindowID>) {
        lock.lock()
        elements = elements.filter { $0.key.pid != pid || liveCGWindowIDs.contains($0.key.cgWindowID) }
        lock.unlock()
    }

    #if DEBUG
    /// For unit tests: read the current entry count directly.
    var countForTesting: Int {
        lock.lock()
        defer { lock.unlock() }
        return elements.count
    }

    func containsForTesting(pid: pid_t, cgWindowID: CGWindowID) -> Bool {
        element(pid: pid, cgWindowID: cgWindowID) != nil
    }
    #endif
}

/// The cache entries' **retention decision**, factored into a pure function for unit testing: if this rule is written wrongly, it either leaves
/// a stale element pointing at a destroyed window (which might act on the wrong window), or wrongly deletes a window that left AX after minimizing (making the cache pointless).
enum AXElementCacheRetention {
    /// - Parameters:
    ///   - cachedCGWindowIDs: the windows this pid currently has cached
    ///   - liveCGWindowIDs: the CG **full list** (neither the on-screen set nor the AX list)
    /// - Returns: the windows that should be deleted
    static func expired(
        cachedCGWindowIDs: Set<CGWindowID>,
        liveCGWindowIDs: Set<CGWindowID>
    ) -> Set<CGWindowID> {
        cachedCGWindowIDs.subtracting(liveCGWindowIDs)
    }
}
