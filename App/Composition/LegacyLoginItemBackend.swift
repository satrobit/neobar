import AppKit
import CoreServices

/// "Launch at login" on macOS 12: `SMAppService` requires 13+, so on 12 the old login items list is used
/// (`LSSharedFileList*`, the same table as "System Preferences → Users & Groups → Login Items"; users can see it and delete entries themselves).
///
/// **The deprecation warnings here are expected; do not change the code to silence them.** Apple marked this API group deprecated in 10.11,
/// but macOS 12 is no longer updated so the interface will not change again, and this path is only selected on 12 (`LaunchAtLoginService.systemBackend()`).
/// When the minimum deployment target moves to 13, delete this whole file. Why not a helper app or LaunchAgent: `Docs/27`.
///
/// Between the backend and `SharedFileListLoginItems` (which actually touches CoreServices) sits `LoginItemListing`,
/// and unit tests replace it with an in-memory list (`LaunchAtLoginServiceTests`).
protocol LoginItemListing: Sendable {
    /// Returns nil when the list cannot be opened, to distinguish it from "the list is empty".
    func itemURLs() -> [URL]?
    func insert(_ url: URL) throws
    /// Deletes **all** entries in the list that resolve to this URL.
    func remove(_ url: URL) throws
}

struct LegacyLoginItemBackend: LaunchAtLoginBackend {
    let list: any LoginItemListing
    let bundleURL: URL

    func readState() -> LaunchAtLoginState {
        guard let urls = list.itemURLs() else { return .unsupported }
        return urls.contains { LoginItemURLMatcher.matches($0, bundleURL) } ? .on : .off
    }

    func setEnabled(_ enabled: Bool) throws {
        guard let urls = list.itemURLs() else { throw LaunchAtLoginError.unsupported }
        let matches = urls.filter { LoginItemURLMatcher.matches($0, bundleURL) }
        if enabled {
            // Do not insert another entry if one is already in the list: the old API does not de-duplicate, and duplicate entries show up as two rows in System Preferences.
            guard matches.isEmpty else { return }
            try list.insert(bundleURL)
        } else {
            for url in matches {
                try list.remove(url)
            }
        }
    }

    /// The old list has no "awaiting approval" step, so "Open Login Items Settings…" in the menu never appears on 12;
    /// it is kept for protocol completeness — on 12 login items live under "Users & Groups".
    func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preferences.users") else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Whether a URL stored in the list has a trailing slash or goes through the `/private` symlink is unreliable; normalize before comparing.
enum LoginItemURLMatcher {
    static func matches(_ lhs: URL, _ rhs: URL) -> Bool {
        normalizedPath(lhs) == normalizedPath(rhs)
    }

    static func normalizedPath(_ url: URL) -> String {
        var path = url.standardizedFileURL.resolvingSymlinksInPath().path
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }
}

/// The only place that touches `LSSharedFileList*`.
struct SharedFileListLoginItems: LoginItemListing {
    func itemURLs() -> [URL]? {
        guard let list = openList() else { return nil }
        return entries(in: list).map(\.url)
    }

    func insert(_ url: URL) throws {
        guard let list = openList() else { throw LaunchAtLoginError.unsupported }
        // The return value carries CF_RETURNS_RETAINED, so Swift hands you the object directly; do not call takeRetainedValue() again.
        let inserted = LSSharedFileListInsertItemURL(
            list,
            kLSSharedFileListItemLast.takeUnretainedValue(),
            nil,
            nil,
            url as CFURL,
            nil,
            nil
        )
        guard inserted != nil else { throw LaunchAtLoginError.writeFailed }
    }

    func remove(_ url: URL) throws {
        guard let list = openList() else { throw LaunchAtLoginError.unsupported }
        for entry in entries(in: list) where LoginItemURLMatcher.matches(entry.url, url) {
            guard LSSharedFileListItemRemove(list, entry.item) == noErr else {
                throw LaunchAtLoginError.writeFailed
            }
        }
    }

    private func openList() -> LSSharedFileList? {
        LSSharedFileListCreate(nil, kLSSharedFileListSessionLoginItems.takeUnretainedValue(), nil)?
            .takeRetainedValue()
    }

    private func entries(in list: LSSharedFileList) -> [(item: LSSharedFileListItem, url: URL)] {
        var seed: UInt32 = 0
        let items = LSSharedFileListCopySnapshot(list, &seed)?.takeRetainedValue() as? [LSSharedFileListItem] ?? []
        // When resolving entries, do not show interaction UI and do not mount volumes: this step runs on a background queue, and the list may contain other login items pointing at external drives.
        let flags = UInt32(kLSSharedFileListNoUserInteraction | kLSSharedFileListDoNotMountVolumes)
        return items.compactMap { item in
            guard let url = LSSharedFileListItemCopyResolvedURL(item, flags, nil)?.takeRetainedValue() as URL? else {
                return nil
            }
            return (item, url)
        }
    }
}
