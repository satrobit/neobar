import AppKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers

// DockStripView · click / gesture actions: folders, Relay Station, content preview, messaging-app fallback.
// Split out of DockStripView.swift as an extension on 2026-09-05; moved only, not changed.
extension DockStripView {
    /// Kept launcher uses the same shared membership projection (strip surface).
    func keptAppMembershipItems(bundleID: String) -> [LauncherMembershipItem] {
        LauncherMembershipItem.items(
            surface: .strip,
            bundleID: bundleID,
            isKept: keptAppStore.contains(bundleID),
            isMessaging: messagingStore.contains(bundleID),
            controller: appMembershipController
        )
    }

    /// The sole entry for left-clicking a pinned folder: dispatches by `FolderInteraction.primaryAction` (currently fixed = content preview).
    /// The A/B "left-click preview vs left-click open Finder" changes only the strategy enum and doesn't touch the call sites here.
    func folderPrimaryTap(_ path: String) {
        switch FolderInteraction.primaryAction {
        case .openFinderWindow: openFolderInFinder(path)
        case .preview: folderShowPreview(path)
        }
    }

    /// Open the Finder window for that path (best-effort; shared by left-click and the right-click "Open in Finder").
    func openFolderInFinder(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    /// The sole entry for pinned-folder content preview (the left-click A/B preview branch, right-click "Preview Contents", and later middle-click/force-click all go through it).
    /// Convert the "strip"-space frame (top-left, y-down) to screen coordinates (bottom-left) for the popup.
    /// Mirrors the inverse mapping of stripPoint(from:). If the frame isn't ready (first frame), don't pop up; try again on the next trigger.
    func folderShowPreview(_ path: String) {
        let entryID = StripEntry.pinnedFolder(path: path).id
        guard let frame = folderChipFrames[entryID], stripRootScreenRect != .zero else { return }
        let screenRect = CGRect(
            x: stripRootScreenRect.minX + frame.minX,
            y: stripRootScreenRect.maxY - frame.maxY,
            width: frame.width,
            height: frame.height
        )
        onFolderPopupToggle(path, screenRect, .pinnedFolder)
    }

    /// strip-space frame -> screen rect (the inverse of stripPoint(from:); used for the popup anchor).
    func stripFrameToScreen(_ frame: CGRect) -> CGRect {
        CGRect(x: stripRootScreenRect.minX + frame.minX,
               y: stripRootScreenRect.maxY - frame.maxY,
               width: frame.width, height: frame.height)
    }

    /// Gesture (force-click/middle-click) hit callback: global screen coordinates -> strip space -> hit a pinned folder / a specific Finder window -> preview.
    /// If no previewable chip is hit, silently ignore.
    func handleGesturePreview(atScreen global: CGPoint) {
        guard let p = stripPoint(from: global) else { return }
        for path in pinnedFolderStore.folderPaths {
            let entryID = StripEntry.pinnedFolder(path: path).id
            if let frame = folderChipFrames[entryID], frame.contains(p) {
                onFolderPopupToggle(path, stripFrameToScreen(frame), .pinnedFolder)
                return
            }
        }
        for (cid, frame) in chipFrames where frame.contains(p) {
            guard let item = StripItem.items(from: runtime.snapshot).first(where: { $0.id == cid }),
                  FinderTaskbarPolicy.isFinder(item.bundleIdentifier), item.isAppLevelFallback == false else { return }
            chipPulseNonces[cid, default: 0] += 1   // immediate "got the click" feedback, covering the ~200ms of reverse lookup
            previewFinderWindow(item, anchor: stripFrameToScreen(frame))
            return
        }
    }

    /// A specific Finder window -> reverse-look-up the path -> preview. AX positioning + the permission flow are on the main thread, AppleEvents enumeration is in the background,
    /// and on success it returns to the main thread to open the preview; permission denied / no unique match / timeout -> beep + log, no empty window popup (verified in spike#2).
    private func previewFinderWindow(_ item: StripItem, anchor: CGRect) {
        let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "app.neobar.NeoBar", category: "FinderWindowPreview")
        let ref = FinderWindowReference(pid: item.pid, cgWindowID: item.cgWindowID, title: item.title, bounds: item.bounds)
        let reader = FinderWindowContentsReader()
        let onToggle = onFolderPopupToggle

        func resolveViaAppleEvents(_ aeTarget: FinderWindowAppleEventsTarget) {
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let url = try FinderWindowContentsReader.folderURLViaAppleEvents(for: aeTarget)
                    DispatchQueue.main.async { onToggle(url.path, anchor, .finderWindowPreview) }
                } catch {
                    logger.error("finder-window-preview AppleEvents failed: \(String(describing: error), privacy: .public)")
                    DispatchQueue.main.async { NSSound.beep() }
                }
            }
        }
        // A minimized window can't be located in AX by cgWindowID (missing/mismatched) -> use the StripItem's own title+frame
        // to go straight to a unique AppleEvents match (AppleScript's `Finder windows` includes minimized windows, reporting restored-state bounds).
        func resolveFromItem() {
            guard let bounds = item.bounds else { NSSound.beep(); return }
            resolveViaAppleEvents(FinderWindowAppleEventsTarget(title: item.title, cocoaFrame: bounds))
        }

        do {
            switch try reader.target(for: ref) {
            case .folderURL(let url):
                onToggle(url.path, anchor, .finderWindowPreview)
            case .appleEvents(let aeTarget):
                resolveViaAppleEvents(aeTarget)
            }
        } catch FinderWindowContentsError.windowNotFound {
            resolveFromItem()
        } catch FinderWindowContentsError.missingWindowID {
            resolveFromItem()
        } catch FinderWindowContentsError.automationPermissionRequired {
            if FinderWindowContentsReader.requestFinderAutomationPermission() { resolveFromItem() } else { NSSound.beep() }
        } catch {
            logger.error("finder-window-preview target failed: \(String(describing: error), privacy: .public)")
            NSSound.beep()
        }
    }

    /// Relay shelf click: same coordinate conversion as folderShowPreview, with the anchor using the separate shelfFrame.
    func shelfChipTapped() {
        guard shelfFrame != .zero, stripRootScreenRect != .zero else { return }
        let screenRect = CGRect(
            x: stripRootScreenRect.minX + shelfFrame.minX,
            y: stripRootScreenRect.maxY - shelfFrame.maxY,
            width: shelfFrame.width,
            height: shelfFrame.height
        )
        onShelfPopupToggle(screenRect)
    }

    /// Dock-icon-click equivalent: unhide + reopen. The app recreates its main window
    /// even when other windows are visible (verified with WeChat, 2026-06-12).
    /// Left-click when the messaging-area icon **can't identify the main window** (fallback 3, 2026-08-23):
    /// - the app has no real window at all -> call back the main window (the owner's daily "close main window -> click icon to call it back" flow must not change);
    /// - it has windows but we can't tell which is the main one -> **toggle the whole app**: collapse it if frontmost, otherwise bring it to the front. The icon always
    ///   responds, at the cost of collapsing standalone chat windows too, which is still better than before the change, "could call but not collapse". The logic reuses the one in the drawer icon's
    ///   `LauncherChip.performDefaultTap`, rather than copying "collapse if frontmost, otherwise bring up" again.
    static func messagingFallbackTap(bundleID: String, hasRealWindow: Bool) {
        guard hasRealWindow else {
            reopenMainWindow(bundleID: bundleID)
            return
        }
        LauncherChip.performDefaultTap(bundleID: bundleID, isRunning: true,
                                       finderHasRealWindow: false,   // Finder can't enter the messaging area
                                       launch: {}, onOpen: nil)
    }

    static func reopenMainWindow(bundleID: String) {
        let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter {
                $0.activationPolicy == .regular
                    && ProcessLiveness.isAlive(pid: $0.processIdentifier)
            }
        for app in runningApps { _ = app.unhide() }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init(), completionHandler: nil)
    }
}
