import Foundation

final class AppDisplayNameCache {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func value(for bundleID: String, loader: () -> String?) -> String {
        lock.lock()
        let cached = values[bundleID]
        lock.unlock()
        if let cached { return cached }

        guard let resolved = loader(), !resolved.isEmpty, resolved != bundleID else {
            return bundleID
        }
        lock.lock()
        values[bundleID] = resolved
        lock.unlock()
        return resolved
    }

    func invalidate(bundleID: String) {
        lock.lock()
        values.removeValue(forKey: bundleID)
        lock.unlock()
    }
}

/// All the known spellings of what an app is "called", normalized (trim + lowercase) and stored as a set.
///
/// **Why it is needed**: the messaging-zone absorption criterion is "window title == app name", and the app name used to be looked up fresh every frame via
/// `NSRunningApplication.runningApplications(withBundleIdentifier:).first?.localizedName`.
/// That is a LaunchServices call that can **momentarily return empty** for a live process (same cause as the hard constraint on `ProcessLiveness`).
/// One glitch -> the main window isn't absorbed that frame -> the app renders one card in the messaging zone and one in the live zone -> the row widens and pushes the right side away,
/// and the mismatched state sticks until the next unrelated re-layout (measured sticking from 2 seconds to 79 minutes).
///
/// Measured 2026-08-11: on this machine `Bundle.localizedInfoDictionary` resolves Feishu / WeChat to English
/// (`{feishu, lark}` / `{wechat}`); the Chinese titles of Feishu and WeChat aren't in the bundle-derived names at all,
/// so these two apps **can only** rely on that live query -- they are the ones that mismatch as a pair, while QQ (which has `qq` in its bundle) never mismatches.
///
/// **The fix**: the name set only ever grows -- bundle-derived names ∪ every `localizedName` ever successfully observed.
/// Once an observation has succeeded, no later glitch affects the decision; before one succeeds it retries every time,
/// so "the first frame of a cold start happens to glitch" won't pin an incomplete set as a complete cache forever (that would be worse than today).
///
/// A side effect is saving I/O: after a successful observation there are zero LaunchServices calls per frame (it used to be once per frame × per messaging app,
/// and happened right inside the evaluation of `DockStripView.body`).
final class AppNameRegistry {
    /// Bundle-derived names (read from Info.plist, once). Returns a normalized set.
    private let bundleNamesLoader: (String) -> Set<String>
    /// The `localizedName` of the current running instance; returns nil if the process isn't running or LaunchServices glitches.
    private let runningNameLoader: (String) -> String?

    private struct Entry {
        var names: Set<String>
        /// Whether a running name has ever been successfully observed. When false, every query retries.
        var sawRunningName: Bool
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    /// Product aliases -- **written only after being measured, add but never guess** (2026-08-23): another brand name an app uses for its main window under some UI language,
    /// which can't be found in Info.plist and isn't the running name either. With WeChat's English UI (mainland account) the main window is called
    /// `Weixin`, while on an English system the app is called `WeChat`, and neither equals the Chinese name of WeChat -- so users on an English system with a mainland account
    /// (overseas Chinese) can't get into the messaging zone, and even if they did, the main window wouldn't be recognized. Already normalized (lowercase).
    static let productAliases: [String: Set<String>] = [
        "com.tencent.xinWeChat": ["weixin"],
    ]

    init(bundleNamesLoader: @escaping (String) -> Set<String>,
         runningNameLoader: @escaping (String) -> String?) {
        self.bundleNamesLoader = bundleNamesLoader
        self.runningNameLoader = runningNameLoader
    }

    /// Normalize: trim leading/trailing whitespace + lowercase. An empty string means "not a name", and callers directly treat it as no match.
    static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The full set of known names. Retries `runningNameLoader` until a running name has been observed.
    func knownNames(for bundleID: String) -> Set<String> {
        lock.lock()
        let cached = entries[bundleID]
        lock.unlock()

        // Disk reads happen outside the lock. Read only when the entry is missing; once read, it stays cached.
        var entry = cached ?? Entry(names: baseNames(for: bundleID), sawRunningName: false)

        // No running name seen yet -> try once more. Once seen, never query again, so glitches can't affect remembered names.
        if !entry.sawRunningName {
            let normalized = runningNameLoader(bundleID).map(Self.normalize)
            if let normalized, !normalized.isEmpty {
                entry.names.insert(normalized)
                entry.sawRunningName = true
            }
        }

        return commit(entry, for: bundleID)
    }

    /// Under concurrency two threads may each compute an entry; **merge rather than overwrite**, so the later writer doesn't wipe out the earlier one's
    /// observation (the set only ever grows, so merging is always safe). Returns the merged name set.
    @discardableResult
    private func commit(_ entry: Entry, for bundleID: String) -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        var merged = entry
        if let existing = entries[bundleID] {
            merged.names.formUnion(existing.names)
            merged.sawRunningName = merged.sawRunningName || existing.sawRunningName
        }
        entries[bundleID] = merged
        return merged.names
    }

    /// Names handed in from outside (such as the ready-made `NSRunningApplication` in the `NSWorkspace` launch notification),
    /// saving one query. Likewise only ever grows.
    func observe(name raw: String, for bundleID: String) {
        let normalized = Self.normalize(raw)
        guard !normalized.isEmpty else { return }

        lock.lock()
        let existing = entries[bundleID]
        lock.unlock()

        // When first seeing this bundle, bundle names must be brought along -- `knownNames` reads disk only when the entry is missing,
        // so if only the running name were stuffed in here, the bundle names could never be filled in later. Disk reads happen outside the lock.
        var names = existing?.names ?? baseNames(for: bundleID)
        names.insert(normalized)
        commit(Entry(names: names, sawRunningName: true), for: bundleID)
    }

    /// Bundle-derived names ∪ product aliases: the starting point when an entry is first created; both entry-creating paths must go through here.
    private func baseNames(for bundleID: String) -> Set<String> {
        bundleNamesLoader(bundleID).union(Self.productAliases[bundleID] ?? [])
    }

    func matches(title: String, bundleID: String) -> Bool {
        let normalized = Self.normalize(title)
        guard !normalized.isEmpty else { return false }
        return knownNames(for: bundleID).contains(normalized)
    }

    func invalidate(bundleID: String) {
        lock.lock()
        entries.removeValue(forKey: bundleID)
        lock.unlock()
    }
}
