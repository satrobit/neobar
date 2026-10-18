import AppKit
import Foundation

/// Counting ledger for the "most-used files" (the sort data source for the recents section of the right-click menu).
///
/// macOS records only "recently opened" and not counts, so NeoBar counts on its own from the feature's launch, from two sources:
/// ① **Top-of-list changes in the system recents list**: sfl directory watching (`DirectoryWatcher`) + resampling on app activation /
///    menu open. Directory watching gives no guarantee about whether the sfl is written by atomic replacement (a TCC directory,
///    which can't be verified with a probe on a dev machine), so it is only an **accelerator**; resampling is what backstops correctness --
///    at the latest by the next right-click on that app, the previous top-of-list change gets recorded after the fact.
/// ② **Opened from the NeoBar menu** (`recordOpen`): directly +1, and also sets `lastTop` to that file,
///    to avoid ① counting it again when the sfl is updated afterwards.
///
/// Storage: a JSON file (Application Support/<bundle id>/document-usage.json), **not in
/// UserDefaults** -- the worst case of 40 bundles x 200 entries is several hundred KB, and stuffing that into the preferences file would slow every defaults write.
/// Pure logic (sorting / eviction / count decisions) lives in `DocumentUsageRanking` (unit-tested); only side effects are handled here.
@MainActor
final class DocumentUsageStore {
    /// Menu construction is an AppKit side-effect path; following the precedent of `AppDisplayNameResolver`, it uses a shared instance
    /// rather than injecting another environment object into each of the three NSHostingViews.
    static let shared = DocumentUsageStore()

    private var usageByBundle: [String: BundleDocumentUsage]
    private var watcher: DirectoryWatcher?
    private var activationObserver: NSObjectProtocol?
    /// When directory watching fires, use mtime to pick out "which bundle's sfl changed" and resample only those that changed.
    private var mtimeByFile: [String: Date] = [:]
    private var saveWork: DispatchWorkItem?
    private let ioQueue = DispatchQueue(label: "app.neobar.NeoBar.document-usage", qos: .utility)

    private init() {
        // Load synchronously: the file is capped at several hundred KB and loaded once; paying a few milliseconds on first access (right-click menu or start) is acceptable.
        usageByBundle = DocumentUsageDisk.load()
    }

    // MARK: Lifecycle (AppDelegate: on while the taskbar runs, stopped on suspend / quit)

    func start() {
        guard watcher == nil else { return }
        watcher = DirectoryWatcher(path: DocumentUsageDisk.sharedListDir) { [weak self] in
            self?.directoryChanged()
        }
        // Establish the mtime baseline (the round where known is empty only records and does not sample).
        directoryChanged()
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard let bid = app?.bundleIdentifier else { return }
            MainActor.assumeIsolated { self?.resampleInBackground(bundleIDs: [bid]) }
        }
    }

    func stop() {
        watcher?.stop()
        watcher = nil
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }
    }

    // MARK: Menu-side entry points

    /// Synchronous sampling when the menu opens: the caller has just read that bundle's recents list and hands the top item in along the way.
    func noteRecentSample(bundleID: String, topPath: String?) {
        var usage = usageByBundle[bundleID] ?? BundleDocumentUsage()
        let previous = usage.lastTop
        usage.lastTop = topPath
        if DocumentUsageRanking.shouldCountTopChange(previousTop: previous, newTop: topPath), let topPath {
            usage.files = DocumentUsageRanking.bumped(usage.files, path: topPath, at: Date())
            usage.touchedAt = Date()
        } else if previous != topPath {
            usage.touchedAt = Date()
        }
        guard usageByBundle[bundleID] != usage else { return }
        usageByBundle[bundleID] = usage
        usageByBundle = DocumentUsageRanking.prunedBundles(usageByBundle)
        scheduleSave()
    }

    /// A file was opened from the NeoBar menu: directly +1, and set lastTop to it (to prevent ① from double-counting).
    func recordOpen(bundleID: String, path: String) {
        var usage = usageByBundle[bundleID] ?? BundleDocumentUsage()
        usage.files = DocumentUsageRanking.bumped(usage.files, path: path, at: Date())
        usage.lastTop = path
        usage.touchedAt = Date()
        usageByBundle[bundleID] = usage
        usageByBundle = DocumentUsageRanking.prunedBundles(usageByBundle)
        scheduleSave()
    }

    /// The ranking (count descending -> last opened descending -> system recents order). Existence checks are done only for paths from the "count-only source"
    /// (the system recents list side, `RecentDocumentsReader`, has already checked), and deleted files are cleaned out of the ledger along the way.
    func ranked(bundleID: String, recentPaths: [String], limit: Int = 10) -> [String] {
        let counts = usageByBundle[bundleID]?.files ?? [:]
        let candidates = DocumentUsageRanking.ranked(
            counts: counts,
            recentPaths: recentPaths,
            limit: limit + 8
        )
        let recentSet = Set(recentPaths)
        var removedDead = false
        let alive = candidates.filter { path in
            if recentSet.contains(path) { return true }
            if FileManager.default.fileExists(atPath: path) { return true }
            usageByBundle[bundleID]?.files.removeValue(forKey: path)
            removedDead = true
            return false
        }
        if removedDead { scheduleSave() }
        return Array(alive.prefix(limit))
    }

    // MARK: Sampling

    private func directoryChanged() {
        let known = mtimeByFile
        ioQueue.async { [weak self] in
            let fm = FileManager.default
            let dir = DocumentUsageDisk.sharedListDir
            var next: [String: Date] = [:]
            var changed: [String] = []
            let names = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
            for name in names where name.contains(".sfl") {
                let path = dir + "/" + name
                guard let mtime = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date else { continue }
                next[name] = mtime
                if known[name] != mtime {
                    changed.append((name as NSString).deletingPathExtension)
                }
            }
            DispatchQueue.main.async { [weak self, next, changed] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.mtimeByFile = next
                    guard !known.isEmpty else { return } // First round only establishes the baseline
                    self.resampleInBackground(bundleIDs: changed)
                }
            }
        }
    }

    private func resampleInBackground(bundleIDs: [String]) {
        guard !bundleIDs.isEmpty else { return }
        ioQueue.async { [weak self] in
            var tops: [String: String?] = [:]
            for bid in Set(bundleIDs) {
                tops[bid] = RecentDocumentsReader.recentDocuments(for: bid, maxCount: 1).first?.path
            }
            DispatchQueue.main.async { [weak self, tops] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    for (bid, top) in tops { self.noteRecentSample(bundleID: bid, topPath: top) }
                }
            }
        }
    }

    // MARK: Persistence (merged at 1s, utility queue, atomic write)

    private func scheduleSave() {
        saveWork?.cancel()
        let snapshot = usageByBundle
        let work = DispatchWorkItem { DocumentUsageDisk.write(snapshot) }
        saveWork = work
        ioQueue.asyncAfter(deadline: .now() + 1, execute: work)
    }
}

/// Disk and paths (file-level private): placed outside the @MainActor class so the io queue calls it directly without touching isolation.
private enum DocumentUsageDisk {
    static let sharedListDir =
        ("~/Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments"
            as NSString).expandingTildeInPath

    struct Archive: Codable {
        var version: Int
        var bundles: [String: BundleDocumentUsage]
    }

    static var storeURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let bundleID = Bundle.main.bundleIdentifier ?? "app.neobar.NeoBar"
        return base.appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("document-usage.json")
    }

    static func load() -> [String: BundleDocumentUsage] {
        guard let data = try? Data(contentsOf: storeURL),
              let archive = try? JSONDecoder().decode(Archive.self, from: data),
              archive.version == 1 else { return [:] }
        return archive.bundles
    }

    static func write(_ bundles: [String: BundleDocumentUsage]) {
        let archive = Archive(version: 1, bundles: bundles)
        guard let data = try? JSONEncoder().encode(archive) else { return }
        let url = storeURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }
}
