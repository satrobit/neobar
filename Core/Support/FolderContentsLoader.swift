import Foundation
import UniformTypeIdentifiers

/// Sort order for pinned-folder popups/covers (matches the native Stacks "Sort by"). rawValue is persisted
/// (`PinnedFolderStore.sortOrders`, path → rawValue). Declaration order is the menu display order.
enum FolderSortOrder: String, CaseIterable {
    case name
    case dateAdded      // Default: date added, newest first (the same ordering as the old version)
    case dateModified   // Date modified, newest first
    case dateCreated    // Date Created, newest first; sits after Date Modified as on the native Dock
    case kind

    static let `default`: FolderSortOrder = .dateAdded

    var menuTitle: String {
        switch self {
        case .name: return String(localized: "Name")
        case .dateAdded: return String(localized: "Date Added")
        case .dateModified: return String(localized: "Date Modified")
        case .dateCreated: return String(localized: "Date Created")
        case .kind: return String(localized: "Kind")
        }
    }
}

/// How a pinned folder looks on the bar (the native Dock's "Display as"): its own icon, or a stack of
/// its first items. rawValue is persisted (`PinnedFolderStore.displayModes`); declaration order is
/// the menu order, folder first as on the Dock.
enum FolderDisplayMode: String, CaseIterable {
    case folder
    case stack

    static let `default`: FolderDisplayMode = .stack

    var menuTitle: String {
        switch self {
        case .folder: return String(localized: "Folder")
        case .stack: return String(localized: "Stack")
        }
    }
}

/// How a pinned folder's popup shows its contents (the native Dock's "View content as"). rawValue is
/// persisted (`PinnedFolderStore.viewModes`); declaration order is the native menu order.
/// `automatic` picks fan or grid by how many items fit the screen's height
/// (`FolderViewResolution`).
enum FolderViewMode: String, CaseIterable {
    case fan
    case grid
    case list
    case automatic

    static let `default`: FolderViewMode = .automatic

    var menuTitle: String {
        switch self {
        case .fan: return String(localized: "Fan")
        case .grid: return String(localized: "Grid")
        case .list: return String(localized: "List")
        case .automatic: return String(localized: "Automatic")
        }
    }
}

/// Whether a stored path is still there, told apart from "there but not readable": only `ENOENT` /
/// `ENOTDIR` mean gone. Anything else (`EPERM` from a privacy-protected folder such as the Desktop,
/// `EACCES`, I/O errors) must never delete a shelf reference.
enum FileReachability: Equatable {
    case exists, missing, inaccessible

    static func of(path: String) -> FileReachability {
        var info = stat()
        let result = lstat(path, &info)
        return classify(result: result, errorNumber: result == 0 ? 0 : errno)
    }

    static func classify(result: Int32, errorNumber: Int32) -> FileReachability {
        if result == 0 { return .exists }
        return errorNumber == ENOENT || errorNumber == ENOTDIR ? .missing : .inaccessible
    }
}

/// Reading and sorting the contents of pinned folders / Trash. `load` hits the file system (callers run it on a background queue);
/// sorting and cover picking are pure functions covered by unit tests. Enumeration always skips hidden files.
enum FolderContentsLoader {
    struct Entry: Equatable {
        var url: URL
        var name: String
        var isDirectory: Bool
        var dateAdded: Date?
        var dateModified: Date?
        /// false = the path exists but this process may not read it (privacy permission).
        var isAccessible = true
        var dateCreated: Date? = nil
        /// A bundle that Finder shows as one file (an app, a `.rtfd`): never a subfolder.
        var isPackage = false
        /// A Finder alias or a symlink.
        var isAlias = false
    }

    static func load(directory: URL) throws -> [Entry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .addedToDirectoryDateKey, .contentModificationDateKey,
                                      .creationDateKey, .isPackageKey, .isAliasFileKey]
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )
        return urls.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return Entry(
                url: url,
                name: FileManager.default.displayName(atPath: url.path),
                isDirectory: values?.isDirectory ?? false,
                dateAdded: values?.addedToDirectoryDate,
                dateModified: values?.contentModificationDate,
                dateCreated: values?.creationDate,
                isPackage: values?.isPackage ?? false,
                isAlias: values?.isAliasFile ?? false
            )
        }
    }

    /// Date added descending (newest first); where dateAdded may be nil (network volumes, etc.), fall back to the modified date;
    /// ties are then broken by localized file name ascending, to keep the sort stable.
    static func sortedByDateAdded(_ entries: [Entry]) -> [Entry] {
        entries.sorted { a, b in
            let da = a.dateAdded ?? a.dateModified ?? .distantPast
            let db = b.dateAdded ?? b.dateModified ?? .distantPast
            if da != db { return da > db }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// Sort by the user's chosen order (popup grid and cover share the same rule). All stable: the last tiebreaker is always the localized file name.
    static func sorted(_ entries: [Entry], by order: FolderSortOrder) -> [Entry] {
        switch order {
        case .dateAdded:
            return sortedByDateAdded(entries)
        case .name:
            return entries.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .dateModified:
            return entries.sorted { a, b in
                let da = a.dateModified ?? a.dateAdded ?? .distantPast
                let db = b.dateModified ?? b.dateAdded ?? .distantPast
                if da != db { return da > db }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        case .dateCreated:
            return entries.sorted { a, b in
                let da = a.dateCreated ?? a.dateModified ?? .distantPast
                let db = b.dateCreated ?? b.dateModified ?? .distantPast
                if da != db { return da > db }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        case .kind:
            // Explicit two levels: group number → kind name within the group → file name. No sentinel characters spliced into strings —
            // localizedStandardCompare ignores control characters, so a "\0" prefix cannot guarantee folders always come first (caught by a unit test).
            return entries.sorted { a, b in
                let ra = kindRank(for: a), rb = kindRank(for: b)
                if ra != rb { return ra < rb }
                let ka = kindName(for: a), kb = kindName(for: b)
                if ka != kb { return ka.localizedStandardCompare(kb) == .orderedAscending }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
    }

    /// Group rank for kind sorting: folders (0) → files with an extension (1) → files without an extension (2, last).
    static func kindRank(for entry: Entry) -> Int {
        if entry.isDirectory { return 0 }
        return entry.url.pathExtension.isEmpty ? 2 : 1
    }

    /// Kind group name: files are grouped by the localized UTType description (falling back to the extension if unavailable). Folders / files without an extension return an empty string
    /// (each forms its own group, and the group rank is already decided by kindRank).
    static func kindName(for entry: Entry) -> String {
        guard !entry.isDirectory else { return "" }
        let ext = entry.url.pathExtension.lowercased()
        guard !ext.isEmpty else { return "" }
        if let type = UTType(filenameExtension: ext), let desc = type.localizedDescription {
            return desc
        }
        return ext
    }

    /// How many items a folder chip's cover stacks, like a native Dock stack.
    static let coverStackLimit = 3

    /// The chip cover: the first items of the already-sorted listing, front first. Subfolders
    /// count, as on a native Dock stack.
    static func coverEntries(in sortedEntries: [Entry]) -> [Entry] {
        Array(sortedEntries.prefix(coverStackLimit))
    }

    /// Shelf cell: build entries from the given path list (keeping the input order = staging order); paths that are definitely missing are skipped.
    /// Unreadable paths stay as `isAccessible == false` entries: without the folder's privacy
    /// permission an existing file looks the same as a deleted one to `fileExists`.
    static func entries(forPaths paths: [String]) -> [Entry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .addedToDirectoryDateKey, .contentModificationDateKey,
                                      .creationDateKey]
        return paths.compactMap { path in
            let reachability = FileReachability.of(path: path)
            guard reachability != .missing else { return nil }
            let url = URL(fileURLWithPath: path)
            guard reachability == .exists else {
                return Entry(url: url, name: url.lastPathComponent, isDirectory: false,
                             dateAdded: nil, dateModified: nil, isAccessible: false)
            }
            let values = try? url.resourceValues(forKeys: Set(keys))
            return Entry(
                url: url,
                name: FileManager.default.displayName(atPath: path),
                isDirectory: values?.isDirectory ?? false,
                dateAdded: values?.addedToDirectoryDate,
                dateModified: values?.contentModificationDate,
                dateCreated: values?.creationDate
            )
        }
    }

    /// Popup "load first, then show" (root-cause fix for the piecemeal feel): enumerate + sort in the background, waiting at most `timeout`
    /// (a local folder is typically <20ms). On timeout or read failure returns nil (rare cases such as network volumes),
    /// and the caller takes the original async backfill path. After a timeout the background block runs to completion and is released naturally; its result is no longer read.
    static func preload(url: URL, timeout: TimeInterval, order: FolderSortOrder = .default) -> [Entry]? {
        final class Box { var entries: [Entry]? }
        let semaphore = DispatchSemaphore(value: 0)
        let box = Box()
        DispatchQueue.global(qos: .userInteractive).async {
            box.entries = (try? load(directory: url)).map { sorted($0, by: order) }
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success else { return nil }
        return box.entries
    }
}
