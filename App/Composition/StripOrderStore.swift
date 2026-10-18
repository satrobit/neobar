import Foundation

/// Task strip drag-to-reorder, route A (anti-shuffle within a session): the **display-order state layer**, managing only the main strip's
/// **live window zone** (live zone). It holds an ordered list of chip ids; each render uses `reconciled(current:)`
/// to reconcile against the "currently alive chips" (existing ones keep order, new windows go to the end, truly closed ones are dropped), and a drag uses `move` to change the order.
///
/// Boundary: the order of the fixed messaging zone is managed by `MessagingAppStore` itself; this store **manages only the live zone and never crosses the boundary**.
/// The ordering primitives live in `StripOrdering` (`UI/ReadModel/StripItem.swift`); this class is only its stateful shell.
///
/// Persistence has two layers and **does not** do Dock-like layout restoration across shutdowns:
/// - **Same boot cycle** (`stripLiveOrder` + `stripLiveOrderBootTime`): the exact chip order, keyed by
///   the stable `tabgrp-*` seat tokens + the `app-*` of kept apps. If the boot time changed (= the machine was restarted, cgWindowID
///   gets reshuffled/reused), the whole record is discarded; **chip ids are never taken over across boots**.
/// - **Across machine restarts** (`stripKeptAppOrderV1`): stores only the bundleID ranking of ordinary kept apps. It is not a
///   "one-time reorder at cold start" mode but a **standing placement rule** fed to `StripOrdering.reconcile`:
///   cards with no position memory are placed by rank, and late-arriving windows follow the same rule (reason in `stableKeptRanks` and AGENTS).
///
/// The order of the messaging zone and the drawer still belongs to their own order stores; this class manages only the live zone and never crosses the boundary.
@MainActor
final class StripOrderStore: ObservableObject {
    @Published private(set) var liveOrder: [String] = []
    @Published private(set) var stableKeptAppOrder: [String] = []

    private let orderKey = "stripLiveOrder"
    private let bootKey = "stripLiveOrderBootTime"
    private let stableKeptOrderKey = "stripKeptAppOrderV1"
    /// Boot time of this boot (seconds). Constant within a boot cycle, so caching it once is enough.
    private let bootTime: Int

    /// Position-memory stickiness (slice 1). When a chip id **briefly disappears** from the current snapshot (occasional AX missed reads in Safari,
    /// tab-group anchor migration, etc.), do not immediately delete it from the remembered order: record the disappearance time, and within the grace period still treat it as "present"
    /// to keep its rank, only the display layer does not render it (`reconciled` filters with the real current). Only when it still has not returned after the grace period
    /// is it truly dropped. This way a card that flickers away and returns reconnects to its original position instead of being thrown as a new card to the right of its same-app peers.
    private var absentSince: [String: Date] = [:]
    private static let rankRetentionGrace: TimeInterval = 5.0

    /// Sticky id->appKey memory. Once a window disappears the appKeyOf mapping is lost, and the placeholder app-* would jump to the tail for lack of a peer.
    /// Each sync merges the incoming appKeyOf; eviction timing = the end of sync, after liveOrder is updated, keeping only
    /// keys within current ∪ liveOrder; an id within its grace period is still in liveOrder, so its key is not deleted by mistake.
    private var stickyAppKeys: [String: String] = [:]

    /// **Staging of the external block** for a drawer-to-strip drag with an exact drop point. On the frame of promotion the window cards are not yet in the live zone (`drawerStore.remove`
    /// puts them back only on the next round), so card ids cannot be obtained; therefore only `bundleID + target` is recorded, and the card ids are resolved in the next `sync` via `appKeyOf`
    /// and placed with `movingBlock`; the resolved ids are backfilled into `boundIDs` so that undo can clear them exactly.
    private var externalBlock: (bundleID: String, target: String?, after: Bool, boundIDs: [String])?

    private let defaults: UserDefaults
    private let now: () -> Date
    private let keptIDsProvider: () -> Set<String>
    private let stableKeptOrderProvider: () -> [String]
    private let inventoryLog: WindowInventoryAnomalyLog
    private var lastProjectionSample: InventoryOrderProjectionSample?

    /// Whether the diagnostic payload should be constructed. The caller asks this before building `InventoryOrderProjectionSample`;
    /// that payload contains the whole appKey dictionary, so constructing it with logging off is pure waste (same pattern as in `AppTracker`).
    var isInventoryLogEnabled: Bool { inventoryLog.isEnabled }

    init(defaults: UserDefaults = .standard,
         now: @escaping () -> Date = Date.init,
         keptIDsProvider: @escaping () -> Set<String> = { [] },
         stableKeptOrderProvider: (() -> [String])? = nil,
         bootTimeProvider: () -> Int = StripOrderStore.bootTimeSeconds,
         inventoryLog: WindowInventoryAnomalyLog = WindowInventoryAnomalyLog()) {
        self.defaults = defaults
        self.now = now
        self.keptIDsProvider = keptIDsProvider
        self.stableKeptOrderProvider = stableKeptOrderProvider ?? { Array(keptIDsProvider()).sorted() }
        self.inventoryLog = inventoryLog
        bootTime = bootTimeProvider()

        let eligibleOrder = self.stableKeptOrderProvider()
        let eligible = Set(eligibleOrder)
        if defaults.object(forKey: stableKeptOrderKey) != nil {
            let stored = defaults.stringArray(forKey: stableKeptOrderKey) ?? []
            var cleaned = Self.cleanedStableOrder(stored, eligible: eligible)
            let known = Set(cleaned)
            cleaned.append(contentsOf: eligibleOrder.filter { !known.contains($0) })
            stableKeptAppOrder = cleaned
            if cleaned != stored { defaults.set(cleaned, forKey: stableKeptOrderKey) }
        } else {
            let legacyApps = (defaults.stringArray(forKey: orderKey) ?? []).compactMap { id -> String? in
                guard id.hasPrefix("app-") else { return nil }
                return String(id.dropFirst(4))
            }
            stableKeptAppOrder = Self.cleanedStableOrder(legacyApps + eligibleOrder, eligible: eligible)
            defaults.set(stableKeptAppOrder, forKey: stableKeptOrderKey)
        }

        // Trust the exact chip order only when the save comes from the **same boot cycle** (cgWindowID is reshuffled/reused across restarts).
        // No chip id is taken over across boots; the bundleID ranking from `stableKeptAppOrder` is arranged live in reconcile.
        if defaults.object(forKey: bootKey) != nil,
           defaults.integer(forKey: bootKey) == bootTime,
           let saved = defaults.stringArray(forKey: orderKey) {
            liveOrder = saved
        }
    }

    /// Cross-restart ranking (appKey -> rank). Fed to `StripOrdering` so that kept app cards with **no memory** are placed by rank.
    /// This is not a "one-time cold-start mode": at boot the task strip starts before most apps (AppTracker still has four rescan rounds),
    /// and late-arriving windows must follow the same rule, otherwise those apps would never get a rank and could only land at the end.
    private var stableKeptRanks: [String: Int] {
        let eligible = Set(stableKeptOrderProvider())
        var ranks: [String: Int] = [:]
        for appKey in stableKeptAppOrder where eligible.contains(appKey) {
            ranks[appKey] = ranks.count
        }
        return ranks
    }

    /// Display order = the result of reconciling the remembered order against the currently alive chip ids (does not change its own state, safe to read in body).
    /// `appKeyOf` (chip id -> owning app key) lets a new window be inserted next to its same-app peers rather than at the far right of the strip.
    /// The sticky appKey is merged non-destructively here: the incoming one takes priority, the remembered one is the fallback.
    ///
    /// **Pure read, never writes `absentSince`** (side effects are forbidden during body evaluation): the anchors absent in this frame are computed by `absentRankAnchors`
    /// from `liveOrder` + read-only `absentSince` + the current time, sharing the same computation with `sync`. Rendering happens
    /// before `sync` stamps; at that moment an old entry that has just gone absent still has `absentSince` as nil, and `absentRankAnchors` treats it as an anchor within
    /// grace for positioning; otherwise a new `app-*`/`tabgrp-*` from quit/reopen would be tail-inserted on its first frame and pulled back by the spring = a shadow slide.
    /// Anchors are used only to position a new id next to its same-app peers, and are filtered out of the visible output once computed (the user sees only the real current).
    func reconciled(current: [String], appKeyOf: [String: String] = [:],
                    headPreferred: Set<String> = []) -> [String] {
        var merged = stickyAppKeys
        merged.merge(appKeyOf) { _, new in new }
        let currentSet = Set(current)
        let anchors = absentRankAnchors(current: currentSet, now: now())
        let effectiveCurrent = current + anchors
        backfillPlaceholderAppKeys(&merged, ids: effectiveCurrent)
        let ordered = StripOrdering.reconcile(
            remembered: liveOrder,
            current: effectiveCurrent,
            appKeyOf: merged,
            headPreferredKeys: headPreferred,
            stableKeptRanks: stableKeptRanks
        )
        let anchorSet = Set(anchors)
        return ordered.filter { !anchorSet.contains($0) }
    }

    /// Absent rank-anchors (**shared** by the `reconciled` render path and the `sync` side-effect path): old entries in `liveOrder` that are not in
    /// `current` this frame but should still keep their position. **The full set is taken from `liveOrder`, not `absentSince.keys`**: the first
    /// render frame happens before `sync` stamps, and an entry that has just gone absent still has `absentSince` as nil, so it must be treated as an anchor within grace
    /// with elapsed=0; one already stamped and still within grace continues as an anchor; once grace expires it is no longer an anchor. **Pure read**, does not write `absentSince`.
    private func absentRankAnchors(current: Set<String>, now: Date) -> [String] {
        liveOrder.filter { id in
            guard !current.contains(id) else { return false }
            guard let t = absentSince[id] else { return true }   // just went absent (sync has not stamped yet) -> elapsed=0
            return now.timeIntervalSince(t) <= Self.rankRetentionGrace
        }
    }

    /// The `app-*` placeholder id carries its bundleID; when the mapping is missing, fill it in from the id (`app-com.foo` -> `com.foo`), ensuring the first frame's
    /// "same-app peer" positioning does not come up empty: for kept quit (`tabgrp-*` -> `app-*`) and reopen (`app-*` -> `tabgrp-*`)
    /// the first frame relies on the placeholder and the real window sharing the same app key. An existing mapping is not overwritten.
    private func backfillPlaceholderAppKeys(_ map: inout [String: String], ids: [String]) {
        for id in ids where id.hasPrefix("app-") && map[id] == nil {
            map[id] = String(id.dropFirst(4))
        }
    }

    /// Converge the remembered order with the current live set (drop truly closed ones, insert new windows next to same-app peers), keeping the manually arranged relative order.
    /// **Called as a side effect of snapshot changes, never during body evaluation.** `appKeyOf` must come from the same source as `reconciled`,
    /// otherwise the persisted memory order would disagree with the display order, and on the next frame a new window would jump from beside its peers back to the end.
    func sync(
        current: [String],
        appKeyOf: [String: String] = [:],
        headPreferred: Set<String> = [],
        projectionSample: InventoryOrderProjectionSample? = nil
    ) {
        let now = self.now()
        if let projectionSample, projectionSample != lastProjectionSample {
            inventoryLog.record(.orderProjectionChanged(
                projectionSample.payload(previousLiveIDs: lastProjectionSample?.currentLiveIDs ?? [])
            ))
            lastProjectionSample = projectionSample
        }
        syncStableKeptMembership()
        // Merge appKeyOf into the sticky memory
        stickyAppKeys.merge(appKeyOf) { _, new in new }

        let currentSet = Set(current)

        // Returned id: clear its absent stamp.
        for id in current { absentSince.removeValue(forKey: id) }
        // An id that just disappeared from the remembered order: stamp it absent (only if already registered). **Stamping happens only in sync**.
        for id in liveOrder where !currentSet.contains(id) && absentSince[id] == nil {
            absentSince[id] = now
        }
        // An absent id within grace counts as "still present" -> keeps its rank; an expired one is no longer kept -> handed to reconcile to drop.
        // Reuses the same anchor helper as reconciled -> the pre-sync render and the post-sync visible order are consistent.
        // Stamping is done at this point, so every anchor already has absentSince (the helper's nil branch takes effect only on the render path).
        let anchors = absentRankAnchors(current: currentSet, now: now)
        let effectiveCurrent = current + anchors
        backfillPlaceholderAppKeys(&stickyAppKeys, ids: effectiveCurrent)
        let expiredMemory = absentSince.filter {
            now.timeIntervalSince($0.value) > Self.rankRetentionGrace
        }
        let reconcileResult = StripOrdering.reconcileWithTrace(
            remembered: liveOrder,
            current: effectiveCurrent,
            appKeyOf: stickyAppKeys,
            headPreferredKeys: headPreferred,
            stableKeptRanks: stableKeptRanks
        )
        var next = reconcileResult.order
        absentSince = absentSince.filter { now.timeIntervalSince($0.value) <= Self.rankRetentionGrace }
        // Consume the external-block staging: once all of the dragged app's window cards are in current (reconcile has folded them into next), resolve this group of
        // cards with appKeyOf and drop them as a block at the staged target, **completed in a single publish**: no tail flash-in, not moved away by the reconcile rules. app-* fallback cards are excluded.
        // The keepPlacement path has no window cards, so it falls back to using the placeholder id "app-\(bundleID)" as a single-element block.
        if var ext = externalBlock {
            var blockIDs = next.filter { stickyAppKeys[$0] == ext.bundleID && !$0.hasPrefix("app-") }
            if blockIDs.isEmpty {
                let placeholderID = "app-\(ext.bundleID)"
                if next.contains(placeholderID) { blockIDs = [placeholderID] }
            }
            if !blockIDs.isEmpty {
                next = StripOrdering.movingBlock(next, move: blockIDs, relativeTo: ext.target, after: ext.after)
                ext.boundIDs = blockIDs
                externalBlock = ext
            }
        }
        for (chipID, since) in expiredMemory {
            inventoryLog.record(.orderMemoryDropped(InventoryOrderMemoryDroppedPayload(
                chipID: chipID,
                appKey: stickyAppKeys[chipID],
                previousIndex: liveOrder.firstIndex(of: chipID) ?? -1,
                absentForMs: max(0, Int((now.timeIntervalSince(since) * 1_000).rounded()))
            )))
        }
        let currentSetForLog = Set(current)
        let visibleNextForLog = next.filter(currentSetForLog.contains)
        for placement in reconcileResult.placements where currentSetForLog.contains(placement.chipID) {
            inventoryLog.record(.orderChipPlaced(InventoryOrderChipPlacedPayload(
                chipID: placement.chipID,
                appKey: stickyAppKeys[placement.chipID],
                index: visibleNextForLog.firstIndex(of: placement.chipID) ?? placement.index,
                reason: placement.reason.rawValue
            )))
        }
        if next != liveOrder {
            liveOrder = next
            updateStableKeptOrder(from: liveOrder)
            persistLiveOrder()
        } else {
            updateStableKeptOrder(from: liveOrder)
        }

        // Evict sticky appKeys: keep only keys within current ∪ liveOrder (an id within grace is still in liveOrder).
        let aliveKeys = currentSet.union(Set(liveOrder))
        stickyAppKeys = stickyAppKeys.filter { aliveKeys.contains($0.key) }
    }

    // MARK: - External block drop point (drawer-to-strip drag, exact drop point)

    /// Promotion into the task strip: stage "this app's window cards placed as a block left/right of `target` (`target==nil` = end)", consumed on the next `sync`.
    func stageExternalBlock(bundleID: String, relativeTo target: String?, after: Bool) {
        externalBlock = (bundleID, target, after, [])
    }

    /// Continuous reorder (after the window cards are materialized and the staging consumed): move this group of ids as a block to `targetID`. Publishes only on change.
    func reorderBlock(ids: [String], relativeTo targetID: String, after: Bool) {
        let next = StripOrdering.movingBlock(liveOrder, move: ids, relativeTo: targetID, after: after)
        if next != liveOrder { liveOrder = next; updateStableKeptOrder(from: next); persistLiveOrder() }
    }

    /// Settle: only clear the staging tracking; `boundIDs` stay in `liveOrder` (already normal members).
    func commitExternalBlock() { externalBlock = nil }

    /// Undo promotion: delete `boundIDs` from `liveOrder` and clear their `absentSince` (otherwise the 5s rank stickiness would revive them as ghost ranks),
    /// and clear the staging. **Must be called before `drawerStore.add` in `revertDrawerToStrip` triggers sync**.
    func cancelExternalBlock() {
        guard let ext = externalBlock else { return }
        let ids = Set(ext.boundIDs)
        if !ids.isEmpty {
            let next = liveOrder.filter { !ids.contains($0) }
            for id in ids { absentSince.removeValue(forKey: id) }
            if next != liveOrder { liveOrder = next; updateStableKeptOrder(from: next); persistLiveOrder() }
        }
        externalBlock = nil
    }

    /// Drag drop: place `draggedID` on the left/right side of `targetID`. First reconcile to fix the current display order, then insert;
    /// do not publish if the order did not change (`dropUpdated` is called at high frequency during a drag; this filters out pointless churn).
    func reorder(draggedID: String, relativeTo targetID: String, after: Bool, current: [String]) {
        let base = StripOrdering.reconcile(remembered: liveOrder, current: current, appKeyOf: stickyAppKeys)
        let next = StripOrdering.reordering(base, move: draggedID, relativeTo: targetID, after: after)
        if next != liveOrder { liveOrder = next; updateStableKeptOrder(from: next); persistLiveOrder() }
    }

    /// Persist the current order: store `tabgrp-*` + the kept `app-*` + this boot's time.
    private func persistLiveOrder() {
        defaults.set(StripOrdering.persistableLiveOrder(liveOrder, keptIDs: keptIDsProvider()), forKey: orderKey)
        defaults.set(bootTime, forKey: bootKey)
    }

    private func syncStableKeptMembership() {
        let eligibleOrder = stableKeptOrderProvider()
        let eligible = Set(eligibleOrder)
        var next = stableKeptAppOrder.filter(eligible.contains)
        let known = Set(next)
        next.append(contentsOf: eligibleOrder.filter { !known.contains($0) })
        guard next != stableKeptAppOrder else { return }
        stableKeptAppOrder = next
        defaults.set(next, forKey: stableKeptOrderKey)
    }

    /// Reorder only the visible members in the full stable list. Hidden drawer members keep
    /// their slots, matching the drawer/messaging order-store contract.
    private func updateStableKeptOrder(from chipOrder: [String]) {
        syncStableKeptMembership()
        let eligible = Set(stableKeptOrderProvider())
        var seen = Set<String>()
        let visible = chipOrder.compactMap { id -> String? in
            guard let appKey = stickyAppKeys[id], eligible.contains(appKey), seen.insert(appKey).inserted else {
                return nil
            }
            return appKey
        }
        guard !visible.isEmpty else { return }
        let visibleSet = Set(visible)
        let slots = stableKeptAppOrder.indices.filter { visibleSet.contains(stableKeptAppOrder[$0]) }
        guard slots.count == visible.count else { return }
        var next = stableKeptAppOrder
        for (slot, appKey) in zip(slots, visible) { next[slot] = appKey }
        guard next != stableKeptAppOrder else { return }
        stableKeptAppOrder = next
        defaults.set(next, forKey: stableKeptOrderKey)
    }

    private static func cleanedStableOrder(_ values: [String], eligible: Set<String>) -> [String] {
        var seen = Set<String>()
        return values.filter { eligible.contains($0) && seen.insert($0).inserted }
    }

    /// Seconds of `kern.boottime`; if unreadable give 0 (= trust no save, a safe degradation).
    private nonisolated static func bootTimeSeconds() -> Int {
        var tv = timeval()
        var size = MemoryLayout<timeval>.stride
        return sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0 ? Int(tv.tv_sec) : 0
    }
}
