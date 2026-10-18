import AppKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers

/// Funnel for the system drag-and-drop of external files onto the strip. Routing geometry = the pure function `StripDropRouting.route`;
/// this delegate is only responsible for: publishing the target to the view for highlighting during hover, and after release asynchronously gathering all URLs and then committing back on the main thread.
/// The mount point must be at the same level as the "strip" coordinateSpace (same coordinate source, settled in review).
///
/// **App bundles and ordinary files are separated right here**: `.app` only goes to `onCommitApplications`,
/// and `onCommit` (`handleExternalDrop`) can never receive an app from now on. That is the second reason this file exists,
/// and one of the two gates against the bug "dragging an app onto a folder cell moves it out of 'Applications'".
struct StripFileDropDelegate: DropDelegate {
    /// Geometry is **read when a drop callback runs, never copied at construction**: the strip's
    /// frames live in `StripFrameBox` and the body no longer rebuilds this delegate when they move,
    /// so a value captured here would route a later drop by stale geometry (wrong folder, false
    /// trash). nil = the transit shelf was closed by the user (not "frames not yet measured"; the latter still passes `.zero`).
    let shelfFrame: () -> CGRect?
    let trashFrame: () -> CGRect?
    let folderFrames: () -> [String: CGRect]
    let orderedPaths: [String]
    var headSlack: CGFloat = StripDropRouting.defaultHeadSlack
    /// The make-way gap open among the pinned folders right now (nil = none). No default: an
    /// omission compiles into a gap that closes under a pointer resting in it at the zone's ends.
    let openFolderGap: StripDropRouting.OpenFolderGap?
    /// dropEntered = hover session starts; dropUpdated = movement during the session; performDrop/dropExited = session ends.
    /// The view side uses these to do "highlight can only be lit by dropEntered + a drag-end watchdog" (see externalDropHover*).
    let onHoverBegan: (StripDropRouting.Target) -> Void
    let onHoverMoved: (StripDropRouting.Target) -> Void
    /// Parameter = "is this branch the settle?". Only `performDrop` passes `true` (the gap is left for the settle handoff).
    let onHoverEnded: (Bool) -> Void
    let onCommit: (StripDropRouting.Target, [URL]) -> Void
    /// The dragged-in app bundle + drop x ("strip" space). See `handleExternalApplicationDrop`.
    let onCommitApplications: ([URL], CGPoint) -> Void
    /// The make-way gap during hover: (hover target, the dragged app's bundleID or nil, whether this drop is folders only, drop point).
    /// The view side folds it into an anchor and gates on change; **this is called about every ~50ms**.
    let onGhostMoved: (StripDropRouting.Target, String?, Bool, CGPoint) -> Void
    /// For temporary diagnostics: at which index the gap is currently inserted (nil = no gap), the frozen strip width, the strip's actual screen rect.
    /// The last two are for verifying "whether the width freeze actually works"; delete after the "plus sign flicker" is sorted out.
    let currentGhostIndex: () -> Int?
    let currentFrozenWidth: () -> CGFloat?
    let currentStripRect: () -> CGRect

    /// The target the latest hover callback resolved, read by `StripDropBadgeOverlay` right after it
    /// forwards the same callback. Main thread only. An orphan `dropUpdated` after a drop can leave it
    /// set: harmless, since only a `.copy` answer is rewritten and the next `dropEntered` overwrites it.
    static var hoveredTarget: StripDropRouting.Target?

    /// The target during hover (decides highlight and cursor). Apps are always `.keepApp`.
    private func route(_ info: DropInfo) -> StripDropRouting.Target {
        route(info, isApplicationDrag: DragPasteboardInspector.containsApplication())
    }

    /// The target of the non-app half: in a mixed drag apps go to keep and the rest still follow file semantics, so a separate copy has to be computed.
    private func fileRoute(_ info: DropInfo) -> StripDropRouting.Target {
        route(info, isApplicationDrag: false)
    }

    private func route(_ info: DropInfo, isApplicationDrag: Bool) -> StripDropRouting.Target {
        StripDropRouting.route(location: info.location,
                               isApplicationDrag: isApplicationDrag,
                               isTrashItemDrag: DragPasteboardInspector.containsOnlyTrashItems(),
                               shelfFrame: shelfFrame(),
                               trashFrame: trashFrame(),
                               folderFrames: folderFrames(),
                               orderedPaths: orderedPaths,
                               headSlack: headSlack,
                               pinEdgeFraction: DragPasteboardInspector.pinsFolders()
                                   ? StripDropRouting.folderPinEdgeFraction : 0,
                               openGap: openFolderGap)
    }

    private func reportGhost(_ target: StripDropRouting.Target, _ info: DropInfo) {
        onGhostMoved(target, DragPasteboardInspector.applicationBundleID(),
                     DragPasteboardInspector.pinsFolders(), info.location)
    }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [UTType.fileURL])
    }

    func dropEntered(info: DropInfo) {
        let target = route(info)
        Self.hoveredTarget = target
        trace("entered", info, target: target)
        onHoverBegan(target)
        reportGhost(target, info)
    }

    /// Stays `.copy` over the Trash too: the badge-free answer is `StripDropBadgeOverlay`'s.
    func dropUpdated(info: DropInfo) -> DropProposal? {
        let target = route(info)
        Self.hoveredTarget = target
        trace("updated", info, target: target)
        onHoverMoved(target)
        reportGhost(target, info)
        return DropProposal(operation: target == .none ? .forbidden : .copy)
    }

    func dropExited(info: DropInfo) {
        Self.hoveredTarget = nil
        trace("exited", info, target: route(info))
        onHoverEnded(false)   // nothing to hand off at settle → close the gap on the spot
    }

    /// Temporary diagnostics (2026-09-08 "the plus sign keeps flickering"). Delete together with `HoverTrace.externalDrop` once it's sorted out.
    private func trace(_ phase: String, _ info: DropInfo, target: StripDropRouting.Target) {
        guard HoverTrace.isEnabled else { return }
        HoverTrace.externalDrop(phase: phase,
                                x: info.location.x,
                                isApp: DragPasteboardInspector.containsApplication(),
                                target: "\(target)",
                                fileTarget: "\(fileRoute(info))",
                                operation: target == .none ? "forbidden" : "copy",
                                ghostIndex: currentGhostIndex(),
                                frozenWidth: currentFrozenWidth(),
                                stripRect: currentStripRect())
    }

    func performDrop(info: DropInfo) -> Bool {
        let target = route(info)
        let fileTarget = fileRoute(info)
        let location = info.location
        Self.hoveredTarget = nil
        trace("perform", info, target: target)
        // Highlight goes out the moment the drop settles; clear synchronously (the system may still send an orphaned dropUpdated after this, which is ignored by the gating).
        // Pass true: the gap must be kept until the real icon enters the projection, closed by `keepDroppedApplications` / the `.pin` of `handleExternalDrop`
        // (plus a fallback Timer). A folder dropped *into* a chip fills no gap: close it now.
        let fillsGap: Bool
        switch target {
        case .keepApp:
            fillsGap = true
            // The gap follows the release point, while the session is still live, so the landing
            // takes over exactly the slot the app was let go in.
            reportGhost(target, info)
        case .pin: fillsGap = DragPasteboardInspector.pinsFolders()
        default: fillsGap = false
        }
        onHoverEnded(fillsGap)
        guard target != .none else { return false }
        let providers = info.itemProviders(for: [UTType.fileURL])
        guard !providers.isEmpty else { return false }
        // The fallback for an in-process drag (see `StripDropRouting.committedURLs`). The drag
        // pasteboard is readable only while the session lives — snapshot it before this returns.
        let pasteboardURLs = DragPasteboardInspector.draggedURLs()

        // Asynchronously gather all URLs, keeping the provider order, and commit once back on the main thread.
        let group = DispatchGroup()
        let box = ResultBox(count: providers.count)
        for (index, provider) in providers.enumerated() {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                box.set(url, at: index)
                group.leave()
            }
        }
        group.notify(queue: .main) {
            // Trash items are filtered here, before the app split, so a Trash `.app` cannot reach
            // the keep path either.
            let urls = StripDropRouting.committedURLs(
                loaded: box.urls,
                pasteboard: pasteboardURLs,
                homeDirectory: FileManager.default.homeDirectoryForCurrentUser
            )
            guard !urls.isEmpty else { return }
            // At the moment of settling, judge app identity once more from the **real URLs** (what was read during hover was the drag pasteboard, used only to
            // decide highlight and cursor). The routing split is hard: what `onCommit` receives never contains an app.
            let applications = urls.filter(DragPasteboardInspector.isApplication)
            let files = urls.filter { !DragPasteboardInspector.isApplication($0) }
            if !applications.isEmpty {
                onCommitApplications(applications, location)
            }
            if !files.isEmpty, fileTarget != .none {
                onCommit(fileTarget, files)
            }
        }
        return true
    }

    /// Drag pasteboard cheat sheet: answers **synchronously** during hover "is this drag an app or not".
    ///
    /// It must be synchronous: when `dropUpdated` returns `.forbidden` the system never calls `performDrop` at all,
    /// and an app's drop target covers the whole strip (including the window area, where for files it is `.none`). Fetching URLs asynchronously via `itemProviders`
    /// would mean "dragging from Finder in one motion and releasing in the window area" is already rejected before the URL arrives.
    /// `NSPasteboard(name: .drag)` is synchronously readable by the target process during a drag session, which fills exactly that gap.
    ///
    /// `dropUpdated` comes about every ~50ms, so cache by `changeCount`: read from disk only once within one drag session.
    enum DragPasteboardInspector {
        private struct Session {
            let changeCount: Int
            /// Every dragged URL is inside a Trash: the whole drop is refused.
            let containsOnlyTrashItems: Bool
            let containsApplication: Bool
            /// The id of the first app bundle. **Parsing Info.plist is a disk read**, so do it only once per drag session
            /// because `dropUpdated` fires about every ~50ms, and reading disk every time would bog down the main thread.
            let applicationBundleID: String?
            /// Every app bundle's id, deduped, in drag order — the drawer's make-way slot. Read in
            /// the same pass as the first.
            let applicationBundleIDs: [String]
            /// File URLs only, Trash items included (the caller filters them).
            let draggedURLs: [URL]
            /// `StripDropRouting.dragPinsFolders` over the non-app items. Read from disk once per session.
            let pinsFolders: Bool
        }
        private static var session: Session?

        /// Whether there is an app bundle on the drag pasteboard. Unreadable (pasteboard empty / not a file drag) is always false:
        /// keep the original file semantics; at settle it is judged once more from the real URLs.
        /// Called only on the main thread (all DropDelegate callbacks are on the main thread), so the cache needs no lock.
        static func containsApplication() -> Bool {
            currentSession().containsApplication
        }

        /// Whom the make-way gap should be shown for. `nil` = not an app drag, or the bundle is broken and no id can be read → no make-way.
        static func applicationBundleID() -> String? {
            currentSession().applicationBundleID
        }

        /// The ids the drawer's make-way slot shows and its drop lands (`DrawerView`).
        static func applicationBundleIDs() -> [String] {
            currentSession().applicationBundleIDs
        }

        static func containsOnlyTrashItems() -> Bool {
            currentSession().containsOnlyTrashItems
        }

        /// Whether the drag is folders only, so the folder zone pins it: that is what opens the
        /// make-way gap, splits a chip into pin edges and a move-into centre, and drops the badge.
        static func pinsFolders() -> Bool {
            currentSession().pinsFolders
        }

        /// The dragged file URLs, read synchronously. Readable only while the session is alive.
        static func draggedURLs() -> [URL] {
            currentSession().draggedURLs
        }

        /// Path components only — nothing inside the Trash is read.
        static func isInsideTrash(_ url: URL) -> Bool {
            TrashPath.isInsideTrash(url, homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
        }

        private static func currentSession() -> Session {
            let pasteboard = NSPasteboard(name: .drag)
            let changeCount = pasteboard.changeCount
            if let session, session.changeCount == changeCount { return session }
            let dragged = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
            // Trash items are filtered before the app check: a mixed drag keeps only the rest.
            let urls = dragged.filter { !isInsideTrash($0) }
            let apps = urls.filter(isApplication)
            let appIDs = apps.map { Bundle(url: $0)?.bundleIdentifier }
            var seen = Set<String>()
            let next = Session(
                changeCount: changeCount,
                containsOnlyTrashItems: !dragged.isEmpty && urls.isEmpty,
                containsApplication: !apps.isEmpty,
                applicationBundleID: appIDs.first.flatMap { $0 },
                applicationBundleIDs: appIDs.compactMap { $0 }.filter { seen.insert($0).inserted },
                draggedURLs: dragged.filter(\.isFileURL),
                pinsFolders: StripDropRouting.dragPinsFolders(
                    nonApplicationItemsAreDirectories: urls.filter { !isApplication($0) }.map { url in
                        url.isFileURL && ((try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false)
                    })
            )
            session = next
            return next
        }

        /// Whether it is an app bundle. Ask UTType first (recognizes bundles with changed case / no extension),
        /// and fall back to the extension if it can't be read. `.app` is itself a directory, so `isDirectoryKey` **must not** be used to decide.
        static func isApplication(_ url: URL) -> Bool {
            if let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType {
                return type.conforms(to: .application)
            }
            return url.pathExtension.lowercased() == "app"
        }
    }

    /// loadObject callbacks are on background threads; lock and write by position, preserving order.
    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var urls: [URL?]
        init(count: Int) { urls = Array(repeating: nil, count: count) }
        func set(_ url: URL?, at index: Int) {
            lock.lock(); defer { lock.unlock() }
            urls[index] = url
        }
    }
}

/// Removes the cursor badge over the Trash chip, a folder's pin slot and an app drag, and the
/// system drop animation of an app drag; everything else about the drop stays SwiftUI's.
///
/// SwiftUI's `.onDrop` only offers `.copy` (badge) / `.move` / `.forbidden`, and its real AppKit
/// destination is a private subview spanning the strip — `NSWindow`'s dragging methods are never
/// called during a session, so neither the window nor a parent view can rewrite the answer. AppKit
/// hands the drag to the topmost registered view instead, so this view sits **over** that subview
/// with the same frame (`.overlay` right after `.onDrop`), forwards every dragging message to it
/// unchanged, and rewrites only the returned operation. SwiftUI therefore sees exactly the session it
/// saw before — one enter, updates, one exit or perform — so highlight, ghost, frozen width and the
/// watchdog are untouched. A view covering only the Trash chip would split that into exit/enter pairs.
struct StripDropBadgeOverlay: NSViewRepresentable {
    func makeNSView(context: Context) -> ForwardingView { ForwardingView() }
    func updateNSView(_ nsView: ForwardingView, context: Context) {}

    final class ForwardingView: NSView {
        private weak var destination: NSView?

        /// Observes drags only; clicks, hover and scrolling go to the content below.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            resolveDestination()
            // SwiftUI may insert its destination view later in the same pass.
            DispatchQueue.main.async { [weak self] in self?.resolveDestination() }
        }

        override func layout() {
            super.layout()
            if destination?.window !== window { resolveDestination() }
        }

        /// Registered only while the SwiftUI destination is known, with its exact types: unregistered,
        /// AppKit targets SwiftUI directly and drops keep working (with the badge).
        private func resolveDestination() {
            let found = window == nil ? nil : Self.nearestDropDestination(from: self)
            destination = found
            let types = found?.registeredDraggedTypes ?? []
            if Set(types) != Set(registeredDraggedTypes) {
                unregisterDraggedTypes()
                if !types.isEmpty { registerForDraggedTypes(types) }
            }
        }

        /// The nearest registered view sharing an ancestor with `view` — the strip's only `.onDrop`.
        /// The ancestor itself counts too, in case a SwiftUI version handles drops in the hosting view.
        private static func nearestDropDestination(from view: NSView) -> NSView? {
            var ancestor = view.superview
            while let current = ancestor {
                if let found = firstRegistered(in: current, excluding: view) { return found }
                if !current.registeredDraggedTypes.isEmpty { return current }
                ancestor = current.superview
            }
            return nil
        }

        private static func firstRegistered(in root: NSView, excluding excluded: NSView) -> NSView? {
            for subview in root.subviews where subview !== excluded && !(subview is ForwardingView) {
                if !subview.registeredDraggedTypes.isEmpty { return subview }
                if let found = firstRegistered(in: subview, excluding: excluded) { return found }
            }
            return nil
        }

        private func liveDestination() -> NSView? {
            if destination?.window == nil { resolveDestination() }
            return destination
        }

        /// Read after forwarding: SwiftUI calls the delegate synchronously inside the forwarded call.
        private func answer(_ proposed: NSDragOperation, _ sender: NSDraggingInfo) -> NSDragOperation {
            let generic = StripDropRouting.usesGenericOperation(
                hoveredTarget: StripFileDropDelegate.hoveredTarget,
                pinsFolder: StripFileDropDelegate.DragPasteboardInspector.pinsFolders(),
                proposedIsCopy: proposed == .copy,
                sourceAllowsGeneric: sender.draggingSourceOperationMask.contains(.generic)
            )
            return generic ? .generic : proposed
        }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            guard let destination = liveDestination() else { return [] }
            return answer(destination.draggingEntered(sender), sender)
        }

        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            guard let destination = liveDestination() else { return [] }
            return answer(destination.draggingUpdated(sender), sender)
        }

        override func draggingExited(_ sender: NSDraggingInfo?) {
            destination?.draggingExited(sender)
        }

        /// SwiftUI turns `animatesToDestination` on inside this call; switching it off afterwards is
        /// what lets the drag image vanish on release. Setting it after `performDragOperation:` is too late.
        override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
            let accepted = destination?.prepareForDragOperation(sender) ?? false
            if StripDropRouting.suppressesSystemDropAnimation(hoveredTarget: StripFileDropDelegate.hoveredTarget) {
                sender.animatesToDestination = false
            }
            return accepted
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            destination?.performDragOperation(sender) ?? false
        }

        override func concludeDragOperation(_ sender: NSDraggingInfo?) {
            destination?.concludeDragOperation(sender)
        }

        override func draggingEnded(_ sender: NSDraggingInfo) {
            destination?.draggingEnded(sender)
        }
    }
}
