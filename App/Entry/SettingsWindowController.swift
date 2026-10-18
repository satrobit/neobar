import AppKit
import Combine
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let store: AppSettingsStore
    private let coordinator: SettingsCoordinator
    /// The "Reopen onboarding" button on the General page. Closure injection: the onboarding window is opened by `AppDelegate`
    /// (it must go straight to `showWelcomeWindow()`, see the comment there).
    private let onShowWelcomeGuide: () -> Void
    private var window: NSWindow?
    private var hostingView: NSHostingView<SettingsWindowView>?
    private var sessionSubscriptions: Set<AnyCancellable> = []
    private var closedFrame: NSRect?
    private var hasPresented = false
    /// The selected tab (paged 2026-08-24). The controller holds the sole copy = in-session memory;
    /// the height-measuring probe must share it, otherwise it measures a different page. Deliberately not persisted across restarts.
    private let tabState = SettingsTabState()

    init(
        store: AppSettingsStore,
        coordinator: SettingsCoordinator,
        onShowWelcomeGuide: @escaping () -> Void
    ) {
        self.store = store
        self.coordinator = coordinator
        self.onShowWelcomeGuide = onShowWelcomeGuide
    }

    func present() {
        let window = window ?? makeWindow()
        if let closedFrame {
            window.setFrame(closedFrame, display: false)
            self.closedFrame = nil
        }
        let host = NSHostingView(
            rootView: SettingsWindowView(
                store: store,
                coordinator: coordinator,
                tabState: tabState,
                onShowWelcomeGuide: onShowWelcomeGuide
            )
        )
        window.contentView = host
        hostingView = host
        // On reopen, align the title and toolbar selection state with the session memory (cheap insurance in case a future path changes the selection while the window is closed).
        window.title = tabState.selected.title
        window.toolbar?.selectedItemIdentifier = NSToolbarItem.Identifier(tabState.selected.rawValue)

        sessionSubscriptions.removeAll()

        resizeToFitKeepingTopEdge()
        repairPlacement(isFirstPresentation: !hasPresented)
        hasPresented = true
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// External wrap-up entry (permission loss suspends). `close()` triggers `windowWillClose`, and cleanup goes through that one path.
    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window, notification.object as? NSWindow === window else { return }
        closedFrame = window.frame
        sessionSubscriptions.removeAll()
        window.contentView = NSView()
        hostingView = nil
        // tabState is deliberately not reset: reopening returns to the same tab.
    }

    // MARK: Tabs

    /// Prevents NSToolbar auto-validation from graying out the icon items (our five tabs are always clickable).
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool { true }

    @objc private func selectToolbarTab(_ sender: NSToolbarItem) {
        guard let tab = SettingsTab(rawValue: sender.itemIdentifier.rawValue) else { return }
        select(tab: tab)
    }

    private func select(tab: SettingsTab) {
        // Clicking the already-selected tab returns early, so as not to play the height animation for nothing.
        guard tabState.selected != tab else { return }
        // **Change first, then measure**: the height probe shares this tabState, and only after the change does it measure the new page.
        tabState.selected = tab
        window?.toolbar?.selectedItemIdentifier = NSToolbarItem.Identifier(tab.rawValue)
        window?.title = tab.title
        resizeToFitKeepingTopEdge(animated: true)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: SettingsWindowView.contentWidth, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        // The title follows the selected tab (preferences convention); the localization key of the old static title was deleted accordingly.
        window.title = tabState.selected.title
        window.toolbarStyle = .preference
        let toolbar = NSToolbar(identifier: "SettingsToolbar")
        toolbar.delegate = self
        toolbar.allowsUserCustomization = false
        // Don't persist the NSToolbar Configuration preference key, in the same family as "don't enable frame autosave".
        toolbar.autosavesConfiguration = false
        toolbar.displayMode = .iconAndLabel
        window.toolbar = toolbar
        toolbar.selectedItemIdentifier = NSToolbarItem.Identifier(tabState.selected.rawValue)
        window.level = .normal
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window
        return window
    }

    /// `animated` is passed true only by the tab-switch path (top and left edges fixed, bottom edge animates to the new page height).
    /// `present()` and the authorization sink use the default false, consistent with the single-page era.
    private func resizeToFitKeepingTopEdge(animated: Bool = false) {
        guard let window else { return }
        // The probe must carry the same fixed width as the real window (`SettingsWindowView` puts
        // `.frame(width:)` outside its ScrollView). `fittingSize` proposes no width, so without it
        // every wrapping note measures single-line and the window comes up short by one line per
        // note that wraps — invisible in English, 30–45pt of clipped content in German and French.
        let probe = NSHostingView(
            rootView: SettingsWindowContent(
                store: store,
                coordinator: coordinator,
                tabState: tabState,
                onShowWelcomeGuide: onShowWelcomeGuide
            )
            .frame(width: SettingsWindowView.contentWidth)
        )
        probe.setFrameSize(NSSize(width: SettingsWindowView.contentWidth, height: 0))
        probe.layoutSubtreeIfNeeded()
        let naturalHeight = probe.fittingSize.height
        let visibleHeight = preferredScreen()?.visibleFrame.height ?? 900
        // Lower bound 160: 320 was the single-page floor; after paging, the shortest "Advanced" page naturally can't reach it, and forcing it would leave a blank stretch.
        let contentHeight = max(160, min(naturalHeight, visibleHeight - 80))
        let oldTop = window.frame.maxY
        guard animated else {
            window.setContentSize(NSSize(width: SettingsWindowView.contentWidth, height: contentHeight))
            if hasPresented {
                window.setFrameOrigin(NSPoint(x: window.frame.minX, y: oldTop - window.frame.height))
                repairPlacement(isFirstPresentation: false)
            }
            return
        }
        // Tab-switch animation: must use the **instance** frameRect(forContentRect:), which includes title bar + toolbar height;
        // the class method doesn't, and would make the window grow by one toolbar on every tab switch. The position fix is done **before** the animation:
        // window.frame read during the animation is an interpolated value, and fixing after the animation would clamp against a mid-way frame.
        let contentRect = NSRect(x: 0, y: 0, width: SettingsWindowView.contentWidth, height: contentHeight)
        var target = window.frameRect(forContentRect: contentRect)
        target.origin.x = window.frame.minX
        target.origin.y = oldTop - target.height
        let titlebarHeight = max(1, window.frame.height - window.contentLayoutRect.height)
        let repaired = AccessoryWindowPresentation.repairedFrame(
            windowFrame: target,
            titlebarHeight: titlebarHeight,
            visibleFrames: NSScreen.screens.map(\.visibleFrame),
            preferredVisibleFrame: preferredScreen()?.visibleFrame,
            isFirstPresentation: false
        )
        window.setFrame(repaired ?? target, display: true, animate: true)
    }

    private func repairPlacement(isFirstPresentation: Bool) {
        guard let window else { return }
        let screens = NSScreen.screens
        let visibleFrames = screens.map(\.visibleFrame)
        let preferred = preferredScreen()?.visibleFrame
        let titlebarHeight = max(1, window.frame.height - window.contentLayoutRect.height)
        guard let repaired = AccessoryWindowPresentation.repairedFrame(
            windowFrame: window.frame,
            titlebarHeight: titlebarHeight,
            visibleFrames: visibleFrames,
            preferredVisibleFrame: preferred,
            isFirstPresentation: isFirstPresentation
        ) else { return }
        window.setFrame(repaired, display: false)
    }

    private func preferredScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? window?.screen ?? NSScreen.main
    }
}

extension SettingsWindowController: NSToolbarDelegate {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsTab.allCases.map { NSToolbarItem.Identifier($0.rawValue) }
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    /// Miss this one and a tab click responds but is **never highlighted**: AppKit only draws the selected state for items in the selectable set.
    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard let tab = SettingsTab(rawValue: itemIdentifier.rawValue) else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = tab.title
        item.paletteLabel = tab.title
        item.image = NSImage(systemSymbolName: tab.symbolName, accessibilityDescription: tab.title)
        item.target = self
        item.action = #selector(selectToolbarTab(_:))
        return item
    }
}
