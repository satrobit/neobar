import AppKit
import QuickLookThumbnailing

/// A pinned folder chip's cover: the first items of the folder's current sort, stacked like a
/// native Dock stack (front first). Enumeration runs on a background queue; each folder carries
/// a generation counter and an async Quick Look result publishes only while it is unchanged, so
/// a stale thumbnail cannot overwrite a fresh cover. `@Published` is written on the MainActor only.
struct FolderCover: Equatable {
    struct Layer: Equatable {
        var image: NSImage
        /// A real Quick Look thumbnail (drawn at its own aspect with a hairline) rather than an
        /// icon, which carries its own transparent margin.
        var isThumbnail: Bool
    }
    /// Front first. Empty = the folder's own icon, drawn at full icon size like the native Dock's
    /// empty stack — not as a one-layer pile, whose front-layer geometry shrinks and lowers it.
    var layers: [Layer]
}

@MainActor
final class PinnedFolderCoverStore: ObservableObject {
    /// path → cover. Per layer: Quick Look thumbnail → the item's icon; an empty folder shows its own icon.
    @Published private(set) var covers: [String: FolderCover] = [:]

    private struct CacheEntry {
        let order: FolderSortOrder
        let entries: [FolderContentsLoader.Entry]
    }
    /// Full folder contents proactively pre-read and cached in the background, dedicated to zero-latency extraction by popups. Hot cache first; no @Published to avoid unnecessary global redraws.
    private var cache: [String: CacheEntry] = [:]

    private var watchers: [String: DirectoryWatcher] = [:]
    private var generations: [String: Int] = [:]
    /// One counter for all folders, never reset: a per-folder count restarts at 1 when a folder
    /// is unpinned and pinned again, and a callback from before would pass the check.
    private var lastGeneration = 0
    /// coverFilePath|modDate -> thumbnail; if the cover file hasn't changed it isn't regenerated.
    private let thumbnailCache = NSCache<NSString, NSImage>()
    /// Per-folder sort order (injected by AppDelegate, reads PinnedFolderStore): the cover = the first few items under the current sort order,
    /// consistent with the popup grid (same as native Stacks: change the sort and the chip cover changes with it).
    private let sortOrderProvider: (String) -> FolderSortOrder
    /// `PinnedFolderStore.isUnopenedSeed`: such a folder shows its plain icon and is not read or
    /// watched until the user opens it (reading Downloads raises the system's access prompt).
    private let isUnopenedSeed: (String) -> Bool

    init(sortOrderProvider: @escaping (String) -> FolderSortOrder = { _ in .default },
         isUnopenedSeed: @escaping (String) -> Bool = { _ in false }) {
        self.sortOrderProvider = sortOrderProvider
        self.isUnopenedSeed = isUnopenedSeed
    }

    /// Extract a hot cache that hits and has a matching sort order. If nil, the caller should run a synchronous preload as a fallback.
    func cachedEntries(for path: String, order: FolderSortOrder) -> [FolderContentsLoader.Entry]? {
        guard let entry = cache[path], entry.order == order else { return nil }
        return entry.entries
    }

    /// Reconcile with PinnedFolderStore.folderPaths: add or remove watchers as needed, and refresh all covers once.
    func sync(paths: [String]) {
        let wanted = Set(paths)
        for gone in Array(watchers.keys) where !wanted.contains(gone) {
            watchers[gone]?.stop()
            watchers[gone] = nil
            covers[gone] = nil
            cache[gone] = nil
            generations[gone] = nil
        }
        for path in paths {
            if isUnopenedSeed(path) {
                covers[path] = FolderCover(layers: [])
                continue
            }
            if watchers[path] == nil {
                // The DirectoryWatcher callback is already on the main thread; wrap it in a Task to go through MainActor isolation.
                watchers[path] = DirectoryWatcher(path: path) { [weak self] in
                    Task { @MainActor [weak self] in self?.refresh(path: path) }
                }
            }
            refresh(path: path)
        }
    }

    private func refresh(path: String) {
        lastGeneration += 1
        let generation = lastGeneration
        generations[path] = generation
        let folderURL = URL(fileURLWithPath: path)
        let order = sortOrderProvider(path)   // Read it on the MainActor; the background block uses the value

        Task.detached(priority: .utility) { [weak self] in
            let entries = (try? FolderContentsLoader.load(directory: folderURL)) ?? []
            let sortedEntries = FolderContentsLoader.sorted(entries, by: order)
            let stack = FolderContentsLoader.coverEntries(in: sortedEntries)
            await MainActor.run { [weak self] in
                guard let self, self.generations[path] == generation else { return }
                self.cache[path] = CacheEntry(order: order, entries: sortedEntries)
                self.publishCover(path: path, stack: stack, generation: generation)
            }
        }
    }

    private func publishCover(path: String, stack: [FolderContentsLoader.Entry], generation: Int) {
        guard !stack.isEmpty else {
            covers[path] = FolderCover(layers: [])
            return
        }
        var pending: [(index: Int, url: URL, cacheKey: String)] = []
        let layers = stack.enumerated().map { index, entry -> FolderCover.Layer in
            // Folders (and bundles) keep their icon, as on a native stack.
            guard !entry.isDirectory else {
                return .init(image: Self.icon(forPath: entry.url.path), isThumbnail: false)
            }
            let cacheKey = "\(entry.url.path)|\(entry.dateModified?.timeIntervalSince1970 ?? 0)"
            if let cached = thumbnailCache.object(forKey: cacheKey as NSString) {
                return .init(image: cached, isThumbnail: true)
            }
            // The file's icon stands in until its Quick Look thumbnail arrives.
            pending.append((index, entry.url, cacheKey))
            return .init(image: Self.icon(forPath: entry.url.path), isThumbnail: false)
        }
        covers[path] = FolderCover(layers: layers)

        for (index, url, cacheKey) in pending {
            let request = QLThumbnailGenerator.Request(
                fileAt: url,
                size: CGSize(width: 64, height: 64),
                scale: 2,
                representationTypes: .thumbnail
            )
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
                guard let cgImage = representation?.cgImage else { return }  // keep the icon on failure
                let image = NSImage(cgImage: cgImage, size: .zero)
                Task { @MainActor [weak self] in
                    guard let self, self.generations[path] == generation,
                          var cover = self.covers[path], cover.layers.indices.contains(index) else { return }
                    self.thumbnailCache.setObject(image, forKey: cacheKey as NSString)
                    cover.layers[index] = .init(image: image, isThumbnail: true)
                    self.covers[path] = cover
                }
            }
        }
    }

    /// NSWorkspace icons are shared cache objects; you must `.copy()` before changing size (same convention as AppMenuFragments).
    static func icon(forPath path: String) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: path)
        guard let copy = icon.copy() as? NSImage else { return icon }
        copy.size = NSSize(width: 64, height: 64)
        return copy
    }
}
