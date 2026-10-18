import AppKit
import Foundation

/// The SkyLight private-space host for all our panels (taskbar / glass backing / capsule, plus drawer / popup / name bubble / drag carrier).
///
/// **Every window that can overlap the taskbar must be pinned in.** A window left in the desktop space is composited **below** this
/// space regardless of `level`: a drag carrier looks semi-transparent as soon as it overlaps the glass backing, and the bottom row of the drawer looks dark when it overlaps the shadow edge of the capsule window
/// (owner 2026-09-03, confirmed by `DOCK_OVERLAY_SPACE=0` A/B). The first version on 2026-09-02 pinned only the three resident panels.
///
/// Why it is needed: during a swipe between desktops, WindowServer bakes `.canJoinAllSpaces` resident panels into the transition
/// snapshots of both desktops; the Liquid Glass backing cannot get the picture behind it in the snapshot and degrades into a solid dark gray (the frosted-glass path turns white),
/// recovering only once the swipe settles (owner 2026-09-02 screenshot + `scratch/space_transition_lab` measurements). The system Dock is unaffected
/// because it is not in any desktop space at all. Move the panels into a space we create ourselves (`SLSSpaceCreate` →
/// `SLSSpaceSetAbsoluteLevel 0` → `SLSShowSpaces` → `SLSSpaceAddWindowsAndRemoveFromSpaces`),
/// and the panels stay rock-steady just like the Dock, with the material updating live to follow the content beneath.
///
/// Boundaries verified by measurement (`scratch/overlay_space_lab`, macOS 26.5.2, two displays):
/// - Click / enter events arrive as usual, both before and after switching desktops;
/// - The two displays can **share one** space; each panel is shown only on the display its frame is on;
/// - `orderOut` → `orderFrontRegardless` **does not** drop membership, and neither does switching desktops — so pinning once
///   after the panel is first shown is enough, and the re-pin on the show/hide path is just a cheap read-back;
/// - The private space **cannot be read** under the `SLSCopySpacesForWindows` mask `0x7` (the issue #19 fix uses that mask,
///   and would treat pinned panels as "in no desktop" and repair them over and over), so the read-back must use `0xF`; the return values of `SLSShowSpaces` /
///   `SLSSpaceAddWindowsAndRemoveFromSpaces` are not error codes (measured to return large integers), so only the read-back counts.
///
/// If any symbol cannot be obtained (old system / renamed by Apple) → `make()` returns nil and the panels keep the old `.canJoinAllSpaces` behavior,
/// with the issue #19 fix unchanged. Switch: `DOCK_OVERLAY_SPACE=0`.
@MainActor
final class OverlaySpaceHost {
    static let isEnabled = DebugSwitch.overlaySpace.isEnabled(in: ProcessInfo.processInfo.environment)

    private typealias MainConnectionIDFn = @convention(c) () -> Int32
    private typealias SpaceCreateFn = @convention(c) (Int32, Int32, CFDictionary?) -> UInt64
    private typealias SpaceDestroyFn = @convention(c) (Int32, UInt64) -> Int32
    private typealias SpaceSetAbsoluteLevelFn = @convention(c) (Int32, UInt64, Int32) -> Int32
    private typealias SpaceListFn = @convention(c) (Int32, CFArray) -> Int32
    private typealias SpaceAddWindowsFn = @convention(c) (Int32, UInt64, CFArray, Int32) -> Int32
    private typealias CopySpacesForWindowsFn = @convention(c) (Int32, Int32, CFArray) -> CFArray?

    private struct Symbols {
        let cid: Int32
        let create: SpaceCreateFn
        let destroy: SpaceDestroyFn
        let setAbsoluteLevel: SpaceSetAbsoluteLevelFn
        let show: SpaceListFn
        let hide: SpaceListFn
        let addWindows: SpaceAddWindowsFn
        let copySpaces: CopySpacesForWindowsFn
    }

    private static let symbols: Symbols? = {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
            RTLD_LAZY
        ) else { return nil }
        func load<T>(_ name: String, as: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: T.self) }
        }
        guard let cidFn = load("SLSMainConnectionID", as: MainConnectionIDFn.self),
              let create = load("SLSSpaceCreate", as: SpaceCreateFn.self),
              let destroy = load("SLSSpaceDestroy", as: SpaceDestroyFn.self),
              let setLevel = load("SLSSpaceSetAbsoluteLevel", as: SpaceSetAbsoluteLevelFn.self),
              let show = load("SLSShowSpaces", as: SpaceListFn.self),
              let hide = load("SLSHideSpaces", as: SpaceListFn.self),
              let addWindows = load("SLSSpaceAddWindowsAndRemoveFromSpaces", as: SpaceAddWindowsFn.self),
              let copySpaces = load("SLSCopySpacesForWindows", as: CopySpacesForWindowsFn.self)
        else { return nil }
        return Symbols(cid: cidFn(), create: create, destroy: destroy, setAbsoluteLevel: setLevel,
                       show: show, hide: hide, addWindows: addWindows, copySpaces: copySpaces)
    }()

    /// Returns nil when the switch is off or a symbol is missing: the caller takes the old behavior as "no host".
    static func make() -> OverlaySpaceHost? {
        guard isEnabled, symbols != nil else { return nil }
        return OverlaySpaceHost()
    }

    private init() {}

    private var spaceID: UInt64?

    /// Moves windows into the private space. Windows already inside are skipped; returns "all targets are confirmed in the space after read-back".
    /// The space is created only on the first call, to avoid a space appearing out of nowhere when a host exists but is never used.
    @discardableResult
    func pin(windowNumbers: [Int]) -> Bool {
        guard let symbols = Self.symbols else { return false }
        let targets = windowNumbers.filter { $0 > 0 }
        guard !targets.isEmpty, let sid = ensureSpace(symbols) else { return false }
        let missing = targets.filter { !isPinned(windowNumber: $0) }
        guard !missing.isEmpty else { return true }
        // selector 0x7: remove from all the spaces the window originally belonged to (otherwise it also stays on each desktop and still gets baked into the snapshot).
        _ = symbols.addWindows(symbols.cid, sid, missing.map { NSNumber(value: $0) } as CFArray, 0x7)
        return missing.allSatisfy { isPinned(windowNumber: $0) }
    }

    /// Read-back: whether this window is now in our private space. Unreadable / space not created → false.
    func isPinned(windowNumber: Int) -> Bool {
        guard let sid = spaceID, windowNumber > 0, let symbols = Self.symbols,
              let raw = symbols.copySpaces(
                symbols.cid,
                0xF,
                [NSNumber(value: windowNumber)] as CFArray
              ) as? [NSNumber]
        else { return false }
        return raw.contains { $0.uint64Value == sid }
    }

    /// Reclaim before exit. WindowServer reclaims it when the process dies anyway; this just avoids leaving a garbage space behind.
    func tearDown() {
        guard let sid = spaceID, let symbols = Self.symbols else { return }
        _ = symbols.hide(symbols.cid, [NSNumber(value: sid)] as CFArray)
        _ = symbols.destroy(symbols.cid, sid)
        spaceID = nil
    }

    private func ensureSpace(_ symbols: Symbols) -> UInt64? {
        if let spaceID { return spaceID }
        // type 1: the space created this way was measured to report `SLSSpaceGetType` 3 (system-level), and windows in it do not take part in desktop transitions.
        let sid = symbols.create(symbols.cid, 1, nil)
        guard sid != 0 else { return nil }
        // absolute level 0: same level as the desktop; the window's own level (.floating) decides that it sits above normal windows.
        _ = symbols.setAbsoluteLevel(symbols.cid, sid, 0)
        _ = symbols.show(symbols.cid, [NSNumber(value: sid)] as CFArray)
        spaceID = sid
        return sid
    }
}
