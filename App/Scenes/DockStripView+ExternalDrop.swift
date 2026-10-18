import AppKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers

// DockStripView · external files dragged onto the taskbar: highlight, hover target, drop dispatch.
// Split out of DockStripView.swift as an extension on 2026-09-05; moved only, not changed.
extension DockStripView {
    /// The three lifecycle entry points of the external-drag highlight + the watchdog. `externalDropTarget` is changed only within this group.
    /// dropEntered: a hover session begins → lighting up is allowed.
    func externalDropHoverBegan(_ target: StripDropRouting.Target) {
        externalDropHoverActive = true
        // **Must be captured before the first gap is inserted**, otherwise what gets frozen is the value already widened by the gap, and the ring still holds.
        // This is the single starting point of the whole hover session, so the capture point can only be here.
        // An app the landing surely adds is the exception: its gap grows and re-centres the bar.
        if !appDropMayWidenOnHover(), frozenStripWidth == nil, stripRootScreenRect != .zero {
            frozenStripWidth = stripRootScreenRect.width
        }
        // A gap still waiting for the previous drop's landing now belongs to this session.
        externalDropGhostTimeout?.invalidate()
        externalDropGhostTimeout = nil
        setExternalDropTarget(target)
    }

    /// dropUpdated: updates only while a session is in progress; the orphan dropUpdated (hoverActive=false) the system re-sends after a drop settles/exits is ignored → no flash-back.
    func externalDropHoverMoved(_ target: StripDropRouting.Target) {
        guard externalDropHoverActive else { return }
        setExternalDropTarget(target)
    }

    /// performDrop/dropExited: session ends → clear the highlight immediately, invalidate the watchdog, close the gate (cleared synchronously, goes out the instant the drop settles, no tail left).
    ///
    /// **The yield gap is not cleared here**: `performDrop` also goes through this path, and the real icon only enters the projection after `actionQueue` has
    /// resolved the bundleID — removing the gap in between would show a "gap closes → icon pops out" flash.
    /// The gap is cleared by `keepDroppedApplications` once the real icon is in place, with `armExternalDropGhostTimeout` as a fallback.
    /// - Parameter isLanding: `true` is passed only by `performDrop` — that branch must leave the gap for the landing handoff.
    ///   All other wrap-ups (`dropExited`, shelf-cell toggle changes) always pass `false`: there is no landing to hand off to, and the gap must be removed on the spot,
    ///   otherwise the strip is left with a permanent empty slot that never goes away.
    func externalDropHoverEnded(isLanding: Bool) {
        externalDropHoverActive = false
        externalDropGeneration &+= 1
        externalDropWatchdog?.invalidate()
        externalDropWatchdog = nil
        externalDropTarget = nil
        if isLanding, externalDropGhost != nil {
            // The fallback for the handoff period is installed at this one spot rather than deep inside the landing path: `performDrop` has
            // several early returns after this (target is .none, no provider, URL list empty, not a single app resolved),
            // and none of them reaches the landing. Installed here, any of them self-heals within 1s.
            armExternalDropGhostTimeout()
        } else {
            // No gap to hand off (a plain file was dragged, or no space was yielded to begin with) → collapse immediately, **including unfreezing the strip width**.
            // Without this branch, after a file drop settles the strip width would stay frozen at its value at the moment of hovering.
            clearExternalDropGhost()
        }
    }

    /// Update the yield gap during hover. App drag (`bundleID` non-empty) → live-area gap; drag containing folders →
    /// pinned-folder-area gap (`StripDropRouting.folderGhostIndex`); neither → collapse the gap.
    ///
    /// **The change gate is the reason this function exists**: `dropUpdated` is called every ~50ms, and every write to `@State`
    /// recomputes the whole taskbar (measured: "46 whole-strip recomputes in a 1.2-second drag"). If the anchor did not change, not a single word is written.
    func updateExternalDropGhost(target: StripDropRouting.Target, bundleID: String?,
                                 pinsFolder: Bool, atX x: CGFloat) {
        // **The gate shares its source with the whole-strip highlight, for the same reason**: ~330ms after a successful drop the system re-sends an orphan
        // `dropUpdated`. Without this gate, that one would reopen the gap that was just collapsed at landing, and also invalidate
        // the fallback Timer along the way — leaving a permanent empty slot on the strip (2026-09-08 owner measurement: after dragging "Find My" onto the strip
        // there was an extra slot on the right, which stayed even after "Find My" was removed). After the session ends the gap must neither be reopened nor must it wipe out
        // the gap that is mid-handoff, so this returns directly rather than clearing.
        guard externalDropHoverActive else { return }
        guard let bundleID else {
            let current = externalDropGhost.flatMap { $0.zone == .folder ? $0.insertIndex : nil }
            let index = StripDropRouting.folderGhostIndex(current: current, target: target,
                                                          pinsFolder: pinsFolder)
            setExternalDropGhost(index.map { StripDropGhost(zone: .folder, insertIndex: $0) })
            return
        }
        // The drop-target decision and drawer promotion share one implementation (`StripBlockLanding`). The gap does not report card frames, so `chipFrames`
        // holds only real cards — but their **positions** have already been pushed apart by the gap, so the decision result must be folded into an insertion index to be stable
        // (see `StripDropGhost` for the reason). The display order is sorted by the frames' left edges, the same source as the render order.
        let orderedLiveIDs = chipFrames.sorted { $0.value.minX < $1.value.minX }.map(\.key)
        let target = blockTarget(atX: x, excluding: [])
        let index = StripDropRouting.ghostInsertionIndex(orderedIDs: orderedLiveIDs,
                                                         targetID: target?.id,
                                                         after: target?.after ?? false)
        setExternalDropGhost(StripDropGhost(zone: .live(bundleID: bundleID), insertIndex: index))
    }

    /// The open make-way gap if it is an app's (`.live` zone); a folder's gap is `nil` here.
    var appDropGhost: StripDropGhost? {
        guard let ghost = externalDropGhost, case .live = ghost.zone else { return nil }
        return ghost
    }

    /// Whether this drag is an app the landing will surely add as a new launcher card, so the bar
    /// may grow and re-centre while it hovers (`StripDropRouting.appDropMayWidenOnHover`).
    func appDropMayWidenOnHover() -> Bool {
        guard let bundleID = StripFileDropDelegate.DragPasteboardInspector.applicationBundleID() else {
            return false
        }
        return StripDropRouting.appDropMayWidenOnHover(
            isRunning: runningApplicationStore.isRunning(bundleID),
            isMessaging: messagingStore.contains(bundleID),
            isFinder: FinderTaskbarPolicy.isFinder(bundleID),
            hasEntryOnStrip: !freshProjection().liveEntryIDs(bundleID: bundleID).isEmpty
        )
    }

    /// `.onChange(of: externalDropGhost)`. The box holds what the last body rendered, so it is
    /// compared before it is overwritten.
    func appDropGhostDidChange() {
        let previous = frames.renderedAppGhost
        let current = appDropGhost
        frames.renderedAppGhost = current
        if (previous == nil) != (current == nil) { onAppGapPresenceChange() }
        // The hand-over just ended. The landed card does not necessarily move any geometry (a card
        // re-dropped in place, a bar at its width limit) and a resting pointer is never re-polled,
        // so re-resolve explicitly once SwiftUI has laid out the new card.
        if previous != nil, current == nil, !externalDropHoverActive {
            DispatchQueue.main.async {
                refreshHoveredEntry(frames: stripHoverFrames, origin: stripRootScreenRect)
            }
        }
    }

    static var entryTransition: AnyTransition {
        .scale(scale: 0.88).combined(with: .opacity)
    }

    /// A card an app drop just added enters with no transition of its own: it takes the gap's slot
    /// in the same update, and `DroppedAppLandingGrow` grows its artwork inside the frame readers.
    static var droppedAppLandingTransition: AnyTransition {
        .asymmetric(insertion: .identity, removal: entryTransition)
    }

    /// The change gate. Closing keeps the frozen width: the hover session is still running, and
    /// unfreezing mid-session re-centres the bar under the pointer (see `frozenStripWidth`).
    private func setExternalDropGhost(_ next: StripDropGhost?) {
        guard next != externalDropGhost else { return }
        externalDropGhostTimeout?.invalidate()
        externalDropGhostTimeout = nil
        externalDropGhost = next
    }

    /// After landing, give the gap a bounded fallback: when the real icon should have entered the projection but did not (bad bundle / canKeep fails /
    /// resolution failed), the gap must also go away by itself.
    func armExternalDropGhostTimeout() {
        guard externalDropGhost != nil else { return }
        externalDropGhostTimeout?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: false) { _ in
            clearExternalDropGhost()
        }
        RunLoop.main.add(timer, forMode: .common)
        externalDropGhostTimeout = timer
    }

    /// Unfreeze the strip width at the same time the gap is removed — the two share a lifetime: the landing branch waits until the real icon is in the projection before unfreezing,
    /// so the strip grows to its final length in one clean step instead of first snapping back to the old width and then lengthening.
    func clearExternalDropGhost() {
        externalDropGhostTimeout?.invalidate()
        externalDropGhostTimeout = nil
        externalDropGhost = nil
        frozenStripWidth = nil
    }

    /// Set the drop target + reset the drag-end watchdog. `dropUpdated` arrives every ~50ms during hover and keeps pushing the 0.35s Timer back
    /// → neither moving nor stationary hovering will clear it by mistake; once the drag ends without a wrap-up callback (dropUpdated stops), the Timer fires and clears the leftover highlight.
    /// Clear only if the generation still matches, to avoid an already-queued old Timer wrongly clearing a new drag. Touches only `externalDropTarget`, not the drawer unstash highlight.
    func setExternalDropTarget(_ target: StripDropRouting.Target) {
        externalDropTarget = target
        externalDropGeneration &+= 1
        externalDropWatchdog?.invalidate()
        let gen = externalDropGeneration
        let timer = Timer(timeInterval: 0.35, repeats: false) { _ in
            guard externalDropGeneration == gen else { return }
            externalDropHoverActive = false
            externalDropTarget = nil
            externalDropWatchdog = nil
            // This is the path where "the drag ended but not a single wrap-up callback was given". The session is already dead,
            // so the gap and the frozen strip width must both go away with it, otherwise the strip stays stuck at its hover-time width.
            clearExternalDropGhost()
        }
        RunLoop.main.add(timer, forMode: .common)
        externalDropWatchdog = timer
    }

    /// External drop lands (the DropDelegate gathers the URLs asynchronously, then calls back on the main thread).
    /// The shelf accepts everything; a hit on a chip moves into it; gap/tail pinning accepts directories only.
    ///
    /// **`urls` never contains an app bundle** — `StripFileDropDelegate` has already routed them to
    /// `handleExternalApplicationDrop`, and `.keepApp` never reaches here either.
    func handleExternalDrop(_ target: StripDropRouting.Target, urls: [URL]) {
        switch target {
        case .trash:
            let files = urls.filter { !StripFileDropDelegate.DragPasteboardInspector.isApplication($0) }
            trashStore.trash(files)
        case .stash:
            shelfStore.stash(paths: urls.map(\.path))
        case .moveInto(let path):
            // The second gate guards this branch too: this is a real file move (same-volume move, cross-volume copy), and letting an
            // app slip in would move it out of "Applications". The routing gate is in `StripFileDropDelegate`.
            let files = urls.filter { !StripFileDropDelegate.DragPasteboardInspector.isApplication($0) }
            guard !files.isEmpty else { break }
            onMoveExternalFiles(files, path)
        case .pin(let insertIndex):
            var index = insertIndex
            for url in urls where isPinnableDirectory(url) {
                pinnedFolderStore.insert(url.path, at: index)
                index += 1
            }
            // The gap leaves in the same update that brings the chips in, so the neighbours do not
            // move. An app's gap (mixed drag) is not ours to close — `keepDroppedApplications` does —
            // and neither is the gap of a drag that began hovering before this commit arrived.
            if externalDropGhost?.zone == .folder, !externalDropHoverActive { clearExternalDropGhost() }
        case .keepApp, .none:
            break
        }
    }

    /// Dragging an app from Finder onto the taskbar: check "Keep in Dock" + land at the cursor position (owner 2026-09-07).
    /// Semantics parallel "dragging into the drawer also checks keep along the way" (`Docs/27`): it only handles in, not out, and re-checks on every drag-in,
    /// so dragging an already-kept app again = moving it to a new position, not an error.
    /// An app placed in the drawer (hidden ones included) is moved out first, as when its drawer cell
    /// is dragged onto the bar: a kept app shows only in the drawer, so the drop would add nothing here.
    ///
    /// - Parameter x: the drop x ("strip" space); the landing decision and drawer promotion share `StripBlockLanding`.
    func handleExternalApplicationDrop(_ urls: [URL], atX x: CGFloat) {
        let paths = urls.map(\.path)
        // Reading Info.plist is disk I/O: iron rule — user actions go through `actionQueue`, using neither `Task.detached`
        // nor occupying the Swift cooperative pool (where AppTracker's blocking AX reads run).
        AppRuntime.actionQueue.async {
            let bundleIDs = paths.compactMap { path in
                Bundle(url: URL(fileURLWithPath: path))?.bundleIdentifier
            }
            DispatchQueue.main.async {
                // Bad bundle / no Info.plist → silently ignore, but the gap must be collapsed immediately (before the fallback Timer).
                guard !bundleIDs.isEmpty else { return clearExternalDropGhost() }
                keepDroppedApplications(bundleIDs, atX: x)
            }
        }
    }

    /// Check keep one by one + land. The second and later apps land to the right of the previous one, keeping the dragged-in order.
    private func keepDroppedApplications(_ bundleIDs: [String], atX x: CGFloat) {
        // The gap is removed only on the last statement — the drop target was computed using it as the anchor, and if removed too early `blockTarget` would count
        // the width it yielded back in, and the icon would land next door.
        defer { clearExternalDropGhost() }
        var previousAnchor: (id: String, after: Bool)?
        var addedIDs = Set<String>()
        defer { markLandingEntries(addedIDs) }
        for bundleID in bundleIDs where keptAppStore.canKeep(bundleID) {
            // Drop target: when dragging a card that already exists, exclude itself, otherwise the whole block anchors on itself and stays in place.
            let ownIDs = Set(freshProjection().liveEntryIDs(bundleID: bundleID))
            let target = previousAnchor ?? blockTarget(atX: x, excluding: ownIDs)
            stripOrderStore.stageExternalBlock(bundleID: bundleID,
                                               relativeTo: target?.id,
                                               after: target?.after ?? false)
            appMembershipController.moveOutOfDrawer(bundleID)
            appMembershipController.setKept(bundleID, enabled: true)
            // **Synchronously** run a sync once to consume the drop-target block just staged. Cannot wait for `onChange(of: keptAppStore.bundleIDs)`:
            // when that one runs is uncertain, and committing first would lose the staged block (the icon lands at the end), while not committing would make every later
            // sync move this block again, pushing back the user's later manual reorder.
            reconcileLiveOrder(freshProjection())
            stripOrderStore.commitExternalBlock()
            // Dragging several apps at once: the next one lands to the right of this one, keeping the dragged-in order. The anchor is taken from the projection after landing
            // (a running app has no `app-<bid>` placeholder card, only window cards, and forcing a placeholder id would anchor to a chip that does not exist).
            let landedIDs = freshProjection().liveEntryIDs(bundleID: bundleID)
            // Only cards that were not on this strip get the grow-in; a re-dropped one slides over.
            addedIDs.formUnion(Set(landedIDs).subtracting(ownIDs))
            let landed = landedIDs.last
            previousAnchor = (landed ?? "app-\(bundleID)", true)
        }
    }

    /// Marks freshly landed cards for `droppedAppLandingTransition`, in the same turn as the gap
    /// clears, and unmarks only these once the entrance is over (a later drop keeps its own marks).
    private func markLandingEntries(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        landingEntryIDs.formUnion(ids)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            landingEntryIDs.subtract(ids)
        }
    }

    /// Whether it can be pinned as a folder cell. **An app bundle is a directory in the file system**, so checking only `isDirectoryKey`
    /// would pin the app as a cell that expands the internal structure of the `.app` — a real bug before 2026-09-07.
    /// The routing gate is in `StripFileDropDelegate`; this is the second: `.moveInto` is a real file move
    /// (same-volume move, cross-volume copy), and once an app slips in it would move the user's app out of "Applications".
    private func isPinnableDirectory(_ url: URL) -> Bool {
        guard !StripFileDropDelegate.DragPasteboardInspector.isApplication(url) else { return false }
        return (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? url.hasDirectoryPath
    }
}
