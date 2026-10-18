import Foundation

/// The unified basis for user-given file / folder paths: expand `~`, collapse `..`, strip the trailing slash (except the root `/`).
/// Shared by the shelf (`ShelfStore`) and pinned folders (`PinnedFolderStore`), so both sides' stored keys dedupe on the same basis.
enum FilePathNormalization {
    nonisolated static func normalized(_ path: String) -> String {
        var p = (path as NSString).standardizingPath
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }
}
