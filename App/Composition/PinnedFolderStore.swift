import Foundation

/// Persistence layer for the pinned-folders area: an ordered list of folder paths (order is the display order; drag-reorder and drop-to-pin both modify this array).
/// The app is not sandboxed, so storing normalized bare paths is enough; no security-scoped bookmark is needed.
@MainActor
final class PinnedFolderStore: ObservableObject {
    @Published private(set) var folderPaths: [String] = []
    /// Per-folder sort order (normalized path → FolderSortOrder.rawValue). Absent = default order, not persisted.
    @Published private(set) var sortOrders: [String: String] = [:]
    /// Per-folder "Display as" (normalized path → FolderDisplayMode.rawValue). Absent = stack.
    @Published private(set) var displayModes: [String: String] = [:]
    /// Per-folder "View content as" (normalized path → FolderViewMode.rawValue). Absent = automatic.
    @Published private(set) var viewModes: [String: String] = [:]
    /// Pinned by us, not by the user, and not opened yet: nothing may read such a folder (no cover
    /// enumeration, no watcher), or a privacy-protected one — Downloads — raises the system's
    /// access prompt at first launch with no user action behind it. Cleared by the first open.
    private(set) var unopenedSeedPaths: Set<String> = []
    private let defaults: UserDefaults
    private let key = "pinnedFolderPaths"
    private let sortKey = "pinnedFolderSortOrders"
    private let displayModeKey = "pinnedFolderDisplayModes"
    private let viewModeKey = "pinnedFolderViewModes"
    private let unopenedSeedKey = "pinnedFolderUnopenedSeeds"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        folderPaths = defaults.stringArray(forKey: key) ?? []
        sortOrders = defaults.dictionary(forKey: sortKey) as? [String: String] ?? [:]
        displayModes = defaults.dictionary(forKey: displayModeKey) as? [String: String] ?? [:]
        viewModes = defaults.dictionary(forKey: viewModeKey) as? [String: String] ?? [:]
        unopenedSeedPaths = Set(defaults.stringArray(forKey: unopenedSeedKey) ?? [])
    }

    /// A fresh install starts with Downloads pinned, as the native Dock does. Fresh is decided by
    /// `InstallLineage` only (AGENTS.md): an upgrader who never pinned a folder has no key either.
    func seedDownloadsForFreshInstall(lineage: InstallLineage,
                                      downloadsURL: URL? = FileManager.default.urls(for: .downloadsDirectory,
                                                                                    in: .userDomainMask).first) {
        guard lineage == .pristine,
              defaults.object(forKey: key) == nil,
              let downloads = downloadsURL
        else { return }
        // Before `add`: its publication is what makes the cover store look at the folder.
        setUnopenedSeeds([Self.normalized(downloads.path)])
        add(downloads.path)
    }

    func isUnopenedSeed(_ path: String) -> Bool { unopenedSeedPaths.contains(Self.normalized(path)) }

    /// The user opened the folder: from here on it is read like any other. Returns whether it
    /// was an unopened seed, so the caller knows to refresh its cover.
    @discardableResult
    func noteOpened(_ path: String) -> Bool {
        guard isUnopenedSeed(path) else { return false }
        setUnopenedSeeds(unopenedSeedPaths.subtracting([Self.normalized(path)]))
        return true
    }

    private func setUnopenedSeeds(_ paths: Set<String>) {
        unopenedSeedPaths = paths
        defaults.set(paths.sorted(), forKey: unopenedSeedKey)
    }

    func contains(_ path: String) -> Bool { folderPaths.contains(Self.normalized(path)) }

    func add(_ path: String) {
        let normalized = Self.normalized(path)
        guard !normalized.isEmpty, !folderPaths.contains(normalized) else { return }
        folderPaths.append(normalized)
        persist()
    }

    /// Drop-to-pin: insert at display-order position index. An already-pinned path is moved to the new position (Dock semantics: dragging it in again just reorders).
    func insert(_ path: String, at index: Int) {
        let normalized = Self.normalized(path)
        guard !normalized.isEmpty else { return }
        var next = folderPaths
        var target = min(max(0, index), next.count)
        if let existing = next.firstIndex(of: normalized) {
            next.remove(at: existing)
            if existing < target { target -= 1 }
        }
        next.insert(normalized, at: min(target, next.count))
        guard next != folderPaths else { return }
        folderPaths = next
        persist()
    }

    /// In-area drag reorder: move draggedPath to the left/right of targetPath (reuses the StripOrdering pure function).
    func reorder(draggedPath: String, relativeTo targetPath: String, after: Bool) {
        let next = StripOrdering.reordering(folderPaths,
                                            move: Self.normalized(draggedPath),
                                            relativeTo: Self.normalized(targetPath),
                                            after: after)
        guard next != folderPaths else { return }
        folderPaths = next
        persist()
    }

    func remove(_ path: String) {
        let normalized = Self.normalized(path)
        folderPaths.removeAll { $0 == normalized }
        if unopenedSeedPaths.contains(normalized) { setUnopenedSeeds(unopenedSeedPaths.subtracting([normalized])) }
        if sortOrders.removeValue(forKey: normalized) != nil {
            defaults.set(sortOrders, forKey: sortKey)
        }
        if displayModes.removeValue(forKey: normalized) != nil {
            defaults.set(displayModes, forKey: displayModeKey)
        }
        if viewModes.removeValue(forKey: normalized) != nil {
            defaults.set(viewModes, forKey: viewModeKey)
        }
        persist()
    }

    func sortOrder(for path: String) -> FolderSortOrder {
        FolderSortOrder(rawValue: sortOrders[Self.normalized(path)] ?? "") ?? .default
    }

    func setSortOrder(_ order: FolderSortOrder, for path: String) {
        let normalized = Self.normalized(path)
        guard sortOrders[normalized] != order.rawValue else { return }
        sortOrders[normalized] = order.rawValue
        defaults.set(sortOrders, forKey: sortKey)
    }

    func displayMode(for path: String) -> FolderDisplayMode {
        FolderDisplayMode(rawValue: displayModes[Self.normalized(path)] ?? "") ?? .default
    }

    func setDisplayMode(_ mode: FolderDisplayMode, for path: String) {
        let normalized = Self.normalized(path)
        guard displayModes[normalized] != mode.rawValue else { return }
        displayModes[normalized] = mode.rawValue
        defaults.set(displayModes, forKey: displayModeKey)
    }

    func viewMode(for path: String) -> FolderViewMode {
        FolderViewMode(rawValue: viewModes[Self.normalized(path)] ?? "") ?? .default
    }

    func setViewMode(_ mode: FolderViewMode, for path: String) {
        let normalized = Self.normalized(path)
        guard viewModes[normalized] != mode.rawValue else { return }
        viewModes[normalized] = mode.rawValue
        defaults.set(viewModes, forKey: viewModeKey)
    }

    private func persist() {
        defaults.set(folderPaths, forKey: key)
    }

    /// Normalize: expand ~ / collapse .. and strip the trailing slash, so the same folder is pinned only once.
    static func normalized(_ path: String) -> String {
        FilePathNormalization.normalized(path)
    }
}
