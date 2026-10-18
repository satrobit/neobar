import Foundation

/// The rows of a pinned folder's list view (the native Dock's `directorylist` menu): files in the
/// folder's sort, subfolders as cascading submenus, cut at 501 with a disabled "...".
enum FolderListMenuPlan {
    /// The native loop stops at 501 items.
    static let itemLimit = 501

    enum Row: Equatable {
        case file(FolderContentsLoader.Entry)
        case subfolder(FolderContentsLoader.Entry)
        /// More items than the limit: a disabled "..." closes the list.
        case more
    }

    /// What a menu level shows: its rows, or — the directory did not answer within the preload's
    /// time limit — a disabled "..." and "Open in Finder" for that directory.
    enum Listing: Equatable {
        case rows([Row])
        case timedOut
    }

    static func listing(entries: [FolderContentsLoader.Entry]?,
                        isSubfolder: (FolderContentsLoader.Entry) -> Bool) -> Listing {
        guard let entries else { return .timedOut }
        var rows = entries.prefix(itemLimit).map { isSubfolder($0) ? Row.subfolder($0) : Row.file($0) }
        if entries.count > itemLimit { rows.append(.more) }
        return .rows(rows)
    }

    /// A directory that is not a package, or an alias / symlink whose target is one. Resolving
    /// the alias is the caller's (file system) job.
    static func isSubfolder(_ entry: FolderContentsLoader.Entry,
                            aliasTargetIsFolder: (URL) -> Bool) -> Bool {
        if entry.isAlias { return aliasTargetIsFolder(entry.url) }
        return entry.isDirectory && !entry.isPackage
    }
}
