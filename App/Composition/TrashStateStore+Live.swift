import AppKit

extension TrashStateStore {
    static let shared = TrashStateStore(
        client: FinderTrashClient(),
        fileTrasher: { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) },
        workQueue: AppRuntime.actionQueue,
        changeStamp: { TrashChangeStamp.live() },
        directoryObserver: TrashDirectoryWatcher(directories: { TrashChangeStamp.liveDirectories() },
                                                 notificationCenter: NSWorkspace.shared.notificationCenter,
                                                 workQueue: AppRuntime.actionQueue),
        confirmEmpty: { completion in
            // Run the modal loop from a run-loop block, never inside a main-queue block: CFRunLoop
            // does not service the main dispatch queue in a modal loop nested in one, so every
            // taskbar update would stall until the alert is answered.
            RunLoop.main.perform {
                MainActor.assumeIsolated {
                    NSApp.activate(ignoringOtherApps: true)
                    let alert = NSAlert()
                    alert.messageText = String(localized: "Are you sure you want to permanently erase the items in the Trash?")
                    alert.informativeText = String(localized: "You can’t undo this action.")
                    alert.addButton(withTitle: String(localized: "Empty Trash")).hasDestructiveAction = true
                    alert.addButton(withTitle: String(localized: "Cancel")).keyEquivalent = "\u{1b}"
                    completion(alert.runModal() == .alertFirstButtonReturn)
                }
            }
        },
        beep: { NSSound.beep() },
        notificationCenter: NSWorkspace.shared.notificationCenter
    )

    /// Brings the Trash window Finder just opened forward by itself, through the same activation as
    /// its window chip. Never activates Finder as a whole — not even when the inventory misses the
    /// window: that raised Finder's other windows (2026-09-15), and a loaded Finder needs seconds.
    static func revealTrashWindow(runtime: AppRuntime) -> @MainActor () -> Void {
        { [weak runtime] in
            runtime?.activateWhenAppears(timeout: 6) {
                TrashWindowLookup.actionWindowID(snapshot: $0, titles: TrashWindowLookup.liveTitles)
            }
        }
    }
}

extension TrashStateStore {
    /// "Open in Finder" from the chip menu and the popup: the existing Trash window if there is one
    /// (never a second one), otherwise the non-activating open followed by the reveal.
    static func openTrashWindow(runtime: AppRuntime, store: TrashStateStore) {
        if let windowID = TrashWindowLookup.actionWindowID(snapshot: runtime.snapshot,
                                                           titles: TrashWindowLookup.liveTitles) {
            runtime.activate(windowID: windowID)
        } else {
            store.openTrash()
        }
    }
}

extension TrashChangeStamp {
    /// The home Trash plus the current user's trash on every mounted local volume. Network volumes
    /// are never touched: a `stat` on a dead NFS mount hangs for over 10s (2026-09-16). The
    /// directory watcher follows the same list.
    static func liveDirectories() -> [URL] {
        let fileManager = FileManager.default
        var directories = [fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")]
        let keys: [URLResourceKey] = [.volumeIsLocalKey, .volumeIsRootFileSystemKey]
        let volumes = fileManager.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                    options: [.skipHiddenVolumes]) ?? []
        for volume in volumes {
            let values = try? volume.resourceValues(forKeys: Set(keys))
            guard values?.volumeIsLocal == true, values?.volumeIsRootFileSystem != true else { continue }
            directories.append(volume.appendingPathComponent(".Trashes/\(getuid())"))
        }
        return directories
    }

    static func live() -> TrashChangeStamp {
        let fileManager = FileManager.default
        return build(directories: liveDirectories()) { directory in
            (try? fileManager.attributesOfItem(atPath: directory.path))?[.modificationDate] as? Date
        }
    }
}

extension TrashWindowLookup {
    /// Resolved once: the projection reads it on every body pass, and the process language
    /// cannot change without a relaunch.
    static let liveTitles = titles(
        localizedName: FileManager.default.displayName(
            atPath: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash").path
        )
    )
}
