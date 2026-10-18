import AppKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers

// DockStripView · projection building: one body evaluation builds only one StripProjection (performance rule), label dedup, appKey.
// Split out of DockStripView.swift as an extension on 2026-09-05, moved only, not changed.
extension DockStripView {
    /// Pinned messaging zone (leftmost, in store order) + live window zone, in **natural**
    /// snapshot order. Messaging apps show only while running (quit → chip gone; the future
    /// drawer pending-launch area takes over the not-running role). Drawer membership hides a messaging
    /// app from the strip without clearing its messaging flag.
    ///
    /// Plan B: each messaging app pins exactly ONE app-level chip. Its main window
    /// (title matches the app name) is absorbed into that chip; pop-out windows
    /// (chat windows etc.) flow through the live zone as normal window chips so the
    /// pinned zone keeps a stable width (muscle memory).
    ///
    /// Split out so the live zone can be reordered by `stripOrderStore` (strip drag-reorder,
    /// route A) while the pinned messaging zone keeps its own `MessagingAppStore` order —
    /// the two zones never cross (dragging happens within a zone).
    func makeProjection() -> StripProjection {
        // This is the only snapshot-to-strip conversion in one body evaluation. Everything below,
        // including drag callbacks captured by that body, consumes the same immutable projection.
        // The Trash chip stands in for Finder's Trash window, so that window gets no card of its own.
        let stripSnapshot = settingsStore.showTrash
            ? TrashWindowAbsorption.removing(
                TrashWindowAbsorption.absorbedWindowIDs(in: runtime.snapshot, trashTitles: TrashWindowLookup.liveTitles),
                from: runtime.snapshot)
            : runtime.snapshot
        let snapshotItems = StripItem.items(from: stripSnapshot)
        let snapshotBundleIDs = Set(snapshotItems.compactMap(\.bundleIdentifier))
        let hiddenBundleIDs = Set(snapshotItems.compactMap { item in
            item.status == "hidden" ? item.bundleIdentifier : nil
        })
        let keptIDs = keptAppStore.bundleIDs
        let runningIDs = runningApplicationStore.runningBundleIDs
        // Unified model: messaging zone visible = (messaging − drawer) ∩ (running ∪ kept). Messaging identity no longer keeps an app alive on its own;
        // kept decides whether it stays after quitting (kept is added on first marking, so the default look is unchanged); the drawer exception still hides it (the drawer has higher priority).
        let msg = AppMembershipProjection.visibleMessagingIDs(
            messagingIDs: messagingStore.bundleIDs,
            drawerIDs: drawerStore.bundleIDs,
            keptIDs: keptIDs,
            runningIDs: runningIDs
        )
        let msgSet = Set(msg)
        // Finder's app-level entry (the card shown when there are no windows) shows only when "Keep in Dock" is ticked (owner, 2026-08-20).
        // The tracking layer still always follows Finder, so after unticking, as soon as a window opens, the window card comes back instantly.
        let showsFinderEntry = FinderTaskbarPolicy.showsAppLevelEntry(
            isKept: keptAppStore.contains(FinderTaskbarPolicy.bundleID)
        )
        let items = snapshotItems.filter { item in
            let bid = item.bundleIdentifier ?? ""
            if drawerStore.contains(bid) { return false }
            if item.isAppLevelFallback, FinderTaskbarPolicy.isFinder(bid), !showsFinderEntry { return false }
            return true
        }

        var messaging: [StripEntry] = []
        var absorbedWindowIDs = Set<String>()
        for bid in msg {
            let appWindows = items.filter { $0.bundleIdentifier == bid && !$0.isAppLevelFallback }
            // The three rules for identifying the main window live in the pure `MessagingMainWindowDecision` (title match → unique after exclusion → can't identify);
            // here we only feed window facts into it.
            let mainID = MessagingMainWindowDecision.mainWindowID(
                bundleID: bid,
                windows: appWindows.map {
                    .init(id: $0.id, title: $0.title,
                          isMinimized: $0.status == WindowStatus.minimized.rawValue,
                          area: ($0.bounds?.width ?? 0) * ($0.bounds?.height ?? 0))
                },
                titleMatchesAppName: { AppDisplayNameResolver.titleMatchesAppName($0, bundleID: bid) }
            )
            let main = appWindows.first { $0.id == mainID }
            if let main { absorbedWindowIDs.insert(main.id) }
            if main == nil || appWindows.count > 1 {
                MessagingZoneDiagnostics.record(bundleID: bid, windows: appWindows, mainID: main?.id)
            }
            messaging.append(.messagingApp(bundleID: bid, mainWindow: main))
        }

        // Live zone: real windows (including kept app windows) + kept app placeholders
        var liveNatural: [StripEntry] = []
        for item in items {
            guard !msgSet.contains(item.bundleIdentifier ?? "") else {
                if item.isAppLevelFallback { continue }     // app chip replaces the app-* fallback
                if absorbedWindowIDs.contains(item.id) { continue }
                liveNatural.append(.window(item))
                continue
            }
            liveNatural.append(.window(item))
        }

        // Kept app placeholders (D1 two sources):
        // a. Unrunning: not in snapshot → inject placeholder
        // b. Running but only isAppLevelFallback → replace the fallback .window with .keptApp
        // Placeholders are inserted at the **head** of liveNatural (in kept store order): in normal running the order is decided by the memory layer,
        // and the array position only affects where a "new id with no memory" lands, i.e. after a cross-machine restart (boottime lost the file) placeholders land at the head of the live zone.
        let snapshotByBundle = Dictionary(grouping: snapshotItems, by: { $0.bundleIdentifier ?? "" })
        var keptPlaceholders: [StripEntry] = []
        for bid in keptIDs {
            guard !drawerStore.contains(bid),
                  !msgSet.contains(bid) else { continue }
            // Finder is intentionally left on the `.window` fallback-card path: it carries a dedicated menu (recent folders /
            // new window) and "click to open home directory", and swapping to a .keptApp LauncherChip would lose all of those.
            // For Finder, kept is only the visibility gate above.
            if FinderTaskbarPolicy.isFinder(bid) { continue }
            let appItems = snapshotByBundle[bid] ?? []
            let hasRealWindow = appItems.contains { !$0.isAppLevelFallback }
            if hasRealWindow { continue }  // Real windows render normally, no placeholder
            if !appItems.isEmpty {
                // Source b: replace fallback .window with .keptApp (same id "app-\(bid)")
                liveNatural.removeAll { entry in
                    if case let .window(item) = entry, item.bundleIdentifier == bid, item.isAppLevelFallback {
                        return true
                    }
                    return false
                }
            }
            // Both sources inject .keptApp with id "app-\(bid)"
            keptPlaceholders.append(.keptApp(bundleID: bid))
        }
        let projectedLive = keptPlaceholders + liveNatural
        let liveOrderIDs = projectedLive.map(\.id)
        let appKeys = Self.appKeys(of: projectedLive)
        let order = stripOrderStore.reconciled(
            current: liveOrderIDs,
            appKeyOf: appKeys,
            headPreferred: Set(messagingStore.bundleIDs)
        )
        let byID = Dictionary(projectedLive.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let orderedLive = order.compactMap { byID[$0] }
        if HoverTrace.isEnabled, dragController.carriedPayload != nil {
            HoverTrace.liveOrder(orderedLive.map(\.id))
        }
        // Multi-screen ④: per-screen filtering happens **only here, and only after the ordering layer**. The `liveOrderIDs` fed to `reconciled` above and
        // what `reconcileLiveOrder` feeds to `sync` are both the full set: consistent across screens, so the shared ordering layer won't
        // treat other screens' cards as absent (kicked out of memory after 5s) and drag-reorder won't truncate in the same frame. Launcher kinds (kept placeholders, `app-*` fallback cards,
        // the messaging zone, folders, transit shelf) are on every screen; if ownership is unknown / the screen is unplugged → land only on the main screen.
        let displayFilter: StripDisplayFilter = {
            guard settingsStore.taskbarScreenPlacement == .allScreensPerDisplay, let displayUUID else {
                return .unfiltered
            }
            let table = displayTopologyStore.table
            return StripDisplayFilter(scope: displayUUID, connectedUUIDs: table.connectedUUIDs,
                                      primaryUUID: table.primaryUUID)
        }()
        // Under ④, the window card being dragged / flying back is drawn on the strip it **claims** (when the pointer hovers over strip B, B takes over: B opens an empty slot,
        // A closes up), ignoring the ownership key; the ownership key only changes after the window is moved on release.
        let carriedStripID = dragController.carriedPayload.flatMap { $0.source == .strip ? $0.id : nil }
        let claimedStrip = dragController.activeStripSurfaceID
        // Ones with a running dot but no window (app-level fallback cards, kept apps that are running but left with only a placeholder) land only on the main screen;
        // non-running placeholders are pure launchers and are on every screen (owner, 2026-09-02: has a dot = only on one strip).
        let renderedLive = orderedLive.filter { entry in
            let subject: StripDisplayFilter.Subject
            switch entry {
            case let .window(item):
                subject = item.isAppLevelFallback
                    ? .runningWithoutWindow(displayUUID: runtime.noWindowHomeByBundle[item.bundleIdentifier ?? ""]
                                                         ?? item.displayUUID)
                    : .window(displayUUID: item.displayUUID)
            case let .keptApp(bid):
                subject = runningIDs.contains(bid)
                    ? .runningWithoutWindow(displayUUID: runtime.noWindowHomeByBundle[bid]
                                                         ?? snapshotByBundle[bid]?.first?.displayUUID)
                    : .launcher
            default:
                return true
            }
            // The card being dragged / flying back is drawn per its claim (launcher kinds are on every screen, no change needed).
            if displayFilter.scope != nil, subject != .launcher, entry.id == carriedStripID, let claimedStrip {
                return claimedStrip == stripSurfaceID
            }
            return displayFilter.shows(subject)
        }
        // Card label: the segment shared by several cards of the same app does not help distinguish, so strip it (issue #41).
        //
        // **Group by "the cards actually shown on this bar"**, so it is computed after `renderedLive` is settled: under ④ each screen
        // shows only its own windows and the common segment differs per screen; computing over the full set would strip the only distinguishing info from the lone remaining card on a screen.
        // It also **must come before the "close up when dragged out" removal**: dragging one card away makes the remaining cards recompute the common segment, and the label would grow on the spot,
        // so the text jumps mid-drag.
        let labelTitleByChipID = Self.labelTitles(for: renderedLive, heldTitles: runtime.heldLabelTitlesByChipID)
        // Make-way gap (hover preview when dragging an app from Finder into the strip). **The injection point must be here**: the ordering layer
        // (`stripOrderStore.reconciled`) and multi-screen filtering have both already run, so the gap can't get into `liveOrderIDs`
        // or `appKeys`; once the ordering layer remembers this ghost id, it would keep reserving a spot for it by the 5s absence anchor after it disappears.
        // The rule shares its source with multi-screen filtering: touch only the render array, and only after the ordering layer.
        let liveWithGhost: [StripEntry] = {
            guard let ghost = externalDropGhost, case let .live(bundleID) = ghost.zone else { return renderedLive }
            // The index was computed from the previous frame's card frames, and this frame the live zone may already have one card fewer (app quit / screen filter change),
            // so it must be clamped: an out-of-range `insert(at:)` crashes outright.
            let index = min(max(ghost.insertIndex, 0), renderedLive.count)
            var next = renderedLive
            next.insert(.externalDropGhost(key: bundleID), at: index)
            return next
        }()
        // The folder-zone gap (a folder dragged in from Finder) goes in after the store order for
        // the same reason: it is a render artifact, never a pinned path. Clamped like the live one.
        var pinnedEntries = pinnedFolderStore.folderPaths.map { StripEntry.pinnedFolder(path: $0) }
        if let ghost = externalDropGhost, ghost.zone == .folder {
            pinnedEntries.insert(.externalDropGhost(key: "folder"),
                                 at: min(max(ghost.insertIndex, 0), pinnedEntries.count))
        }
        // Close up when dragged out (owner, 2026-09-03): when the card being dragged from the strip leaves the strip → remove it from rendering (not make it transparent),
        // the HStack spring closes up and the panel shortens (`PanelCoordinator` subscribes to `stripSlotCollapsed`). **Remove only from the render array**:
        // what `liveOrderIDs` / `messagingIDs` feed the ordering layer and in-zone decisions is still the full set; a differing subset in the ordering layer would mark it absent
        // (rank lost after the 5s grace), and the messaging zone's "member disappears → cancel the drag" listener must not be falsely triggered by it. Only the claimed strip removes it.
        let collapsedEntryID: String? = {
            guard ownsActiveDrag, dragController.stripSlotCollapsed,
                  let p = dragController.hiddenSlotPayload else { return nil }
            if p.source == .folder { return StripEntry.pinnedFolder(path: p.id).id }
            return Self.stripEntryID(for: p)
        }()
        // The shelf is the last cell of the pinned-app (messaging) zone and shares its divider.
        // Folders sit at the bar's tail in one zone with the Trash, as on the native Dock: no
        // divider between them.
        let headEntries = messaging + (settingsStore.showShelf ? [StripEntry.shelf] : [])
        let tailEntries = pinnedEntries + (settingsStore.showTrash ? [StripEntry.trash] : [])
        var zones = [headEntries, liveWithGhost, tailEntries]
            .map { zone in zone.filter { $0.id != collapsedEntryID } }
            .filter { !$0.isEmpty }
        var entries: [StripEntry] = []
        if !zones.isEmpty {
            entries = zones.removeFirst()
            for (index, zone) in zones.enumerated() {
                let dividerID = zone.first?.id == "trash" ? "zone-divider-trash" : "zone-divider-\(index)"
                entries.append(.divider(id: dividerID))
                entries += zone
            }
        }
        let messagingIDs = messaging.compactMap { entry -> String? in
            guard case let .messagingApp(bundleID, _) = entry else { return nil }
            return bundleID
        }
        // Badge landing spot: in the regular zone, the leftmost window card / placeholder card (by display order) of each app. Messaging-zone members are skipped:
        // its red dot is on that zone's icon, and a standalone chat window's card must not draw another one.
        var badgeEntryIDByBundle: [String: String] = [:]
        for entry in entries {
            switch entry {
            case let .window(item):
                guard let bid = item.bundleIdentifier, !msgSet.contains(bid) else { continue }
                if badgeEntryIDByBundle[bid] == nil { badgeEntryIDByBundle[bid] = item.id }
            case let .keptApp(bid):
                guard !msgSet.contains(bid) else { continue }
                if badgeEntryIDByBundle[bid] == nil { badgeEntryIDByBundle[bid] = entry.id }
            default:
                continue
            }
        }
        let draggingID: String?
        // `carriedPayload` rather than `draggingPayload`: after release there is still a 0.26-second settle-back flight,
        // and during that time the original spot must stay empty, otherwise the card shows up first while the carrier is still flying.
        // **Only the strip being dragged from gets the empty slot** (under multi-screen ③④ the same card on other screens is displayed as usual and moves with the shared ordering layer;
        // the owner reported on 2026-09-02 "the corresponding icon on the other screen disappears").
        if !ownsActiveDrag {
            draggingID = nil
        } else if let payload = dragController.hiddenSlotPayload,
           payload.source == .strip,
           liveOrderIDs.contains(payload.id) {
            draggingID = payload.id
        } else if let converted = dragController.convertedChipID,
                  liveOrderIDs.contains(converted) {
            // **Match the chip id, not the representative card**: what the `keepPlacement` path materializes is a `.keptApp` placeholder or
            // an app-level fallback card, and neither can serve as a `StripItem` representative card; following the representative card would never make way (double image).
            draggingID = converted
        } else if let bid = dragController.convertedDrawerBundleID,
                  let materialized = entries.lazy.compactMap({ entry -> String? in
                      switch entry {
                      case let .window(item): return item.bundleIdentifier == bid ? item.id : nil
                      case let .keptApp(id): return id == bid ? entry.id : nil
                      default: return nil
                      }
                  }).first(where: { liveOrderIDs.contains($0) }) {
            // At the moment of conversion, `convertedChipID` is still nil: it is written in `syncConvertedCarrier`, **after** this round of rendering.
            // If we only relied on it, the freshly materialized card would first be inserted into the strip at 1.0 opacity and hidden only on the next round; SwiftUI gives insertion a fade-in
            // and hiding a fade-out, so what you see is "a very faint icon sliding from the end to the landing spot" (owner, 2026-09-04; it only showed up after the icon cache was fixed and
            // reveal got faster). Derive the card to hide directly from the conversion state (the same rule as `liveEntryIDs(bundleID:).first`, which guarantees it is the same card as the
            // `convertedChipID` written afterwards), taking effect in the same round as the insertion.
            draggingID = materialized
        } else {
            draggingID = nil
        }
        let frontWindowChipIDs: Set<String> = settingsStore.frontWindowBar
            ? FrontWindowIndicatorDecision.frontWindowChipIDs(
                items: snapshotItems,
                optimisticStates: runtime.optimisticStatesByWindowID
            )
            : []
        return StripProjection(
            snapshotItems: snapshotItems,
            snapshotBundleIDs: snapshotBundleIDs,
            hiddenBundleIDs: hiddenBundleIDs,
            messaging: messaging,
            liveNatural: projectedLive,
            liveOrderIDs: liveOrderIDs,
            appKeyByChipID: appKeys,
            labelTitleByChipID: labelTitleByChipID,
            entries: entries,
            layoutKeys: entries.map(StripLayoutKey.init),
            messagingIDs: messagingIDs,
            draggingID: draggingID,
            badgeEntryIDByBundle: badgeEntryIDByBundle,
            frontWindowChipIDs: frontWindowChipIDs
        )
    }

    /// The label finally displayed for each window card: first strip the trailing app name, then strip the common segment shared by several cards of the same app.
    ///
    /// Both steps are needed: under ④ a bar may be left with only one card of some app (`showsTitle` is still true and the
    /// title is still shown), with no companion to compare a common segment against, and then only the app-name step can take effect.
    /// `heldTitles`: cards frozen by label follow-suppression (`WindowTitleSettle`) → the title they should show, substituted only here;
    /// the bubble (`fullTitle`) and menu still use `item.title`.
    private static func labelTitles(for entries: [StripEntry], heldTitles: [String: String]) -> [String: String] {
        var itemsByApp: [String: [(id: String, title: String)]] = [:]
        for case let .window(item) in entries {
            let appName = item.bundleIdentifier.map(AppDisplayNameResolver.displayName(for:)) ?? item.appID
            let resolved = WindowDisplayTitle.resolve(rawTitle: heldTitles[item.id] ?? item.title, fallbackName: appName)
            let withoutApp = WindowDisplayTitle.trimmingAppNameSuffix(resolved, appName: appName)
            itemsByApp[item.bundleIdentifier ?? item.appID, default: []].append((item.id, withoutApp))
        }

        var labels: [String: String] = [:]
        for (_, group) in itemsByApp {
            let trimmed = StripSharedAffixTrim.trimmingSharedAffixes(group.map(\.title))
            for (entry, label) in zip(group, trimmed) { labels[entry.id] = label }
        }
        return labels
    }

    /// **Use this in `onChange` closures, not the `projection` captured by the closure.**
    ///
    /// When the old-style `onChange(of:perform:)` fires, it runs the closure installed on the **previous frame**, so the projection in it
    /// is always one generation behind. Normally that doesn't matter (the next change catches up), but at the moment of drawer conversion it is fatal
    /// (measured 2026-08-18: the render already had 12 cards while `sync` still received 11, without the placeholder that had just appeared):
    ///
    /// 1. In `sync`, `next.contains("app-<bid>")` is false → **the landing-spot stash is never consumed**;
    /// 2. So the memory order `liveOrder` never gets this id → the later `reorderBlock`'s `movingBlock`
    ///    can't find the id to move and **returns unchanged every time** (the five `ok`s in the log are all idle spins);
    /// 3. Rendering can only fall back to the stable kept rank from `reconciled`, pinning it to a fixed position unrelated to the cursor.
    ///
    /// That is the owner's "hard to trigger, pushing the other icons away". The cost of rebuilding a projection here is acceptable:
    /// it fires only when the set of cards in the live zone has really changed, not every frame, let alone every mouse move.
    /// (The AGENTS rule "build only one projection per body" governs the **render path**; this is the side-effect path.)
    func freshProjection() -> StripProjection { makeProjection() }

    /// The render path (`reconciled`) and the side-effect path (`sync`) **must be fed the same appKeyOf**, otherwise the persisted memory order
    /// would disagree with the display order. Factored into one function so the two paths can't diverge.
    static func appKeys(of liveNatural: [StripEntry]) -> [String: String] {
        Dictionary(liveNatural.map { entry -> (String, String) in
            switch entry {
            case let .window(item): return (entry.id, item.bundleIdentifier ?? item.appID)
            case let .keptApp(bid): return (entry.id, bid)
            default: return (entry.id, entry.id)
            }
        }, uniquingKeysWith: { first, _ in first })
    }
}
