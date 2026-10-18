import CoreGraphics
import Foundation

enum WindowDisplayTitle {
    static func resolve(rawTitle: String?, fallbackName: String) -> String {
        let title = rawTitle.flatMap { title in
            title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : title
        } ?? fallbackName
        return title == "NeoBar" ? String(localized: "Taskbar") : title
    }

    /// For the card label: strips the trailing "separator + app name" from the window title (`local-dc02 - Google Chrome`
    /// -> `local-dc02`). The icon already shows which app it is, so the suffix is pure repetition, and it pushes the front half that actually tells windows apart
    /// past `WindowTitleTextMetrics.maximumWidth` (140pt) and gets it truncated -- the two Chrome cards in issue #41's screenshot
    /// were like this, one left with only "local-dc02 - Google C...".
    ///
    /// **Applies only to the rendered label**: the system tooltip from `.help()` still shows the full untruncated title,
    /// otherwise the app name of an icon-only card (which shows no text at all) would be visible nowhere.
    /// The window list in the menu (`WindowListMenuPlan`) deliberately doesn't go through here -- menu rows are wide and don't truncate.
    static func trimmingAppNameSuffix(_ title: String, appName: String) -> String {
        let app = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !app.isEmpty, title.hasSuffix(app), title != app else { return title }

        var head = Substring(title).dropLast(app.count)
        // Eat only one separator: `A - B - Chrome` should become `A - B` after removing the tail, not `A`.
        guard let separator = separators.first(where: { head.hasSuffix($0) }) else { return title }
        head = head.dropLast(separator.count)

        let remainder = head.trimmingCharacters(in: .whitespacesAndNewlines)
        // If only whitespace remains after stripping = the title was just the app name to begin with; leave it as is.
        return remainder.isEmpty ? title : remainder
    }

    /// Trailing separators. Longer ones first, so ` - ` doesn't match first and eat half of a `–` / `—` case.
    private static let separators = [" - ", " — ", " – ", " | ", " · ", "-", "—", "–", "|"]
}

struct StripItem: Hashable {
    let id: String
    let title: String
    let status: String
    let appID: String
    let bundleIdentifier: String?
    let sameAppCardCount: Int
    let showsTitle: Bool
    let isAppLevelFallback: Bool
    let canMinimize: Bool
    let canHide: Bool
    let canClose: Bool
    let isOnDesktop: Bool
    /// Current representative WindowServer id for this chip, if any. Live snapshot
    /// fact only: never persisted, never used as chip identity.
    let cgWindowID: CGWindowID?
    /// Current representative frame in screen coordinates, if available.
    let bounds: CGRect?
    /// Current representative process id.
    let pid: Int32
    /// Which display the representative window sits on (coarse key; nil = unknown). Live fact only.
    let displayUUID: String?
    /// Window the show/hide actions (toggle/activate/minimize/hide/newWindow) route to, and the key
    /// the optimistic-state overlay is read/written under. For a native tab group this is the focused (active)
    /// tab; for a plain window it equals `id`.
    let actionWindowID: String
    /// All real windows behind this chip. A single window → `[id]`; a tab group → every tab,
    /// so "Close Window" can close the whole group (2026-06-14 decision: "close the whole group").
    let memberWindowIDs: [String]

    /// Builds a chip from one or more window records. ≥2 records means a native tab group
    /// (same app + identical frame) collapsed into a single chip.
    init(members: [WindowRecord], sameAppCardCount: Int = 1) {
        // Stable SwiftUI identity = the group's stable token (`groupID`). It does **not change with the active tab's CGWindowID**,
        // nor with members being added or removed (background tabs coming and going, minimized ones leaving AX) → a merged card never changes identity, no jumping or splitting.
        // All members of the same group share one groupID, so taking the first is enough; for an app-* fallback card the groupID = its own id (a group of one).
        let anchor = members.min { ($0.cgWindowID ?? .max) < ($1.cgWindowID ?? .max) } ?? members[0]
        let token = members[0].groupID
        // Display + action representative = the **visible** tab of the group. In a native tab group the
        // non-current tabs report to AX as `.minimized`; exactly one tab is on-screen. Prefer the
        // truly-focused tab (`.active`, only set while the app is frontmost), else the lone visible
        // (non-minimized) tab, else — whole group minimized/hidden — the stable anchor.
        //
        // Keying on visibility (min flag) rather than focus is what makes tab-switching feel instant:
        // switching tabs fires Deminiaturized for the new tab (min→false) promptly, whereas the
        // .active/focus flag lags. So the title follows the Deminiaturized notification, not focus.
        let representative = members.first { $0.status == .active }
            ?? members.first { $0.status != .minimized && $0.status != .hidden }
            ?? anchor

        self.id = token
        self.actionWindowID = representative.id.rawValue
        self.memberWindowIDs = members.map(\.id.rawValue)
        self.title = representative.title
        self.status = representative.status.rawValue
        self.appID = representative.appID.rawValue
        self.bundleIdentifier = representative.bundleIdentifier
        self.sameAppCardCount = sameAppCardCount
        self.showsTitle = sameAppCardCount >= 2
        self.isAppLevelFallback = token.hasPrefix("app-")
        self.canMinimize = self.isAppLevelFallback == false
        self.canHide = true
        self.canClose = self.isAppLevelFallback == false
        self.isOnDesktop = representative.isOnDesktop
        self.cgWindowID = representative.cgWindowID
        self.bounds = representative.bounds
        self.pid = representative.pid
        self.displayUUID = representative.displayUUID
    }

    init(record: WindowRecord, sameAppCardCount: Int = 1) {
        self.init(members: [record], sameAppCardCount: sameAppCardCount)
    }

    static func items(from snapshot: DockSnapshot) -> [StripItem] {
        let records = snapshot.orderedWindowIDs.compactMap { snapshot.windows[$0] }

        // Collapse native tab groups (same app + identical frame) into one slot, preserving
        // first-appearance order. Non-groupable records (app-* fallback, frameless) stay solo.
        var slots: [[WindowRecord]] = []
        var slotIndexByKey: [String: Int] = [:]
        for record in records {
            let key = tabGroupKey(for: record)
            if let key, let idx = slotIndexByKey[key] {
                slots[idx].append(record)
            } else {
                if let key { slotIndexByKey[key] = slots.count }
                slots.append([record])
            }
        }

        let countByApp = Dictionary(grouping: slots) { appGroupingKey(for: $0[0]) }
            .mapValues(\.count)

        return slots.map { members in
            StripItem(members: members, sameAppCardCount: countByApp[appGroupingKey(for: members[0])] ?? 1)
        }
    }

    private static func appGroupingKey(for record: WindowRecord) -> String {
        record.bundleIdentifier ?? record.appID.rawValue
    }

    /// Identity of the native tab group a record belongs to = the stable `groupID` token computed by the tracking layer.
    /// All tabs of the same physical window share the same token (once assigned it doesn't drift with the active tab's cgID / background tabs' frames),
    /// and merging is based on it; an app-* fallback card's groupID = its own unique id and never collides with others → naturally independent, never wrongly merged.
    /// Returns nil if the record doesn't take part in merging (a fallback card with no cgWindowID).
    private static func tabGroupKey(for record: WindowRecord) -> String? {
        guard record.cgWindowID != nil else { return nil }
        return record.groupID
    }
}

/// Task strip drag reorder, route A (anti-shuffle within a session): pure ordering primitives.
///
/// Design in `03 Design Decisions#Task strip drag reorder`. This layer only applies stateless transforms to a list of chip ids:
/// no UI, no persistence, no touching the window identity model. The stateful ordering layer (`StripOrderStore`) and the drag gesture
/// are wired in in later slices and reuse the primitives here.
///
/// Key premise: **seat lifecycle is already guaranteed upstream in `DockSnapshot`** -- minimized / hidden / CG-temporarily-vanished
/// windows all remain in the snapshot (the seat isn't released); only a "real close" makes a window disappear from the snapshot. So in this layer
/// "not in the current list" means "the seat has truly ended", and there's no need, nor should we, to re-judge here whether the window exists.
enum StripOrdering {
    enum PlacementReason: String, Codable, Equatable {
        case sameAppSibling
        case headPreferred
        case stableKeptRank
        case tail
    }

    struct Placement: Equatable {
        let chipID: String
        let index: Int
        let reason: PlacementReason
    }

    struct ReconcileResult: Equatable {
        let order: [String]
        let placements: [Placement]
    }

    /// Reconciles the "remembered display order" with the "chips currently alive" to produce the new display order.
    ///
    /// - Remembered and still present -> keep the remembered relative order (**the core of anti-shuffle**: neighbors being added or removed don't move already-arranged cards).
    /// - Newly appeared (present now, never remembered) -> inserted after the last "existing chip of the same app" (stick to companions: a tab dragged out
    ///   into its own window / Cmd+N both follow the app's existing chips, no longer thrown to the far right of the strip); only if the app has none at all
    ///   (= a brand-new app) is it appended at the end. If `appKeyOf` is empty (default) -> degrades to the old "always append at the end" behavior.
    /// - Remembered but no longer present -> dropped (the seat truly ended, see the type comment).
    /// `headPreferredKeys`: a **new** window of one of these app keys, if it has no companion, is inserted at the **head** of the live zone (not the end) --
    /// a messaging app's popup window lands right next to the messaging zone (owner 2026-07-12 #4). Affects only new ids never remembered; remembered ones stay in place.
    /// `stableKeptRanks`: cross-restart ranking of ordinary kept apps (appKey -> rank). A new id with no companion and not head-preferred,
    /// if it belongs to an app within the ranking, lands between existing ranked cards by rank, rather than being thrown to the end.
    static func reconcile(remembered: [String], current: [String], appKeyOf: [String: String] = [:],
                          headPreferredKeys: Set<String> = [],
                          stableKeptRanks: [String: Int] = [:]) -> [String] {
        reconcileWithTrace(
            remembered: remembered,
            current: current,
            appKeyOf: appKeyOf,
            headPreferredKeys: headPreferredKeys,
            stableKeptRanks: stableKeptRanks
        ).order
    }

    static func reconcileWithTrace(
        remembered: [String],
        current: [String],
        appKeyOf: [String: String] = [:],
        headPreferredKeys: Set<String> = [],
        stableKeptRanks: [String: Int] = [:]
    ) -> ReconcileResult {
        let currentSet = Set(current)
        let rememberedSet = Set(remembered)
        // Remembered and still present: keep the remembered relative order
        var result = remembered.filter { currentSet.contains($0) }
        var placements: [Placement] = []
        func rank(_ id: String) -> Int? { appKeyOf[id].flatMap { stableKeptRanks[$0] } }
        // Newly appeared: (1) has a same-app companion -> insert after the companion; (2) no companion and the app is head-preferred (a messaging app's popup window) ->
        // insert at the head (after existing head-preferred ones, keeping their relative order); (3) no companion but a kept app within the cross-restart ranking
        // -> land between ranked cards by rank; (4) otherwise the end. Processed in `current` order -> multiple new windows of the same app
        // also keep their relative order.
        for id in current where !rememberedSet.contains(id) {
            let app = appKeyOf[id]
            if let app, let pos = result.lastIndex(where: { appKeyOf[$0] == app }) {
                result.insert(id, at: pos + 1)
                placements.append(Placement(chipID: id, index: pos + 1, reason: .sameAppSibling))
            } else if let app, headPreferredKeys.contains(app) {
                let headPos = result.lastIndex { appKeyOf[$0].map(headPreferredKeys.contains) ?? false }
                let index = headPos.map { $0 + 1 } ?? 0
                result.insert(id, at: index)
                placements.append(Placement(chipID: id, index: index, reason: .headPreferred))
            } else if let app, let myRank = stableKeptRanks[app] {
                let index = stableKeptInsertIndex(
                    in: result,
                    myRank: myRank,
                    rank: rank,
                    appKeyOf: appKeyOf,
                    headPreferredKeys: headPreferredKeys
                )
                result.insert(id, at: index)
                placements.append(Placement(chipID: id, index: index, reason: .stableKeptRank))
            } else {
                result.append(id)
                placements.append(Placement(chipID: id, index: result.count - 1, reason: .tail))
            }
        }
        return ReconcileResult(order: result, placements: placements)
    }

    /// Rank placement: after the last card whose rank is not behind mine; if there is no such card, before the first card ranked further back;
    /// if no ranked card exists yet, land after the head-preferred zone (= to the right of messaging popup windows, to the left of ordinary temporary windows).
    private static func stableKeptInsertIndex(
        in result: [String],
        myRank: Int,
        rank: (String) -> Int?,
        appKeyOf: [String: String],
        headPreferredKeys: Set<String>
    ) -> Int {
        if let pos = result.lastIndex(where: { rank($0).map { $0 <= myRank } ?? false }) {
            return pos + 1
        }
        if let pos = result.firstIndex(where: { rank($0).map { $0 > myRank } ?? false }) {
            return pos
        }
        let headEnd = result.lastIndex { appKeyOf[$0].map(headPreferredKeys.contains) ?? false }
        return headEnd.map { $0 + 1 } ?? 0
    }

    /// Apply one drag drop: move `draggedID` to the left of `targetID` (`after == false`) or the right
    /// (`after == true`). If either id is not in the sequence, or the two are the same -> return unchanged.
    static func reordering(_ order: [String], move draggedID: String, relativeTo targetID: String, after: Bool) -> [String] {
        guard draggedID != targetID, order.contains(draggedID), order.contains(targetID) else { return order }
        var result = order
        result.removeAll { $0 == draggedID }
        guard let t = result.firstIndex(of: targetID) else { return order }
        result.insert(draggedID, at: after ? t + 1 : t)
        return result
    }

    /// Block placement (drawer dragged back to the task strip, exact drop point): move `ids` (keeping their given internal relative order) as a whole to the
    /// left (`after==false`) or right (`after==true`) of `targetID`; `targetID==nil` -> move the whole block to the **end** (append doesn't depend on
    /// reconcile's "new window sticks to companion / end" rule, which is exactly what this feature overrides). Moves only ids **already in `order`** (to prevent duplicate
    /// insertion); if `targetID` is within `ids` or not in `order` -> return unchanged.
    static func movingBlock(_ order: [String], move ids: [String], relativeTo targetID: String?, after: Bool) -> [String] {
        let idSet = Set(ids)
        let block = ids.filter { order.contains($0) }
        guard !block.isEmpty else { return order }
        var result = order.filter { !idSet.contains($0) }
        if let targetID {
            guard !idSet.contains(targetID), let t = result.firstIndex(of: targetID) else { return order }
            result.insert(contentsOf: block, at: after ? t + 1 : t)
        } else {
            result.append(contentsOf: block)
        }
        return result
    }

    /// Replace `oldID` with `newID`, **inheriting its position (rank)**. Used when: an app-\* placeholder upgrades to a real window,
    /// or a tab group's anchor migrates because a member closed. If `oldID` is not in the sequence, or `newID` is already in it (to prevent duplicates) -> return unchanged.
    static func substituting(_ order: [String], oldID: String, newID: String) -> [String] {
        guard order.contains(oldID), !order.contains(newID) else { return order }
        return order.map { $0 == oldID ? newID : $0 }
    }

    /// Persistence subset: keep `tabgrp-*` (real window seat keys) + those `app-*` that belong to kept apps (keeping icon position across this app's restarts).
    /// Ordinary app-* compatibility fallbacks still aren't persisted. Since 2026-08-20 Finder is also an ordinary kept app; while it is checked to keep,
    /// `app-com.apple.finder` gets persisted too (so it also has position memory from now on), and drops out of this subset naturally once unchecked.
    /// Across restarts the whole thing is discarded by the `kern.boottime` guard in `StripOrderStore`.
    static func persistableLiveOrder(_ order: [String], keptIDs: Set<String> = []) -> [String] {
        order.filter { id in
            if id.hasPrefix("tabgrp-") { return true }
            if id.hasPrefix("app-") {
                let bid = String(id.dropFirst(4))
                return keptIDs.contains(bid)
            }
            return false
        }
    }
}
