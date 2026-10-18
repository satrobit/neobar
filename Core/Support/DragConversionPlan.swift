import Foundation

/// Drag source: determines three branches: the drop zone, the drop action, and the carrier drawing.
/// `.folder` = pinned-folder chip (in-zone reorder + drag out to remove + drag back to the window area to open), **fully isolated from the strip/drawer stashing
/// semantics**: it doesn't enter drawerStore, doesn't enter the drop zone (canExternalDrop=false), and doesn't go through convert/revert;
/// DockStripView only provides drop-target geometry, and the final commit is triggered by the mouseUp / polling fallback path of `endDrag()`.
/// `.messaging` = messaging-area app chip (in-zone reorder + drag into the drawer to stash): its drop zone is the same as `.strip`'s
/// (capsule + the open drawer body); the rest of the taskbar is not a drop target for it.
/// Defined in this file (not DragController.swift): the test target works by "compiling local source files", so the pure decision layer
/// must compile without DragController's AppKit dependency.
enum DragSource { case strip, drawer, folder, messaging }

/// Behavior mode when a drawer icon is dragged to the taskbar (pure decision; DockStripView feeds the facts).
enum DrawerDragOutMode: Equatable {
    case reject             // Not-running messaging app -> not accepted (stays in the drawer)
    case releaseToMessaging // Running messaging app -> only temporarily released back to the messaging area once inside the messaging-area range
    case unstash            // Has a real window -> the existing precise placement path
    case keepPlacement      // app fallback / kept placeholder -> app-level placement, never modifies kept
}

/// Pure decision layer for cross-panel drag conversion (Codex review 2026-07-11 P2-6). Geometry, stores, and panels don't come in here --
/// the caller feeds in the current facts and this only answers "what should be done"; execution and rollback of the conversion live in `DragController`.
enum DragConversionPlan {

    /// Drawer drag-out mode decision. The messaging check must come **before** the real-window check -- a running messaging app has a main window,
    /// otherwise it would wrongly enter unstash.
    ///
    /// **The messaging-member branch decides "after release, will it really appear in the messaging area"**, and the criterion must come from the same source as the messaging area's
    /// own visibility rule (`AppMembershipProjection.visibleMessagingIDs` = running ∪ already kept).
    /// This used to decide on `isInSnapshot` (the window inventory), which is **another source of truth**: when WeChat's main window is closed,
    /// the process is running, the icon has a running dot, and the messaging area still shows it, yet the window inventory doesn't contain it -- hence
    /// "the running dot is clearly lit but it can never be dragged back to the messaging area" (owner measured 2026-08-20; log evidence
    /// `mode=reject inSnapshot=False running=True`).
    static func drawerDragOutMode(bundleID: String,
                                  isMessagingMember: Bool,
                                  isInSnapshot: Bool,
                                  isRunningProcess: Bool,
                                  hasRealWindow: Bool,
                                  isKept: Bool) -> DrawerDragOutMode {
        guard !bundleID.isEmpty else { return .reject }
        if isMessagingMember {
            // Reject only when neither holds -- in that case releasing it would indeed make it vanish into thin air.
            return (isRunningProcess || isKept) ? .releaseToMessaging : .reject
        }
        if hasRealWindow { return .unstash }
        // app-* fallback while running, or a kept placeholder while stopped.
        return isInSnapshot || isKept ? .keepPlacement : .reject
    }

    /// Finishing action on `endDrag` release (`.messaging` / `.drawer` sources; `.strip`/`.folder` don't go through here).
    enum EndAction: Equatable {
        case none
        /// A messaging-area chip lands in the drop zone (capsule/open drawer) -> drawer.add stashes it.
        case stashMessagingChip
        /// A drawer icon has been promoted into the taskbar -> notify the ordering layer to commit.
        case commitDrawerToStrip
        /// A drawer icon that was not promoted, lands on the taskbar, and is not a messaging member -> degrade to removal (drawer.remove).
        case fallbackUnstash
    }

    /// Release decision. A messaging member's drawer icon **never** takes the degraded unstash: its only path back to the taskbar is
    /// the temporary release into the messaging-area range (drawerToMessaging); releasing anywhere else always leaves it in the drawer (review P1-3).
    /// For a payload already released back to the messaging area the source is `.messaging`: not in the drop zone -> `.none` (drawer.remove has already happened,
    /// so release settles it); in the drop zone -> stash (equivalent to rollback, drawer.add is idempotent).
    static func endAction(source: DragSource,
                          isConvertedToStrip: Bool,
                          isOverDropZone: Bool,
                          isMessagingMember: Bool) -> EndAction {
        switch source {
        case .strip, .folder:
            return .none
        case .messaging:
            return isOverDropZone ? .stashMessagingChip : .none
        case .drawer:
            if isConvertedToStrip { return .commitDrawerToStrip }
            guard isOverDropZone, !isMessagingMember else { return .none }
            return .fallbackUnstash
        }
    }

    /// Whether to turn on "Keep in Dock" for this app after the drag settles (owner decided 2026-08-06).
    ///
    /// **Handles entry only, not exit**: it is turned on only when this drag brings the app into the drawer from outside; dragging from the drawer back to
    /// the taskbar never turns it off (the user may have ticked keep themselves, and turning it off in reverse would erase a setting unrelated to the drawer).
    ///
    /// **It is re-enabled on every drag-in**, not seeded just once for life. If the user manually unticks it and drags the app in again, it
    /// gets ticked again -- this is the semantics the owner decided: dragging into the drawer is an explicit, deliberate action, and each time counts as re-expressing
    /// "I want it to live here long-term". **Don't draw an analogy with `AppMembershipController.markMessaging`**:
    /// that one implements a true one-time seeding via the first return value of `MessagingAppStore.mark`, whereas here we deliberately
    /// don't introduce an equivalent "history archive of who was auto-ticked" (adding a permanent piece of data for a corner case isn't worth it).
    /// `DragControllerConversionTests` has a case that specifically locks this behavior; don't "fix" it as a bug.
    ///
    /// Called only after `endDrag()` settles. The conversion preview (`convert*`) and rollback (`revert*` /
    /// `cancelDrag`) phases **never touch kept**, so that symmetric placement transaction is unchanged.
    ///
    /// - Parameter originSource: The source **at drag start**. Must not pass `draggingPayload.source` --
    ///   the conversion into the drawer body flips it to `.drawer`, which would collide with in-drawer reordering.
    /// - Parameter endedInDrawer: Whether it is actually still in the drawer after settling (read from `DrawerStore`).
    static func enablesKeptOnDrop(originSource: DragSource, endedInDrawer: Bool) -> Bool {
        guard endedInDrawer else { return false }
        return originSource == .strip || originSource == .messaging
    }
}
