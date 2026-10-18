import AppKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers

/// One slot in the strip: a concrete window chip, an app-level leading entry,
/// a pinned folder/shelf entry, or a zone divider.
enum StripEntry: Identifiable, Hashable {
    case window(StripItem)
    /// Constant app-icon chip for a pinned messaging app. Carries the main window's
    /// StripItem when it exists (the chip then *is* that window: toggle + full window
    /// menu); when the main window is gone, tap sends a reopen (Dock-icon-click
    /// equivalent) so the app recreates it — verified to work for WeChat even with
    /// other chat windows visible.
    case messagingApp(bundleID: String, mainWindow: StripItem?)
    /// Apps set to "Keep in Dock": while running they show window cards as usual; after quitting they collapse into a single app icon that stays in place.
    /// The id is always "app-\(bid)" — the same string as the windowless fallback token in AppTracker rebuildSnapshot(),
    /// which is what keeps the live order continuous across quit ↔ placeholder switches.
    case keptApp(bundleID: String)
    /// One cell of the pinned-folders area (right of the window area, right next to the left of the Trash, in the same zone as the Trash with no separator between them). The path is the identity.
    case pinnedFolder(path: String)
    /// Shelf cell: the staging cell at the far right of the pinned-apps area (messaging area), in the same group as that area and sharing the separator after it; not draggable.
    case shelf
    case trash
    /// Visual separator between zones. There are now at most two (messaging + shelf cell | windows, windows | folders + Trash); ids must be unique.
    case divider(id: String)
    /// The **gap** opened up by yielding space while hovering during a drag of an app or folder from Finder into the strip (one card wide, drawing nothing).
    /// `key` only makes the id: the app's bundle id in the live zone, `"folder"` among the pinned folders.
    ///
    /// Pure render artifact: does not enter `liveOrderIDs` / `appKeyByChipID` (the ordering layer remembering a ghost id would keep an absence anchor for it),
    /// does not report `ChipFramePreferenceKey` (`chipFrames` is the input of the drop decision `StripBlockLanding` itself, and
    /// a gap entering it would anchor to itself and jitter whenever the pointer moves) or `FolderChipFramePreferenceKey`, and also reports no hover frame,
    /// and attaches no menu or gestures. It is injected **after** the ordering layer and the multi-display filter in `makeProjection` (same rule as the multi-display filter).
    ///
    /// No semi-transparent icon copy is drawn: during a system drag, macOS already draws that app's icon under the cursor,
    /// and drawing another would give two icons; the native Dock is likewise "system drag image + gap".
    case externalDropGhost(key: String)

    var id: String {
        switch self {
        case let .window(item): return item.id
        // Stable id regardless of main-window presence, so the chip doesn't churn
        // when the main window opens/closes.
        case let .messagingApp(bid, _): return "msg-app-\(bid)"
        case let .keptApp(bid): return "app-\(bid)"
        case let .pinnedFolder(path): return "folder-\(path)"
        case .shelf: return "shelf"
        case .trash: return "trash"
        case let .divider(id): return id
        case let .externalDropGhost(key): return "extghost-\(key)"
        }
    }
}

struct StripProjection {
    let snapshotItems: [StripItem]
    let snapshotBundleIDs: Set<String>
    let hiddenBundleIDs: Set<String>
    let messaging: [StripEntry]
    let liveNatural: [StripEntry]
    let liveOrderIDs: [String]
    let appKeyByChipID: [String: String]
    /// The label each window card finally shows (app-name suffix removed + common segment of the group removed, issue #41).
    /// Computed from **the cards actually shown on this bar**, so it can only come from the projection layer and cannot be computed inside `StripItem`.
    let labelTitleByChipID: [String: String]
    let entries: [StripEntry]
    let layoutKeys: [StripLayoutKey]
    let messagingIDs: [String]
    let draggingID: String?
    /// The entry id of the **leftmost** card of each app in the regular area — the unread badge is drawn only on this one
    /// (one unread count must not become three red dots). Messaging-area members are not here: their badges are drawn on the icon in that area.
    let badgeEntryIDByBundle: [String: String]
    /// Chips that draw the front-window bar this round (`FrontWindowIndicatorDecision`).
    let frontWindowChipIDs: Set<String>

    func hasRealWindow(bundleID: String) -> Bool {
        snapshotItems.contains {
            $0.bundleIdentifier == bundleID && !$0.isAppLevelFallback
        }
    }

    func item(forID id: String) -> StripItem? {
        guard let entry = liveNatural.first(where: { $0.id == id }),
              case let .window(item) = entry else { return nil }
        return item
    }

    func liveChipIDs(bundleID: String) -> [String] {
        entries.compactMap { entry -> String? in
            guard case let .window(item) = entry,
                  item.bundleIdentifier == bundleID,
                  !item.isAppLevelFallback else { return nil }
            return item.id
        }
    }

    /// **All cards** of the app that occupy a slot in the live area, in display order, **not excluding the app-level fallback card or the `.keptApp` placeholder**.
    ///
    /// This is a different rule from `liveChipIDs`; do not merge them: that one answers "which window card should the carrier draw",
    /// this one answers "which card on the strip should yield space". The fallback card and the placeholder card cannot be drawn as a carrier, but they genuinely occupy a slot —
    /// earlier, both questions shared the former rule, so the `keepPlacement` path never yielded space (double ghost, owner 2026-08-18).
    func liveEntryIDs(bundleID: String) -> [String] {
        entries.compactMap { entry -> String? in
            switch entry {
            case let .window(item):
                return item.bundleIdentifier == bundleID ? item.id : nil
            case let .keptApp(bid):
                return bid == bundleID ? entry.id : nil
            default:
                return nil
            }
        }
    }
}

// MARK: - Messaging zone diagnostics

/// Permanent diagnostic for the abnormal path (like `[tabfold]`: zero output on the normal path with a single, recognizable window): when a messaging-area member **cannot identify its main window**,
/// or **has more than one real window** (in which case "which one got picked" is itself what needs investigating), log one line with each window of this app
/// (id + raw title), the main window picked, and the spellings the name table currently recognizes. De-duplicated by signature — the same set of windows + the same
/// conclusion is logged only once, and again only on change. It uses `Logger` rather than `print`: stdout of a build launched via `open` is
/// discarded, while `log show --predicate 'category == "MessagingZone"'` can read it any time afterwards (only notice level is persisted).
///
/// Added 2026-08-23: the owner reported "one card in the messaging area and one card in the regular area for WeChat", and the debug console window was half off-screen,
/// so three rounds of follow-up could not tell whether "the title is not WeChat" or "the name table did not recognize WeChat" — with this line it would be known on the spot.
enum MessagingZoneDiagnostics {
    private static let logger = Logger(subsystem: "app.neobar.NeoBar", category: "MessagingZone")
    private static let lock = NSLock()
    private static var lastSignatureByBundle: [String: String] = [:]

    static func record(bundleID: String, windows: [StripItem], mainID: String?) {
        let described = windows.map { "\($0.id):\($0.title.isEmpty ? "<empty>" : $0.title)" }
        let signature = described.joined(separator: "|") + "→" + (mainID ?? "none")
        lock.lock()
        let unchanged = lastSignatureByBundle[bundleID] == signature
        if !unchanged { lastSignatureByBundle[bundleID] = signature }
        lock.unlock()
        guard !unchanged else { return }
        let known = AppDisplayNameResolver.knownAppNames(for: bundleID).sorted().joined(separator: ", ")
        // notice rather than info: info level is not persisted by default, so `log show` cannot read it afterwards (only `log stream` can see it live).
        logger.notice("[msgmain] bid=\(bundleID, privacy: .public) windows=[\(described.joined(separator: ", "), privacy: .public)] known=[\(known, privacy: .public)] main=\(mainID ?? "none", privacy: .public)")
    }
}

// MARK: - Layout Animation Key

struct StripLayoutKey: Equatable {
    let id: String
    let form: Form

    enum Form: Equatable { case zero, single, multi, launcher }

    init(_ entry: StripEntry) {
        id = entry.id
        switch entry {
        case let .window(item):
            if item.isAppLevelFallback { form = .zero }
            else if item.showsTitle    { form = .multi }
            else                        { form = .single }
        case .messagingApp:
            form = .launcher    // both states render as a fixed-size icon chip
        case .keptApp:
            form = .launcher    // fixed-size kept-app icon chip
        case .pinnedFolder:
            form = .launcher    // fixed-size folder chip
        case .shelf, .trash:
            form = .launcher    // fixed-size shelf chip
        case .divider:
            form = .launcher    // fixed-size separator, no animation form change
        case .externalDropGhost:
            form = .launcher    // One card wide, same shape as the keep placeholder
        }
    }
}
