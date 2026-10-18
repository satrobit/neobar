import CoreGraphics
import Foundation

/// Drop-target routing for external files dragged onto the taskbar (pure functions, covered by unit tests).
///
/// All input coordinates are in the `"strip"` space — `onDrop` must be attached to **the same layer of view that defines that coordinate space**
/// (settled in review: the DropDelegate location and `geo.frame(in: .named("strip"))` must share one origin,
/// and must never be attached to the inner/outer layer after `.padding(shadowPadding)`). Only horizontal routing is done: anything dragged onto the taskbar counts as
/// the effective height, and the vertical hit is guaranteed by the layer onDrop is attached to.
enum StripDropRouting {
    /// Baseline for the mid tier. After the taskbar is scaled the caller passes `defaultHeadSlack * scale`.
    static let defaultHeadSlack: CGFloat = 8

    enum Target: Equatable {
        /// Dropped on the shelf cell → stage it (any file/folder, referenced rather than moved).
        case stash
        case trash
        /// Dropped on a pinned-folder chip → move the source into that folder.
        case moveInto(path: String)
        /// Dropped in the folder area → pin the directory at display-order position index (directories only; the caller filters).
        case pin(insertIndex: Int)
        /// What is dragged is an app bundle → check "Keep in Dock" + land at the cursor position. **The whole strip is its drop target**,
        /// with no index: the insertion position in the live area is computed by `StripBlockLanding` from `chipFrames` (see `handleExternalApplicationDrop`).
        case keepApp
        /// Anywhere else → reject.
        case none
    }

    /// - Parameters:
    ///   - location: the drop point ("strip" space).
    ///   - isApplicationDrag: whether this drag is an app bundle. **No default value**: forgetting to pass it would silently compile to
    ///     "apps take the file branch", which is exactly why this parameter exists — a `.app` is a directory in the file system,
    ///     `.moveInto` is a real file move / cross-volume copy, and would move the user's app out of "Applications".
    ///     It is a pure-function input rather than reading the disk here, so that this safety boundary can be unit-tested.
    ///   - isTrashItemDrag: every dragged URL is inside a Trash (`TrashPath`). **No default**, for
    ///     the same reason as `isApplicationDrag`: an omission would compile into "stash a reference
    ///     into the Trash" or "move a Trash item with our own file access". Checked before the app gate.
    ///   - shelfFrame: the shelf cell frame (reported through a separate PreferenceKey, **not mixed into folderFrames**).
    ///     **nil = the user turned the shelf cell off**. The caller must pass `showShelf ? frame : nil` straight from the setting,
    ///     and cannot wait for the PreferenceKey to clear the old frame — `ShelfFramePreferenceKey.reduce` deliberately ignores `.zero`,
    ///     so the old frame would stay, and after turning it off a drop at the old position would still be misjudged as `.stash`.
    ///   - folderFrames: folder chip frames (key = StripEntry id, i.e. "folder-<path>").
    ///   - orderedPaths: the current display order of pinned folders (PinnedFolderStore.folderPaths).
    ///   - headSlack: the slack **left of** the first folder that still counts as the folder area. It is the only drop target for "insert at position 0" —
    ///     the whole first chip is judged `.moveInto` first, so without this slack there would be no way to insert at the very front. When there are no folders yet,
    ///     it hangs off the left of the Trash and is the drop target for the first pin.
    ///   - tailSlack: the slack right of the last folder that still counts as the folder area. The Trash, when shown, sits right
    ///     after the zone and wins from its left edge on, so the slack only exists without it.
    ///   - pinEdgeFraction: the share of each chip's width, on both sides, that pins beside the chip
    ///     instead of moving into it. `0` keeps the whole chip a move-into target; a folders-only
    ///     drag (`dragPinsFolders`) passes `folderPinEdgeFraction`, or the only way to open the
    ///     make-way gap between two chips would be their 2pt spacing.
    ///   - openGap: the make-way gap currently open in the folder zone. It reports no frame, so at
    ///     either end of the zone its width has to be added to the slack — otherwise the pointer
    ///     resting inside the gap is outside the zone, the gap closes, and the two states loop.
    static func route(location: CGPoint,
                      isApplicationDrag: Bool,
                      isTrashItemDrag: Bool,
                      shelfFrame: CGRect?,
                      trashFrame: CGRect?,
                      folderFrames: [String: CGRect],
                      orderedPaths: [String],
                      headSlack: CGFloat = defaultHeadSlack,
                      tailSlack: CGFloat = 24,
                      pinEdgeFraction: CGFloat = 0,
                      openGap: OpenFolderGap? = nil) -> Target {
        // Trash items are refused everywhere on the bar, the Trash chip and app landing included.
        if isTrashItemDrag { return .none }

        // ⚠️ Safety gate, right after the Trash check: apps always go to keep, never to .moveInto / .pin / .stash.
        // The whole taskbar is its drop target — the user's intuition is "drag onto the Dock", so a drop in the window area must count.
        if isApplicationDrag { return .keepApp }

        if let trashFrame, trashFrame != .zero, location.x >= trashFrame.minX { return .trash }

        // The shelf is its own target, away from the folders (last cell of the pinned-app zone).
        if let shelfFrame {
            guard shelfFrame != .zero else { return .none }   // The shelf cell is open but its frame is not ready (first frame): do not accept
            if location.x >= shelfFrame.minX, location.x <= shelfFrame.maxX { return .stash }
        }

        let frames = orderedPaths.compactMap { folderFrames["folder-" + $0] }

        // Left edge of the folder area: headSlack left of the first folder. With no folders yet it falls back to the left edge of the Trash — the area contains only
        // the Trash, and the headSlack to its left is the only drop target for "drag a directory in to pin it for the first time". With neither →
        // the pinned area does not exist at all; reject.
        let trashMinX = trashFrame.flatMap { $0 != .zero ? $0.minX : nil }
        guard let zoneMinX = frames.map(\.minX).min() ?? trashMinX else { return .none }
        let headGap = openGap.map { $0.insertIndex <= 0 ? $0.width : 0 } ?? 0
        if location.x < zoneMinX - headSlack - headGap { return .none }

        // onDrop covers the effective height of the whole taskbar, and routing keeps its existing purely horizontal semantics; contains cannot be used,
        // otherwise the padding above and below a chip would unexpectedly fall back to pin.
        if let path = orderedPaths.first(where: { path in
            guard let frame = folderFrames["folder-" + path] else { return false }
            let edge = frame.width * min(max(pinEdgeFraction, 0), 0.5)
            return location.x >= frame.minX + edge && location.x <= frame.maxX - edge
        }) {
            return .moveInto(path: path)
        }

        let tailGap = openGap.map { $0.insertIndex >= frames.count ? $0.width : 0 } ?? 0
        guard location.x <= (frames.map(\.maxX).max() ?? zoneMinX) + tailSlack + tailGap else { return .none }

        // Insertion index = the number of folders whose midpoint is left of the drop point (dropped on the left half of a chip → insert before it).
        let index = orderedPaths.filter { path in
            guard let frame = folderFrames["folder-" + path] else { return false }
            return frame.midX < location.x
        }.count
        return .pin(insertIndex: index)
    }
}

/// The gap opened up by yielding space while hovering during a drag of an app or folder from Finder into the strip.
///
/// **What is stored is the insertion index, not "the left/right of which card"**, and this is load-bearing. Once the gap is inserted, every card to its right
/// shifts right by one card width; the next `dropUpdated` measures the frames after the shift. When the pointer rests in the gap,
/// the cards on its left and right are equidistant, and `StripBlockLanding` would oscillate between "right of the left neighbor" and "left of the right neighbor" —
/// these two **refer to the same empty slot**, but as an `(id, after)` tuple they are not equal. If the tuple were stored, the gate would
/// let through a stream of writes that "recompute the whole taskbar although the position did not change" (this repo measured "46 whole-strip recomputes in a 1.2-second drag").
/// Folding to an index normalizes the two phrasings, so the gate can actually hold.
struct StripDropGhost: Equatable {
    enum Zone: Equatable {
        /// An app dragged in: the gap opens among the live-zone cards.
        case live(bundleID: String)
        /// A folder dragged in: the gap opens among the pinned folders.
        case folder
    }
    let zone: Zone
    /// The position within the display order of its zone at which the gap is inserted (live-area cards / pinned folders; the shelf cell is not counted).
    let insertIndex: Int
}

extension StripDropRouting {
    /// Share of a folder chip's width, on each side, that pins beside it while a folder is dragged.
    static let folderPinEdgeFraction: CGFloat = 0.25

    /// The make-way gap open among the pinned folders, as `route` needs it.
    struct OpenFolderGap: Equatable {
        /// Position among the pinned folders (the shelf is not counted).
        let insertIndex: Int
        /// Layout width the gap adds: one card plus one chip spacing.
        let width: CGFloat
    }

    /// Whether a drag gets the folder-pin behaviour (gap, pin edges, no badge): every item that is
    /// not an app is a directory. One plain file among them keeps the old routing for the whole
    /// drag — on a chip's edge it would otherwise be left behind while the folders pin.
    static func dragPinsFolders(nonApplicationItemsAreDirectories: [Bool]) -> Bool {
        !nonApplicationItemsAreDirectories.isEmpty && nonApplicationItemsAreDirectories.allSatisfy { $0 }
    }

    /// The folder-zone gap for a hover target (pure, unit-tested). A pin target opens it at its
    /// index; a move-into target keeps the gap where it is — closing it would slide the chips back
    /// under a pointer that has not moved and hand the drop to the neighbour; anything else closes it.
    static func folderGhostIndex(current: Int?, target: Target, pinsFolder: Bool) -> Int? {
        guard pinsFolder else { return nil }
        switch target {
        case let .pin(insertIndex): return insertIndex
        case .moveInto: return current
        case .stash, .trash, .keepApp, .none: return nil
        }
    }

    /// Folds `StripBlockLanding`'s (anchor card, left/right) into an insertion index (pure function, covered by unit tests).
    /// If the anchor is not in the current display order (that card just disappeared / was filtered out by a display change) → land at the end, and never return an out-of-range index.
    static func ghostInsertionIndex(orderedIDs: [String], targetID: String?, after: Bool) -> Int {
        guard let targetID, let index = orderedIDs.firstIndex(of: targetID) else {
            return orderedIDs.count
        }
        return after ? index + 1 : index
    }

    /// Whether the strip answers a drag with the generic operation (no cursor badge) instead of
    /// SwiftUI's `.copy` (the green plus). Over the Trash, where NeoBar moves the file
    /// itself, and over a pin slot while a folder is dragged, where nothing is copied at all:
    /// `.copy` reads as "a copy goes in", and `.move` is never an option — it tells the source
    /// the item left, and Finder deletes an app it dragged in. A source that does not offer generic
    /// (e.g. ⌥ held) keeps `.copy`.
    static func usesGenericOperation(hoveredTarget: Target?, pinsFolder: Bool,
                                     proposedIsCopy: Bool, sourceAllowsGeneric: Bool) -> Bool {
        guard proposedIsCopy, sourceAllowsGeneric else { return false }
        switch hoveredTarget {
        case .trash, .keepApp: return true
        case .pin: return pinsFolder
        default: return false
        }
    }

    /// Whether the drop turns off the system's "drag image flies to its destination" animation.
    /// SwiftUI's destination switches `animatesToDestination` on in `prepareForDragOperation:`, and
    /// with the item frame left where the pointer is, the drag image just hangs there ~0.4s after
    /// release while the landed icon grows under it. An app landing has its own entrance, as on the
    /// native Dock, so it turns it off; every other target keeps SwiftUI's behaviour.
    static func suppressesSystemDropAnimation(hoveredTarget: Target?) -> Bool {
        hoveredTarget == .keepApp
    }

    /// Whether an app drag may widen the bar while it hovers (the native Dock grows and re-centres).
    /// Conservative: true only when the landing is sure to add a launcher placeholder, which every
    /// strip shows. Anything already on the bar or in the messaging zone would make the bar grow
    /// while hovering and shrink back on landing; a running app usually has a card already (maybe on
    /// another screen). A stopped app in the drawer does widen: the drop moves it out onto the bar.
    /// `false` does not mean nothing is added — only that the bar keeps its width until the landing.
    static func appDropMayWidenOnHover(isRunning: Bool, isMessaging: Bool,
                                       isFinder: Bool, hasEntryOnStrip: Bool) -> Bool {
        !(isRunning || isMessaging || isFinder || hasEntryOnStrip)
    }

    /// The URLs a drop commits. The item providers are the authority; only when **none** of them
    /// yields a URL does the drop fall back to the drag pasteboard snapshot — an in-process drag
    /// (our folder / shelf popup) may not coerce to `URL` at all.
    /// Trash items are dropped from either source (second gate; the first is the hover route).
    static func committedURLs(loaded: [URL?], pasteboard: [URL], homeDirectory: URL) -> [URL] {
        let resolved = loaded.compactMap { $0 }
        return (resolved.isEmpty ? pasteboard : resolved)
            .filter { !TrashPath.isInsideTrash($0, homeDirectory: homeDirectory) }
    }
}
