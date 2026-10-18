import AppKit

/// A pinned folder's list view: a real `NSMenu` in the Dock's tipped bubble, as the native Dock
/// shows it. Files open on click; subfolders cascade and read their contents the first time they
/// open; "Options" holds the folder's three settings; "Open in Finder" closes the list.
@MainActor
final class StackPopupListMenu: NSObject, NSMenuDelegate {
    struct Actions {
        let setSortOrder: (FolderSortOrder) -> Void
        let setDisplayMode: (FolderDisplayMode) -> Void
        let setViewMode: (FolderViewMode) -> Void
    }

    let menu = NSMenu()
    private let sortOrder: FolderSortOrder
    /// Subfolder submenus not read yet, keyed by the submenu object.
    private var pendingSubmenus: [ObjectIdentifier: URL] = [:]

    init(rootURL: URL,
         entries: [FolderContentsLoader.Entry]?,
         sortOrder: FolderSortOrder,
         displayMode: FolderDisplayMode,
         viewMode: FolderViewMode,
         actions: Actions) {
        self.sortOrder = sortOrder
        super.init()
        menu.autoenablesItems = false
        fill(menu, directory: rootURL, entries: entries)
        menu.addItem(.separator())
        let options = NSMenuItem(title: String(localized: "Options"), action: nil, keyEquivalent: "")
        options.submenu = Self.optionsMenu(sortOrder: sortOrder, displayMode: displayMode,
                                           viewMode: viewMode, actions: actions)
        menu.addItem(options)
        menu.addItem(ClosureMenuItem(String(localized: "Open in Finder")) {
            NSWorkspace.shared.open(rootURL)
        })
    }

    /// Where the bubble's tip goes for a chip: the native tip sits ~3pt above the icon's top.
    static func tipRect(forChip chip: CGRect, scale: CGFloat) -> CGRect {
        let side = ChipPillMetrics.bareIconVisibleSlot * scale
        let icon = CGRect(x: chip.midX - side / 2, y: chip.midY - side / 2, width: side, height: side)
        return CGRect(x: icon.minX, y: icon.minY, width: icon.width, height: icon.height + tipGap)
    }

    private static let tipGap: CGFloat = 3

    /// Tracks modally until the menu closes. The Dock's own bubble comes from a private AppKit
    /// call; without it the plain menu opens above the chip, without a tip.
    func popUp(relativeTo rect: NSRect, in view: NSView) {
        let selector = NSSelectorFromString("_popUpMenuRelativeToRect:inView:preferredEdge:")
        if menu.responds(to: selector) {
            typealias PopUp = @convention(c) (AnyObject, Selector, NSRect, NSView, NSRectEdge) -> Void
            let popUp = unsafeBitCast(menu.method(for: selector), to: PopUp.self)
            // The private call reads the edge flipped: `.minY` puts the bubble above the rect.
            popUp(menu, selector, rect, view, .minY)
        } else {
            let height = menu.size.height
            let top = view.isFlipped ? rect.minY - height : rect.maxY + height
            menu.popUp(positioning: nil, at: NSPoint(x: rect.midX - menu.size.width / 2, y: top), in: view)
        }
    }

    func cancelTracking() {
        menu.cancelTracking()
    }

    // MARK: Building

    private func fill(_ menu: NSMenu, directory: URL, entries: [FolderContentsLoader.Entry]?) {
        let listing = FolderListMenuPlan.listing(entries: entries) { entry in
            FolderListMenuPlan.isSubfolder(entry) { url in Self.aliasTargetIsFolder(url) }
        }
        switch listing {
        case .timedOut:
            menu.addItem(Self.moreItem())
            menu.addItem(ClosureMenuItem(String(localized: "Open in Finder")) {
                NSWorkspace.shared.open(directory)
            })
        case let .rows(rows):
            for row in rows {
                switch row {
                case let .file(entry):
                    let item = ClosureMenuItem(entry.name) { NSWorkspace.shared.open(entry.url) }
                    Self.setIcon(of: item, for: entry.url)
                    menu.addItem(item)
                case let .subfolder(entry):
                    let item = NSMenuItem(title: entry.name, action: nil, keyEquivalent: "")
                    Self.setIcon(of: item, for: entry.url)
                    let submenu = NSMenu(title: entry.name)
                    submenu.autoenablesItems = false
                    submenu.delegate = self
                    pendingSubmenus[ObjectIdentifier(submenu)] = entry.isAlias
                        ? (try? URL(resolvingAliasFileAt: entry.url, options: [.withoutUI, .withoutMounting])) ?? entry.url
                        : entry.url
                    item.submenu = submenu
                    menu.addItem(item)
                case .more:
                    menu.addItem(Self.moreItem())
                }
            }
        }
    }

    /// A submenu reads its directory the first time it opens: only files and deeper subfolders,
    /// no "Options" or "Open in Finder" of its own (measured).
    func menuNeedsUpdate(_ submenu: NSMenu) {
        guard let url = pendingSubmenus.removeValue(forKey: ObjectIdentifier(submenu)) else { return }
        let entries = FolderContentsLoader.preload(url: url, timeout: 0.15, order: sortOrder)
        submenu.removeAllItems()
        fill(submenu, directory: url, entries: entries)
    }

    private static func moreItem() -> NSMenuItem {
        let item = NSMenuItem(title: "...", action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private static func optionsMenu(sortOrder: FolderSortOrder, displayMode: FolderDisplayMode,
                                    viewMode: FolderViewMode, actions: Actions) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(PinnedFolderChip.sectionHeader(String(localized: "Sort by")))
        for order in FolderSortOrder.allCases {
            let item = ClosureMenuItem(order.menuTitle) { actions.setSortOrder(order) }
            item.state = order == sortOrder ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(PinnedFolderChip.sectionHeader(String(localized: "Display as")))
        for mode in FolderDisplayMode.allCases {
            let item = ClosureMenuItem(mode.menuTitle) { actions.setDisplayMode(mode) }
            item.state = mode == displayMode ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(PinnedFolderChip.sectionHeader(String(localized: "View content as")))
        for mode in FolderViewMode.allCases {
            let item = ClosureMenuItem(mode.menuTitle) { actions.setViewMode(mode) }
            item.state = mode == viewMode ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    /// 16 × 16, as the native list draws them. A shared cached image is copied before resizing.
    /// macOS 27 hides menu item images unless an item asks for its image to show.
    private static func setIcon(of item: NSMenuItem, for url: URL) {
        let source = FolderIconResolver.cached(url.path) ?? NSWorkspace.shared.icon(forFile: url.path)
        let image = (source.copy() as? NSImage) ?? source
        image.size = NSSize(width: 16, height: 16)
        item.image = image
        // The property only exists in the macOS 27 SDK (Swift 6.4); CI still builds with Xcode 26.
        #if compiler(>=6.4)
        if #available(macOS 27.0, *) { item.preferredImageVisibility = .visible }
        #endif
    }

    private static func aliasTargetIsFolder(_ url: URL) -> Bool {
        guard let target = try? URL(resolvingAliasFileAt: url, options: [.withoutUI, .withoutMounting]),
              let values = try? target.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]) else { return false }
        return values.isDirectory == true && values.isPackage != true
    }
}
