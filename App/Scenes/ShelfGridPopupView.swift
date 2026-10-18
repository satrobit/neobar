import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The shelf's popup: the parked files in the same chrome and cells as the folder popup
/// (`StackPopupChrome` / `FolderGridCell`), but with no drill-in, no "Open in Finder" tail cell and
/// no directory watcher — the source is `ShelfStore`'s path list (newest first; pruned by the
/// coordinator before the popup shows). Cells drag out as real files; their menu adds
/// "Remove from Shelf", and trashing one removes it from the shelf too.
struct ShelfGridPopupView: View {
    @ObservedObject var shelfStore: ShelfStore
    let context: StackPopupContext
    /// Explicit, no default: every panel is its own hosting root (`AGENTS.md` no-default rule).
    let usesLiquidGlass: Bool
    var onClosePopup: () -> Void = {}
    var onContentResize: (CGSize) -> Void = { _ in }
    var onPinFolder: ((URL) -> Void)?
    var isFolderPinned: ((URL) -> Bool)?

    var body: some View {
        // File attributes are read once per render in shelf order (the shelf is small; the
        // coordinator pruned it before showing the popup).
        let entries = FolderContentsLoader.entries(forPaths: shelfStore.itemPaths)
        let note = Self.note(for: entries)
        // An empty shelf is the status line alone: no row of blank cells under it.
        let layout = entries.isEmpty
            ? StackGridLayout.Result(columns: StackGridLayout.noteMinColumns, visibleRows: 0, scrolls: false)
            : StackGridLayout.resolve(cellCount: entries.count, limits: context.limits, hasNote: note != nil)

        StackPopupChrome(title: String(localized: "Shelf"),
                         note: note,
                         layout: layout,
                         plate: .stack,
                         usesLiquidGlass: usesLiquidGlass,
                         appearance: .followsAppearance,
                         arrow: context.arrow,
                         onPanelSizeChange: onContentResize,
                         gridAnimation: .easeInOut(duration: DrawerAnimation.duration),
                         gridAnimationKey: entries.map(\.url.path)) {
            ForEach(entries, id: \.url) { entry in
                FolderGridCell(iconPath: entry.isAccessible ? entry.url.path : nil,
                               staticIcon: entry.isAccessible ? nil : Self.inaccessibleIcon,
                               label: entry.name,
                               preview: entry.isAccessible && !entry.isDirectory ? .init(stamp: entry.dateModified) : nil,
                               dragURL: entry.isAccessible ? entry.url : nil,
                               contextMenu: { cellMenu(for: entry) }) {
                    // The shelf never drills in: a click opens (a folder opens in Finder).
                    NSWorkspace.shared.open(entry.url)
                    onClosePopup()
                }
            }
        }
    }

    private static func note(for entries: [FolderContentsLoader.Entry]) -> String? {
        if entries.isEmpty { return String(localized: "Drag files here to park them") }
        // Kept, not pruned: the file exists but its folder's privacy permission is missing.
        if entries.contains(where: { !$0.isAccessible }) {
            return String(localized: "Some items can’t be accessed. Allow NeoBar to access their folder in your Mac’s privacy settings.")
        }
        return nil
    }

    private static let inaccessibleIcon = NSWorkspace.shared.icon(for: .data)

    private func cellMenu(for entry: FolderContentsLoader.Entry) -> NSMenu {
        let canPin = entry.isDirectory && !(isFolderPinned?(entry.url) ?? true)
        let path = entry.url.path
        return FileItemMenuBuilder.menu(for: .init(
            url: entry.url,
            isDirectory: entry.isDirectory,
            closePopup: onClosePopup,
            pinFolder: canPin ? { onPinFolder?(entry.url) } : nil,
            removeFromShelf: { shelfStore.remove(path) },
            onTrashed: { shelfStore.remove(path) }
        ))
    }
}
