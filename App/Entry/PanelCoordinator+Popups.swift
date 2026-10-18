import AppKit
import ApplicationServices
import Combine
import QuartzCore
import SwiftUI
import os

// PanelCoordinator · folder / shelf / Trash popups: one live session at a time, each in its own
// window (the old one shrinks back while the new one opens), open/close animation, click-away.
/// A numeric-solver version of CAMediaTimingFunction: a CALayer implicit animation can only interpolate "a single property" as a whole,
/// while a popup switch has to interpolate the four semantic quantities centerX/bottomY/width/height separately and then reassemble the frame,
/// so it can only step progress by time itself. It takes the caller's existing CAMediaTimingFunction directly instead of redefining
/// the control points (the two call sites use different curves: PopoverAnimation.curve() and .easeInEaseOut).
/// Same as WebKit UnitBezier: Newton iteration solves x(t)=elapsed, then takes y(t) as the easing progress, with bisection as a fallback when the iteration doesn't converge.
private struct UnitBezierEase {
    private let ax, bx, cx: Double
    private let ay, by, cy: Double

    init(_ timingFunction: CAMediaTimingFunction) {
        var p1 = [Float](repeating: 0, count: 2)
        var p2 = [Float](repeating: 0, count: 2)
        timingFunction.getControlPoint(at: 1, values: &p1)
        timingFunction.getControlPoint(at: 2, values: &p2)
        let (p1x, p1y, p2x, p2y) = (Double(p1[0]), Double(p1[1]), Double(p2[0]), Double(p2[1]))
        cx = 3 * p1x; bx = 3 * (p2x - p1x) - cx; ax = 1 - cx - bx
        cy = 3 * p1y; by = 3 * (p2y - p1y) - cy; ay = 1 - cy - by
    }

    private func sampleX(_ t: Double) -> Double { ((ax * t + bx) * t + cx) * t }
    private func sampleY(_ t: Double) -> Double { ((ay * t + by) * t + cy) * t }
    private func sampleDX(_ t: Double) -> Double { (3 * ax * t + 2 * bx) * t + cx }

    private func solveX(_ x: Double) -> Double {
        var t = x
        for _ in 0..<8 {
            let dx = sampleX(t) - x
            if abs(dx) < 1e-6 { return t }
            let d = sampleDX(t)
            if abs(d) < 1e-6 { break }
            t -= dx / d
        }
        var lo = 0.0, hi = 1.0
        t = x
        while lo < hi {
            let cur = sampleX(t)
            if abs(cur - x) < 1e-6 { return t }
            if x > cur { lo = t } else { hi = t }
            t = (hi - lo) / 2 + lo
        }
        return t
    }

    func progress(at t: Double) -> Double { sampleY(solveX(t)) }
}

extension PanelCoordinator {
    // MARK: - Entry points

    /// Chip / gesture entry: the same content again closes it; anything else opens a new session
    /// (the live one shrinks back meanwhile). `anchorVisibleRect` is the chip's rect on screen.
    func toggleFolderPopup(path: String, anchorVisibleRect: CGRect, origin: FolderPopupOrigin) {
        if openPopupContent == .folder(path: path) {
            closeFolderPopup()
        } else if allowsPopupOpening(.folder(path: path)) {
            openFolderPopup(path: path, anchorVisibleRect: anchorVisibleRect, origin: origin)
        }
    }

    func toggleShelfPopup(anchorVisibleRect: CGRect) {
        if openPopupContent == .shelf {
            closeFolderPopup()
        } else if allowsPopupOpening(.shelf) {
            openShelfPopup(anchorVisibleRect: anchorVisibleRect)
        }
    }

    func toggleTrashPopup(anchorVisibleRect: CGRect) {
        if openPopupContent == .trash {
            closeFolderPopup()
        } else if allowsPopupOpening(.trash) {
            openTrashPopup(anchorVisibleRect: anchorVisibleRect)
        }
    }

    private static func cooldownKey(_ content: PopupContent) -> String {
        switch content {
        case let .folder(path): return path
        case .shelf: return "\u{0}shelf"
        case .trash: return "\u{0}trash"
        }
    }

    private func allowsPopupOpening(_ content: PopupContent) -> Bool {
        popupReopenCooldown.allowsOpening(path: Self.cooldownKey(content), at: CACurrentMediaTime())
    }

    /// How this opening of a folder shows. Only a pinned folder's chip reads its view mode; the
    /// count comes from the preload, and without one the grid opens (it takes late content, a
    /// fan's first frame must be whole).
    private func folderPresentation(path: String, origin: FolderPopupOrigin,
                                    entries: [FolderContentsLoader.Entry]?) -> FolderPopupView {
        guard origin == .pinnedFolder else { return .grid }
        let mode = pinnedFolderStore.viewMode(for: path)
        if mode == .list { return .list }
        guard let entries, let dock = dockPanel else { return .grid }
        let screen = Self.screenGeometry(panelCurrentScreen(panel: dock))
        let stage = StackStage.height(
            screenHeightBelowMenuBar: screen.topUsableY - screen.frame.minY,
            barOccupiedHeight: layoutMetrics.bottomGap + layoutMetrics.panelHeight)
        return FolderViewResolution.resolve(mode: mode, fileCount: entries.count, stageHeight: stage)
    }

    private func openFolderPopup(path: String, anchorVisibleRect: CGRect, origin: FolderPopupOrigin) {
        let rootURL = URL(fileURLWithPath: path)
        let sortOrder = pinnedFolderStore.sortOrder(for: path)
        // First open of a folder we pinned ourselves (Downloads on a fresh install): only now may
        // it be read, so the system's access prompt follows the user's own click.
        if pinnedFolderStore.noteOpened(path) {
            folderCoverStore.sync(paths: pinnedFolderStore.folderPaths)
        }
        // Hybrid fallback: check the hot cache first (0ms, and sort consistency is verified); on a miss, fall back to a short preload (blocking at most 150ms), ensuring the first frame is complete.
        let preloadedEntries = folderCoverStore.cachedEntries(for: path, order: sortOrder)
            ?? FolderContentsLoader.preload(url: rootURL, timeout: 0.15, order: sortOrder)

        switch folderPresentation(path: path, origin: origin, entries: preloadedEntries) {
        case .list:
            presentListPopup(path: path, entries: preloadedEntries, anchorVisibleRect: anchorVisibleRect)
        case let .fan(fileItems, hiddenCount):
            presentFanPopup(path: path, entries: Array((preloadedEntries ?? []).prefix(fileItems)),
                            hiddenCount: hiddenCount, anchorVisibleRect: anchorVisibleRect)
        case .grid:
            // A complete first frame **includes icons**: warm the icon cache of the first batch of visible cells, otherwise the cells appear first and the icons surface one by one from the top-left in parse order.
            if let entries = preloadedEntries {
                FolderIconResolver.warm(paths: entries.prefix(Self.popupWarmCount).map(\.url.path), timeout: 0.1)
            }
            let session = beginPopupSession(content: .folder(path: path), origin: origin,
                                            presentation: .grid, anchor: anchorVisibleRect)
            presentGridPopup(session) { [weak self] context in
                self?.makeFolderGridHosting(session: session, rootURL: rootURL, entries: preloadedEntries,
                                            sortOrder: sortOrder, context: context) ?? NSView()
            }
        }
    }

    private func makeFolderGridHosting(session: FolderPopupSession, rootURL: URL,
                                       entries: [FolderContentsLoader.Entry]?, sortOrder: FolderSortOrder,
                                       context: StackPopupContext) -> NSView {
        let id = session.id
        return NSHostingView(rootView: FolderGridPopupView(
            rootURL: rootURL,
            initialEntries: entries,
            sortOrder: sortOrder,
            context: context,
            usesLiquidGlass: usesLiquidGlass,
            onFileOpened: { [weak self] in self?.closeFolderPopup(sessionID: id) },
            onContentResize: { [weak self] size in self?.repositionFolderPopup(sessionID: id, animated: true, contentSize: size) },
            onPinFolder: { [weak self] url in self?.pinnedFolderStore.add(url.path) },
            isFolderPinned: { [weak self] url in self?.pinnedFolderStore.contains(url.path) ?? true }
        ))
    }

    private func openShelfPopup(anchorVisibleRect: CGRect) {
        shelfStore.prune()   // on open, drop stale references (files moved away / deleted)
        // Same as openFolderPopup: icons are fully lit on the first frame, not surfacing one by one.
        FolderIconResolver.warm(paths: Array(shelfStore.itemPaths.prefix(Self.popupWarmCount)), timeout: 0.1)
        let session = beginPopupSession(content: .shelf, origin: .pinnedFolder,
                                        presentation: .grid, anchor: anchorVisibleRect)
        let id = session.id
        presentGridPopup(session) { [weak self, shelfStore] context in
            NSHostingView(rootView: ShelfGridPopupView(
                shelfStore: shelfStore,
                context: context,
                usesLiquidGlass: self?.usesLiquidGlass ?? false,
                onClosePopup: { [weak self] in self?.closeFolderPopup(sessionID: id) },
                onContentResize: { [weak self] size in self?.repositionFolderPopup(sessionID: id, animated: true, contentSize: size) },
                onPinFolder: { [weak self] url in self?.pinnedFolderStore.add(url.path) },
                isFolderPinned: { [weak self] url in self?.pinnedFolderStore.contains(url.path) ?? true }
            ))
        }
    }

    /// Opens on whatever listing the store still holds and refreshes from Finder behind it: a loaded
    /// Finder answers the listing in ~1s, far too long to hold the first frame for.
    private func openTrashPopup(anchorVisibleRect: CGRect) {
        let store = TrashStateStore.shared
        let session = beginPopupSession(content: .trash, origin: .pinnedFolder,
                                        presentation: .grid, anchor: anchorVisibleRect)
        let id = session.id
        presentGridPopup(session) { [weak self, runtime] context in
            NSHostingView(rootView: TrashGridPopupView(
                trashStore: store,
                context: context,
                usesLiquidGlass: self?.usesLiquidGlass ?? false,
                onClosePopup: { [weak self] in self?.closeFolderPopup(sessionID: id) },
                onContentResize: { [weak self] size in self?.repositionFolderPopup(sessionID: id, animated: true, contentSize: size) },
                onOpenInFinder: { [weak self] in
                    self?.closeFolderPopup(sessionID: id)
                    TrashStateStore.openTrashWindow(runtime: runtime, store: store)
                }
            ))
        }
        // After presenting: the session that just went away cleared the listing when it closed.
        store.loadItems()
    }

    /// Type icons warmed before the popup shows: one screenful on a large display.
    private static let popupWarmCount = 60

    // MARK: - Sessions

    /// Starts a new live session. The old live one, if any, closes the way any outside click
    /// closes it — animated, in its own window — so the two overlap as on the native Dock.
    private func beginPopupSession(content: PopupContent, origin: FolderPopupOrigin,
                                   presentation: FolderPopupSession.Presentation,
                                   anchor: CGRect) -> FolderPopupSession {
        onAccessoryWillOpen?(self, .popup)
        if activePopupSession != nil { closeFolderPopup() }
        popupSessionCounter += 1
        let session = FolderPopupSession(id: popupSessionCounter, content: content, origin: origin,
                                         presentation: presentation, anchor: anchor)
        activePopupSession = session
        setAutoHideInhibitor(.folderPopupOpen, active: true)
        if origin == .pinnedFolder, case let .folder(path) = content {
            if presentation == .list {
                folderPopupPresence.show(path: path, style: .dimmedOnly, sessionID: session.id)
                folderPopupWillShow(path: path)
            } else {
                folderPopupPresence.show(path: path, style: .opening, sessionID: session.id)
            }
        }
        return session
    }

    /// A pinned folder's fan or grid shows on the same frame as its chip's square + arrow, as on
    /// the native Dock. A new popup window reaches the screen 40–100ms after the bar's own update,
    /// so it goes on screen transparent first and `reveal` runs — window shown, open animation,
    /// chip swapped, in one turn — once Core Animation reports it has the window's layers. Any
    /// other popup reveals at once. The timer covers a report that never comes.
    private func revealWhenRendered(_ session: FolderPopupSession, panel: NSPanel,
                                    reveal: @escaping () -> Void) {
        guard session.origin == .pinnedFolder, case .folder = session.content,
              let layer = panel.contentView?.layer else {
            reveal()
            return
        }
        panel.alphaValue = 0
        var revealed = false
        let revealOnce = { [weak self, weak session, weak panel] in
            guard !revealed, let self, let session, let panel, self.activePopupSession === session else { return }
            revealed = true
            panel.alphaValue = 1
            reveal()
            self.showOpenChip(for: session)
        }
        let probe = CABasicAnimation(keyPath: "opacity")
        probe.fromValue = 1
        probe.toValue = 1
        probe.duration = 1.0 / 60
        probe.delegate = AnimationStartSignal(revealOnce)
        layer.add(probe, forKey: "renderProbe")
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.revealFallbackDelay, execute: revealOnce)
    }

    private static let revealFallbackDelay: TimeInterval = 0.15

    private func showOpenChip(for session: FolderPopupSession) {
        guard activePopupSession === session, session.origin == .pinnedFolder,
              case let .folder(path) = session.content else { return }
        folderPopupPresence.show(path: path, style: .pileArrow, sessionID: session.id)
        folderPopupWillShow(path: path)
    }

    /// A fresh window per session. A borderless transparent window lets clicks through its clear
    /// pixels only while `ignoresMouseEvents` was never set; once set (an exiting popup takes no
    /// clicks) it can't go back, and its 40pt border would swallow clicks meant for the chips
    /// under it. Windows are cheap; the session's ends with it.
    private func makePopupPanel() -> NSPanel {
        let panel = sparePopupPanel ?? newPopupPanel()
        sparePopupPanel = nil
        folderPopupPanels.append(panel)
        DispatchQueue.main.async { [weak self] in self?.prepareSparePopupPanel() }
        return panel
    }

    /// A window already on screen (1 × 1, empty, clicks pass through its clear pixels): a popup
    /// in a window ordered in at the click showed ~75ms later than one handed a window already
    /// on screen.
    func prepareSparePopupPanel() {
        guard sparePopupPanel == nil, let dock = dockPanel else { return }
        let panel = newPopupPanel()
        let screen = panelCurrentScreen(panel: dock).frame
        panel.contentView = NSView()
        panel.setFrame(CGRect(x: screen.minX, y: screen.maxY - 1, width: 1, height: 1), display: false)
        panel.orderFrontRegardless()
        pinOverlappingPanelIfNeeded(panel)
        sparePopupPanel = panel
    }

    private func newPopupPanel() -> NSPanel {
        let panel = makeFloatingPanel(contentRect: NSRect(origin: .zero, size: lastPopupSize),
                                      usesLiquidGlass: usesLiquidGlass)
        configurePanel(panel, backgroundColor: NSColor(white: 1.0, alpha: 0.0), appliesLevelOverride: false)
        panel.isReleasedWhenClosed = false
        return panel
    }

    private func presentGridPopup(_ session: FolderPopupSession, makeHosting: (StackPopupContext) -> NSView) {
        guard let mainPanel = dockPanel else { return }
        let panel = makePopupPanel()
        session.panel = panel

        let screenGeometry = Self.screenGeometry(panelCurrentScreen(panel: mainPanel))
        let arrow = StackPopupArrowModel()
        session.arrow = arrow
        let context = StackPopupContext(
            limits: StackGridLayout.limits(
                screenSize: screenGeometry.frame.size,
                availablePlateHeight: PanelGeometry.stackPopupAvailablePlateHeight(
                    anchorVisibleRect: session.anchor, on: screenGeometry)),
            arrow: arrow)

        let hosting = makeHosting(context)
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.0).cgColor

        // Same as the drawer: an ordinary NSView container + the hosting view pinned in, to prevent the top edge anchoring and stretching downward when an NSHostingView is the contentView (AGENTS guardrail).
        let container = NSView(frame: NSRect(origin: .zero, size: lastPopupSize))
        container.wantsLayer = true
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        panel.contentView = container
        session.contentHost = hosting

        // Settle on the first frame: synchronously measure the real size **before** orderFront, so the first frame is already the final size. If a reasonable value can't be measured, fall back to lastPopupSize;
        // the later double-defer re-measurement is still there as a fallback correction.
        panel.layoutIfNeeded()
        let sync = hosting.fittingSize
        if sync.width >= 160, sync.height >= 100 {
            lastPopupSize = sync
        }
        let initialFrame = PanelGeometry.folderPopupTargetFrame(
            anchorVisibleRect: session.anchor, size: lastPopupSize, on: screenGeometry, metrics: layoutMetrics)
        lastPopupTargetFrame = initialFrame
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            setFolderPopupFrame(initialFrame, session: session, display: false)
        }
        // The arrow's position was only known with the frame: lay it out before the first show.
        hosting.layoutSubtreeIfNeeded()
        revealWhenRendered(session, panel: panel) { [weak self] in self?.playGridOpen(session) }
        panel.orderFrontRegardless()
        pinOverlappingPanelIfNeeded(panel)
        session.openedAt = Date()

        // Re-measure fittingSize after popping up (double defer waits for SwiftUI layout to finish): a fallback correction for when the synchronous measurement is off, instantaneous.
        let id = session.id
        DispatchQueue.main.async { [weak self] in
            DispatchQueue.main.async { [weak self] in
                self?.repositionFolderPopup(sessionID: id, animated: false)
            }
        }
        installPopupMonitors()
    }

    /// Sort changed with the grid open: the content is rebuilt in the same window and the frame
    /// slides to the new size; nothing closes.
    private func reloadGridInPlace(_ session: FolderPopupSession, makeHosting: (StackPopupContext) -> NSView) {
        guard let panel = session.panel, let container = panel.contentView, let dock = dockPanel else { return }
        let screenGeometry = Self.screenGeometry(panelCurrentScreen(panel: dock))
        let arrow = session.arrow ?? StackPopupArrowModel()
        session.arrow = arrow
        let context = StackPopupContext(
            limits: StackGridLayout.limits(
                screenSize: screenGeometry.frame.size,
                availablePlateHeight: PanelGeometry.stackPopupAvailablePlateHeight(
                    anchorVisibleRect: session.anchor, on: screenGeometry)),
            arrow: arrow)
        let hosting = makeHosting(context)
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.0).cgColor
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        session.contentHost?.removeFromSuperview()
        container.addSubview(hosting)
        session.contentHost = hosting
        panel.layoutIfNeeded()
        let sync = hosting.fittingSize
        if sync.width >= 160, sync.height >= 100 { lastPopupSize = sync }
        let target = PanelGeometry.folderPopupTargetFrame(
            anchorVisibleRect: session.anchor, size: lastPopupSize, on: screenGeometry, metrics: layoutMetrics)
        lastPopupTargetFrame = target
        animateFolderPopupFrame(session: session, to: target,
                                duration: PopoverAnimation.openDuration, timingFunction: PopoverAnimation.curve())
    }

    /// Ends the live session if it is still `sessionID` (content callbacks of a session that has
    /// already been replaced must not close the new one).
    func closeFolderPopup(sessionID: Int) {
        guard activePopupSession?.id == sessionID else { return }
        closeFolderPopup()
    }

    /// The single way a popup closes (every outside path — screen change, layout, fullscreen,
    /// hide, another unit's accessory — calls this). Animated: the live session turns into the
    /// exiting one and plays its close in its own window. `immediately` also ends an exiting one.
    func closeFolderPopup(immediately: Bool = false) {
        if immediately { finishExitingPopupSession() }
        guard let session = activePopupSession else { return }
        activePopupSession = nil
        popupReopenCooldown.noteClosed(path: Self.cooldownKey(session.content), at: CACurrentMediaTime())
        if session.content == .trash { TrashStateStore.shared.clearListing() }
        setAutoHideInhibitor(.folderPopupOpen, active: false)
        removePopupMonitors()
        cancelFolderPopupFrameTween()   // on close, any in-flight tween must stop, so it doesn't sneakily move the frame after orderOut
        folderPopupPresence.clear(sessionID: session.id)

        switch session.presentation {
        case .list:
            session.listMenu?.cancelTracking()
        case .grid, .fan:
            guard let panel = session.panel else { return }
            // Not revealed yet: nothing on screen to fly back, and the chip still looks closed.
            let userClose = !immediately && panel.isVisible && panel.alphaValue > 0
            if !userClose || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                endPopupWindow(of: session)
                if userClose, session.origin == .pinnedFolder, case let .folder(path) = session.content {
                    folderPopupWillClose(path: path)
                }
                return
            }
            finishExitingPopupSession()
            exitingPopupSession = session
            // A popup on its way out takes no clicks: they land on whatever the user aimed at.
            panel.ignoresMouseEvents = true
            // It shrinks or flies back into the chip over the bar's glass, as on the native Dock.
            // Same level as the bar is not enough: the click on the chip that closes it orders the
            // bar's windows above it.
            let barLevel = ([dockPanel?.level, dockGlassBackgroundPanel?.level].compactMap { $0 } + [.floating])
                .map(\.rawValue).max() ?? NSWindow.Level.floating.rawValue
            panel.level = NSWindow.Level(rawValue: barLevel + 1)
            if session.presentation == .fan {
                playFanClose(session)
            } else {
                playGridClose(session)
            }
            if session.origin == .pinnedFolder, case let .folder(path) = session.content {
                folderPopupWillClose(path: path)
            }
        }
    }

    /// Takes the exiting session's window off screen now (another session needs it, or an
    /// immediate close).
    private func finishExitingPopupSession() {
        guard let exiting = exitingPopupSession else { return }
        exitingPopupSession = nil
        endPopupWindow(of: exiting)
    }

    /// Off screen and gone: dropping the content stops its directory watcher.
    private func endPopupWindow(of session: FolderPopupSession) {
        folderPopupPresence.endLanding(sessionID: session.id)
        for panel in [session.panel, session.clickCatcher].compactMap({ $0 }) {
            panel.contentView?.layer?.removeAllAnimations()
            panel.orderOut(nil)
            panel.contentView = NSView()
            panel.close()
            folderPopupPanels.removeAll { $0 === panel }
        }
        session.panel = nil
        session.clickCatcher = nil
        session.contentHost = nil
    }

    // MARK: - Grid open / close (native: the whole plate grows out of the chip and shrinks back)

    /// Where the grid scales from, in the container's coordinates: the chip's centre, held at the
    /// window's bottom edge when the chip sits lower (only on bars taller than 74pt).
    private func gridScalePivot(_ session: FolderPopupSession, panel: NSPanel) -> CGPoint {
        let frame = panel.frame
        return CGPoint(x: session.anchor.midX - frame.minX,
                       y: max(0, session.anchor.midY - frame.minY))
    }

    /// A transform scaling by `scale` about `pivot`. AppKit keeps a layer-backed view's anchor
    /// point at its origin and may reset it on resize, so the pivot lives in the transform.
    private static func scaleTransform(_ scale: CGFloat, about pivot: CGPoint) -> CATransform3D {
        var t = CATransform3DMakeTranslation(pivot.x, pivot.y, 0)
        t = CATransform3DScale(t, scale, scale, 1)
        return CATransform3DTranslate(t, -pivot.x, -pivot.y, 0)
    }

    private func playGridOpen(_ session: FolderPopupSession) {
        guard let panel = session.panel, let layer = panel.contentView?.layer,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let pivot = gridScalePivot(session, panel: panel)
        let scale = CABasicAnimation(keyPath: "transform")
        scale.fromValue = NSValue(caTransform3D: Self.scaleTransform(1e-5, about: pivot))
        scale.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = PopoverAnimation.stackDuration
        group.timingFunction = PopoverAnimation.gridCurve()
        layer.add(group, forKey: "stackOpen")
    }

    private func playGridClose(_ session: FolderPopupSession) {
        guard let panel = session.panel, let layer = panel.contentView?.layer else {
            endPopupWindow(of: session)
            return
        }
        // From wherever the open animation is now, back into the chip.
        let presentation = layer.presentation()
        let fromTransform = presentation?.transform ?? CATransform3DIdentity
        let fromOpacity = presentation?.opacity ?? 1
        layer.removeAnimation(forKey: "stackOpen")
        let pivot = gridScalePivot(session, panel: panel)
        let scale = CABasicAnimation(keyPath: "transform")
        scale.fromValue = NSValue(caTransform3D: fromTransform)
        scale.toValue = NSValue(caTransform3D: Self.scaleTransform(1e-5, about: pivot))
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = fromOpacity
        fade.toValue = 0.2
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = PopoverAnimation.stackDuration
        group.timingFunction = PopoverAnimation.gridCurve()
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        let id = session.id
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.exitingPopupSession?.id == id else { return }
                self.finishExitingPopupSession()
            }
        }
        layer.add(group, forKey: "stackClose")
        CATransaction.commit()
    }

    // MARK: - Click-away

    private func installPopupMonitors() {
        removePopupMonitors()
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        popupLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.dismissFolderPopupIfOutside(isRightClick: event.type == .rightMouseDown)
            return event
        }
        popupGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.dismissFolderPopupIfOutside(isRightClick: event.type == .rightMouseDown)
        }
    }

    private func removePopupMonitors() {
        if let m = popupLocalMonitor  { NSEvent.removeMonitor(m); popupLocalMonitor  = nil }
        if let m = popupGlobalMonitor { NSEvent.removeMonitor(m); popupGlobalMonitor = nil }
    }

    /// Whether a screen point is on the live popup — what the user sees, never the window's
    /// transparent border. Grid: the plate. List: never (the menu tracks itself).
    func folderPopupContains(_ point: CGPoint) -> Bool {
        guard let session = activePopupSession, let panel = session.panel else { return false }
        switch session.presentation {
        case .grid:
            return PanelGeometry.folderPopupPlateFrame(panelFrame: panel.frame).contains(point)
        case .fan:
            return session.fanView?.layout.itemIndex(at: point) != nil
        case .list:
            return false
        }
    }

    /// click-away: don't close inside the popup; on left click, **also don't close inside the anchor chip (+4pt tolerance)**: the monitor closes on mouseDown and the chip's
    /// onTapGesture reopens on mouseUp; without excluding the anchor, a click on the same chip would flicker open↔close forever (a race confirmed in review, do not delete).
    /// A right click anywhere off the popup closes it, the anchor chip included, as on the native Dock.
    private func dismissFolderPopupIfOutside(isRightClick: Bool) {
        guard let session = activePopupSession else { return }
        let mouse = NSEvent.mouseLocation
        guard !folderPopupContains(mouse) else { return }
        if !isRightClick, session.anchor.insetBy(dx: -4, dy: -4).contains(mouse) { return }
        closeFolderPopup()
    }

    // MARK: - Frame

    /// Every frame the popup window gets goes through here: the arrow has to follow the chip
    /// whenever the plate is clamped off-centre, mid-tween included.
    private func setFolderPopupFrame(_ frame: NSRect, session: FolderPopupSession, display: Bool) {
        guard let panel = session.panel else { return }
        panel.setFrame(frame, display: display)
        let offset = session.anchor.midX - frame.midX
        if session.arrow?.offsetFromCenter != offset { session.arrow?.offsetFromCenter = offset }
    }

    /// Content size change (first measurement / drill-down / live refresh) → recompute the target frame from the anchor. Both width and height are derived from the content (the column count determines the width).
    /// `contentSize` is the window size the content derived from its layout; nil measures it,
    /// which is only valid outside a SwiftUI update (`fittingSize` reads zero inside one).
    private func repositionFolderPopup(sessionID: Int, animated: Bool, contentSize: CGSize? = nil) {
        guard let session = activePopupSession, session.id == sessionID, session.presentation == .grid,
              session.panel != nil,
              let hosting = session.contentHost,
              let dock = dockPanel else { return }
        // Always correct instantly during the entrance window, without stacking on the entrance animation and causing wobble.
        let animated = animated && Date().timeIntervalSince(session.openedAt) > PopoverAnimation.stackDuration
        let size: CGSize
        if let contentSize {
            size = contentSize
        } else {
            // Smaller than any plate = not laid out yet, never a size: keep the last good one.
            let fitting = hosting.fittingSize
            size = fitting.width >= 160 && fitting.height >= 100 ? fitting : lastPopupSize
        }
        lastPopupSize = size
        let screen = panelCurrentScreen(panel: dock)
        let target = PanelGeometry.folderPopupTargetFrame(
            anchorVisibleRect: session.anchor, size: size, on: Self.screenGeometry(screen), metrics: layoutMetrics)
        lastPopupTargetFrame = target

        if folderPopupFrameTimer != nil {
            // A hand-rolled tween is in flight (most likely the transition animation just triggered): the double-defer fallback correction must not interrupt it instantly,
            // it only corrects its end point to the latest measured value and lets it keep flying.
            animateFolderPopupFrame(session: session, to: target,
                                    duration: PopoverAnimation.openDuration, timingFunction: PopoverAnimation.curve())
        } else if animated {
            animateFolderPopupFrame(session: session, to: target,
                                    duration: Self.layoutAnimationDuration,
                                    timingFunction: CAMediaTimingFunction(name: .easeInEaseOut))
        } else {
            setFolderPopupFrame(target, session: session, display: true)
        }
    }

    /// The unified cancel entry for popup switch/reposition tweens: invalidate can't stop a callback that "has already fired but whose Task hasn't run yet",
    /// so the token is incremented to let stale queued tasks turn themselves into no-ops in the tick.
    private func cancelFolderPopupFrameTween() {
        folderPopupFrameTimer?.invalidate()
        folderPopupFrameTimer = nil
        folderPopupTweenTarget = nil
        folderPopupTweenToken &+= 1
    }

    /// Per-frame frame computation of the popup reposition tween: interpolate the "desired center point" (the unclamped anchor center) + width/height, and re-run the
    /// centering + clamping formula every frame, the same rules as `PanelGeometry.folderPopupTargetFrame`, guaranteeing any intermediate size behaves
    /// as if "really anchored on this chip at this size". The first-frame start is back-derived from `start`'s own center, so there is no jump at p=0;
    /// the end point uses the anchor interpolated to the target's width, landing exactly back on target at p=1.
    private func animateFolderPopupFrame(
        session: FolderPopupSession, to target: NSRect, duration: TimeInterval, timingFunction: CAMediaTimingFunction
    ) {
        // Already flying toward the same target → don't restart, let it finish on its original clock.
        if folderPopupFrameTimer != nil, folderPopupTweenTarget == target { return }
        cancelFolderPopupFrameTween()
        let token = folderPopupTweenToken
        guard let panel = session.panel else { return }

        let start = panel.frame
        guard start != target, duration > 0, let dock = dockPanel else {
            setFolderPopupFrame(target, session: session, display: true)
            return
        }
        let screen = Self.screenGeometry(panelCurrentScreen(panel: dock))

        let ease = UnitBezierEase(timingFunction)
        let (w0, w1) = (start.width, target.width)
        let (h0, h1) = (start.height, target.height)
        let anchor = session.anchor
        let startCenterX = start.midX
        let endCenterX = anchor.midX
        let startBottomY = start.minY
        let endBottomY = PanelGeometry.folderPopupDesiredBottomY(anchorVisibleRect: anchor)
        // The screen margins are a tweened quantity too: starting from the ones the current frame
        // holds keeps p=0 on that frame; ending on the anchor's lands p=1 on the target.
        let startMargins = PanelGeometry.folderPopupScreenMargins(holding: start, on: screen)
        let endMargins = PanelGeometry.folderPopupScreenMargins(anchorCenterX: anchor.midX, on: screen)
        let clockStart = CACurrentMediaTime()
        let sessionID = session.id

        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] t in
            Task { @MainActor [weak self] in
                guard let self, self.folderPopupTweenToken == token,
                      let session = self.activePopupSession, session.id == sessionID else {
                    t.invalidate()
                    return
                }
                let raw = min(max((CACurrentMediaTime() - clockStart) / duration, 0), 1)
                if raw >= 1 {
                    self.setFolderPopupFrame(target, session: session, display: true)
                    self.folderPopupFrameTimer = nil
                    self.folderPopupTweenTarget = nil
                    t.invalidate()
                } else {
                    let p = ease.progress(at: raw)
                    let width = w0 + (w1 - w0) * p
                    let height = h0 + (h1 - h0) * p
                    let origin = PanelGeometry.folderPopupClampedOrigin(
                        desiredCenterX: startCenterX + (endCenterX - startCenterX) * p,
                        desiredBottomY: startBottomY + (endBottomY - startBottomY) * p,
                        size: CGSize(width: width, height: height),
                        margins: startMargins.interpolated(to: endMargins, progress: p),
                        on: screen)
                    self.setFolderPopupFrame(NSRect(origin: origin, size: CGSize(width: width, height: height)),
                                             session: session, display: true)
                }
            }
        }
        folderPopupFrameTimer = timer
        folderPopupTweenTarget = target
        RunLoop.main.add(timer, forMode: .common)
    }

    // MARK: - Fan

    private func presentFanPopup(path: String, entries: [FolderContentsLoader.Entry], hiddenCount: Int,
                                 anchorVisibleRect anchor: CGRect) {
        guard let dock = dockPanel else { return }
        let session = beginPopupSession(content: .folder(path: path), origin: .pinnedFolder,
                                        presentation: .fan, anchor: anchor)
        let id = session.id
        let folderURL = URL(fileURLWithPath: path)
        // The first frame is whole: a fan holds at most a screenful of items, warm them all.
        FolderIconResolver.warm(paths: entries.map(\.url.path), timeout: 0.1)

        var items = entries.map { StackFanItem(kind: .entry($0), title: $0.name) }
        items.append(StackFanItem(kind: .openInFinder,
                                  title: hiddenCount > 0
                                      ? FolderViewResolution.moreInFinderTitle(hiddenCount: hiddenCount)
                                      : String(localized: "Open in Finder")))
        let font = NSFont.systemFont(ofSize: StackFanLayout.labelFontSize)
        let labelSizes = items.map { item in
            StackFanLayout.labelSize(textSize: (item.title as NSString).size(withAttributes: [.font: font]))
        }
        let scale = settingsStore.dockPanelHeight.scale
        let tileCenter = CGPoint(x: anchor.midX, y: anchor.midY)
        let layout = StackFanLayout(tileCenter: tileCenter,
                                    squareSide: ChipPillMetrics.bareIconVisibleSlot * scale,
                                    labelSizes: labelSizes)
        // Items fly out of the cover the chip showed: its pile's layers, or the whole slot when
        // it showed the folder's own icon.
        let slot = ChipPillMetrics.bareIconSlot * scale
        let showsPile = pinnedFolderStore.displayMode(for: path) == .stack
            && !(folderCoverStore.covers[path]?.layers.isEmpty ?? true)
        let slotRect = CGRect(x: tileCenter.x - slot / 2, y: tileCenter.y - slot / 2, width: slot, height: slot)
        let pileRects = items.indices.map { index in
            showsPile ? FolderCoverPile.layerRect(index, slotCenter: tileCenter, slot: slot) : slotRect
        }
        let flightFrame = pileRects.reduce(layout.boundingBox.union(slotRect)) { $0.union($1) }
            .insetBy(dx: -2, dy: -2).integral
        var restFrame = flightFrame
        restFrame.origin.y = max(flightFrame.minY, anchor.maxY)
        restFrame.size.height = flightFrame.maxY - restFrame.minY
        session.fanFlightFrame = flightFrame
        session.fanRestFrame = restFrame

        let panel = makePopupPanel()
        session.panel = panel
        let reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let fan = StackPopupFanView(
            items: items, layout: layout, pileRects: pileRects, windowFrame: flightFrame,
            actions: .init(
                activate: { [weak self] index in
                    guard let self, self.activePopupSession?.id == id else { return }
                    if index < entries.count {
                        NSWorkspace.shared.open(entries[index].url)
                    } else {
                        NSWorkspace.shared.open(folderURL)
                    }
                    self.closeFolderPopup(sessionID: id)
                },
                dismiss: { [weak self] in self?.closeFolderPopup(sessionID: id) },
                menu: { [weak self] index in
                    guard index < entries.count else { return nil }
                    let entry = entries[index]
                    let canPin = entry.isDirectory && !(self?.pinnedFolderStore.contains(entry.url.path) ?? true)
                    return FileItemMenuBuilder.menu(for: .init(
                        url: entry.url,
                        isDirectory: entry.isDirectory,
                        closePopup: { [weak self] in self?.closeFolderPopup(sessionID: id) },
                        pinFolder: canPin ? { [weak self] in self?.pinnedFolderStore.add(entry.url.path) } : nil))
                }))
        session.fanView = fan
        session.contentHost = fan
        panel.contentView = fan
        panel.setFrame(reducedMotion ? restFrame : flightFrame, display: false)
        fan.windowWillTake(panel.frame)
        if reducedMotion {
            panel.ignoresMouseEvents = false
            fan.isInteractive = true
        } else {
            // While items fly the fan reaches down over the bar: it lets the bar have its clicks,
            // and a transparent panel above the bar's top takes the rest as clicks outside.
            panel.ignoresMouseEvents = true
            let barTop = dock.frame.maxY - Self.shadowPadding
            let catcherFrame = CGRect(x: flightFrame.minX, y: max(flightFrame.minY, barTop),
                                      width: flightFrame.width, height: flightFrame.maxY - max(flightFrame.minY, barTop))
            if catcherFrame.height > 0 {
                let catcher = makePopupPanel()
                catcher.contentView = StackPopupClickCatcher { [weak self] in self?.closeFolderPopup(sessionID: id) }
                catcher.setFrame(catcherFrame, display: false)
                catcher.ignoresMouseEvents = false
                session.clickCatcher = catcher
            }
        }
        panel.orderFrontRegardless()
        pinOverlappingPanelIfNeeded(panel)
        if let catcher = session.clickCatcher {
            catcher.orderFrontRegardless()
            pinOverlappingPanelIfNeeded(catcher)
        }
        fan.loadThumbnails(scale: dock.backingScaleFactor)
        session.openedAt = Date()
        installPopupMonitors()
        revealWhenRendered(session, panel: panel) {
            fan.playOpen(reducedMotion: reducedMotion) { [weak self] in
                Task { @MainActor [weak self] in self?.fanDidLand(sessionID: id) }
            }
        }
    }

    /// The flight is over: the catcher goes, the window stops at the chip's top and takes every
    /// click in it (a capsule or a gap is a click outside).
    private func fanDidLand(sessionID: Int) {
        guard let session = activePopupSession, session.id == sessionID,
              let panel = session.panel, let fan = session.fanView else { return }
        session.clickCatcher?.orderOut(nil)
        if let catcher = session.clickCatcher {
            catcher.close()
            folderPopupPanels.removeAll { $0 === catcher }
        }
        session.clickCatcher = nil
        panel.disableScreenUpdatesUntilFlush()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        panel.setFrame(session.fanRestFrame, display: true)
        fan.windowWillTake(session.fanRestFrame)
        CATransaction.commit()
        panel.ignoresMouseEvents = false
        fan.isInteractive = true
    }

    private func playFanClose(_ session: FolderPopupSession) {
        guard let panel = session.panel, let fan = session.fanView, case let .folder(path) = session.content else {
            endPopupWindow(of: session)
            return
        }
        session.clickCatcher?.orderOut(nil)
        // Back down over the chip: the items fly into it.
        panel.disableScreenUpdatesUntilFlush()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        panel.setFrame(session.fanFlightFrame, display: true)
        fan.windowWillTake(session.fanFlightFrame)
        CATransaction.commit()
        let stackShown = pinnedFolderStore.displayMode(for: path) == .stack
            && !(folderCoverStore.covers[path]?.layers.isEmpty ?? true)
        let id = session.id
        if stackShown { folderPopupPresence.beginLanding(path: path, sessionID: id) }
        fan.playClose(stackShown: stackShown) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.exitingPopupSession?.id == id else { return }
                self.finishExitingPopupSession()
            }
        }
    }

    // MARK: - List (a real system menu with the Dock's tipped bubble)

    private func presentListPopup(path: String, entries: [FolderContentsLoader.Entry]?, anchorVisibleRect: CGRect) {
        let session = beginPopupSession(content: .folder(path: path), origin: .pinnedFolder,
                                        presentation: .list, anchor: anchorVisibleRect)
        let id = session.id
        let store = pinnedFolderStore
        let menu = StackPopupListMenu(
            rootURL: URL(fileURLWithPath: path),
            entries: entries,
            sortOrder: store.sortOrder(for: path),
            displayMode: store.displayMode(for: path),
            viewMode: store.viewMode(for: path),
            actions: .init(
                setSortOrder: { store.setSortOrder($0, for: path) },
                setDisplayMode: { store.setDisplayMode($0, for: path) },
                setViewMode: { store.setViewMode($0, for: path) }))
        session.listMenu = menu
        // Next turn: the chip's tap gesture finishes first. The menu tracks modally from there.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.activePopupSession?.id == id,
                  let view = self.dockPanel?.contentView, let window = view.window else { return }
            let tipRect = StackPopupListMenu.tipRect(forChip: anchorVisibleRect, scale: self.settingsStore.dockPanelHeight.scale)
            let rect = view.convert(window.convertFromScreen(tipRect), from: nil)
            menu.popUp(relativeTo: rect, in: view)
            // Back from tracking: the menu is closed, whichever way.
            self.closeFolderPopup(sessionID: id)
        }
    }

    // MARK: - Store subscriptions

    /// Pinned folder list changed: sync the cover watchers, close popups of removed folders, and re-flow the strip width.
    func subscribePinnedFolderStore() {
        pinnedFolderStoreSubscription = pinnedFolderStore.$folderPaths
            .receive(on: DispatchQueue.main)
            .sink { [weak self] paths in
                guard let self else { return }
                self.folderCoverStore.sync(paths: paths)
                if let openPath = self.openPopupPath, !paths.contains(openPath) {
                    self.closeFolderPopup()
                }
                DispatchQueue.main.async { [weak self] in self?.relayout(animated: true) }
            }
        // A folder's sort order changed: the cover must be swapped to the first file of the new order; if that folder's grid is open → swap the content in place
        // (the panel doesn't go away, content swaps instantly; drill-down state is reset, same as native Stacks).
        pinnedFolderSortSubscription = pinnedFolderStore.$sortOrders
            .receive(on: DispatchQueue.main)
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in
                guard let self else { return }
                self.folderCoverStore.sync(paths: self.pinnedFolderStore.folderPaths)
                self.reloadOpenFolderPopup()
            }
        pinnedFolderViewModeSubscription = pinnedFolderStore.$viewModes
            .receive(on: DispatchQueue.main)
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in self?.reloadOpenFolderPopup() }
    }

    /// The open folder's sort or view mode changed. Same grid → content swapped in place; any
    /// other change of view → closed at once and opened again as the new one.
    private func reloadOpenFolderPopup() {
        guard let session = activePopupSession, case let .folder(path) = session.content,
              session.presentation != .list else { return }
        let rootURL = URL(fileURLWithPath: path)
        let sortOrder = pinnedFolderStore.sortOrder(for: path)
        let entries = folderCoverStore.cachedEntries(for: path, order: sortOrder)
            ?? FolderContentsLoader.preload(url: rootURL, timeout: 0.15, order: sortOrder)
        let next = folderPresentation(path: path, origin: session.origin, entries: entries)
        if session.presentation == .grid, next == .grid {
            if let entries {
                FolderIconResolver.warm(paths: entries.prefix(Self.popupWarmCount).map(\.url.path), timeout: 0.1)
            }
            reloadGridInPlace(session) { [weak self] context in
                self?.makeFolderGridHosting(session: session, rootURL: rootURL, entries: entries,
                                            sortOrder: sortOrder, context: context) ?? NSView()
            }
        } else {
            closeFolderPopup(immediately: true)
            openFolderPopup(path: path, anchorVisibleRect: session.anchor, origin: session.origin)
        }
    }
}
