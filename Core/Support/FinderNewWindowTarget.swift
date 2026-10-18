import Foundation

/// Where a new Finder window goes when Finder has no window and the user clicks its taskbar chip or
/// drawer icon, read from Finder's own "New Finder windows show" setting (`com.apple.finder`
/// `NewWindowTarget` / `NewWindowTargetPath`). This is the fallback behind the reopen event
/// (`FinderNewWindowOpener`); where that event is enabled Finder picks the location itself.
///
/// Only folder targets resolve to a URL. Recents, Computer and iCloud Drive stay `.home`: Finder's
/// own helper apps for them run an AppleScript whose errors never reach the caller (`Docs/05`), so a
/// failure there could not fall back. A missing or unknown code is `.home` too — what the click did
/// before the setting was honoured, never a regression.
enum FinderNewWindowTarget: Equatable {
    case folder(URL)
    case home

    static func resolve(target: String?, path: String?, home: URL) -> FinderNewWindowTarget {
        switch target {
        case "PfHm": return .home
        case "PfDe": return .folder(home.appendingPathComponent("Desktop", isDirectory: true))
        case "PfDo": return .folder(home.appendingPathComponent("Documents", isDirectory: true))
        case "PfLo": return folderURL(path).map(FinderNewWindowTarget.folder) ?? .home
        case "PfVo": return .folder(folderURL(path) ?? URL(fileURLWithPath: "/", isDirectory: true))
        default: return .home
        }
    }

    /// Parsed by hand rather than with `URL(string:)`: how leniently that accepts an unencoded
    /// non-ASCII path differs between macOS releases, and the result must not depend on the OS.
    private static func folderURL(_ string: String?) -> URL? {
        guard var rest = string, !rest.isEmpty else { return nil }
        if rest.hasPrefix("file://") {
            rest.removeFirst("file://".count)
            if rest.hasPrefix("localhost/") { rest.removeFirst("localhost".count) }
        }
        guard rest.hasPrefix("/"), let path = rest.removingPercentEncoding else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}

/// How the reopen event came back. Same error semantics as `FinderTrashReply`: a missing or zero
/// `keyErrorNumber` is no error. A timeout is its own case because it must not fall back — Finder
/// is busy and the queued event still opens a window later, so opening a folder too would stack two.
enum FinderReopenOutcome: Equatable {
    case delivered, timedOut, failed(Int)

    static func parse(sendError: Int?, replyError: Int?) -> FinderReopenOutcome {
        let errors = [sendError, replyError].compactMap { $0 }.filter { $0 != 0 }
        if errors.contains(-1712) { return .timedOut }
        if let first = errors.first { return .failed(first) }
        return .delivered
    }
}

enum FinderReopenEventGate {
    /// Lowest macOS major version on which the reopen event was measured to open Finder's configured
    /// location (`Docs/05`). Lower it only after measuring on that version: a delivered event that
    /// opens nothing cannot be detected, so an unverified version would leave the click dead.
    static let verifiedMinimumMajorVersion = 27

    static func isEnabled(osMajorVersion: Int, killSwitchOn: Bool) -> Bool {
        killSwitchOn && osMajorVersion >= verifiedMinimumMajorVersion
    }
}

/// Asks whether a URL is a directory without letting a dead network mount hang the caller: `stat`
/// there blocks for 10s+ (`Docs/05`). At most one check is outstanding per process; while a
/// timed-out check still holds the slot, new requests get `.unknown` at once instead of piling up
/// blocked threads. A late result is dropped.
final class BoundedDirectoryProbe {
    enum Answer: Equatable { case directory, notDirectory, unknown }

    private let timeout: TimeInterval
    private let isDirectory: (URL) -> Bool
    private let queue = DispatchQueue(label: "app.neobar.NeoBar.directory-probe", qos: .userInitiated)
    private let lock = NSLock()
    private var busy = false

    init(timeout: TimeInterval, isDirectory: @escaping (URL) -> Bool = BoundedDirectoryProbe.fileSystemIsDirectory) {
        self.timeout = timeout
        self.isDirectory = isDirectory
    }

    func check(_ url: URL) -> Answer {
        lock.lock()
        guard !busy else { lock.unlock(); return .unknown }
        busy = true
        lock.unlock()

        let result = ResultBox()
        let done = DispatchSemaphore(value: 0)
        queue.async { [self] in
            result.set(isDirectory(url))
            lock.lock(); busy = false; lock.unlock()
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success, let value = result.get() else { return .unknown }
        return value ? .directory : .notDirectory
    }

    /// Follows symlinks; a missing path is "not a directory".
    static func fileSystemIsDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private final class ResultBox {
        private let lock = NSLock()
        private var value: Bool?
        func set(_ newValue: Bool) { lock.lock(); value = newValue; lock.unlock() }
        func get() -> Bool? { lock.lock(); defer { lock.unlock() }; return value }
    }
}
