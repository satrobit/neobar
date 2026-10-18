import AppKit
import Combine

@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let store: AppSettingsStore
    private let settingsCoordinator: SettingsCoordinator
    // Closure injection rather than depending on PermissionService directly: the test target compiles this file but does not include PermissionService.swift.
    private let isAccessibilityTrusted: () -> Bool
    private let onShowDebugConsole: () -> Void
    private let onExportDebugSnapshot: () -> Void
    private let onShowSettings: () -> Void
    /// Menu open / close. The taskbar's edge auto-hide must pause while the menu is open, otherwise the idle timer keeps running
    /// and the taskbar shrinks away from under the popped-up menu (same as `folderPopupOpen`). A closure is used because
    /// `PanelCoordinator` doesn't exist at all until permission onboarding completes.
    private let onMenuVisibilityChanged: (Bool) -> Void
    private let onQuit: () -> Void
    /// The display glyphs for the current show/hide shortcut. Fetched on demand via closure: after the user rebinds the key, the group title must follow on the next open.
    private let hotKeyGlyphs: () -> String
    // Closure injection: registration state belongs to the GlobalHotKeyMonitor held by AppDelegate, and the menu queries it fresh on every refresh.
    private let isToggleHotKeyRegistered: () -> Bool
    /// Source of the on-screen display snapshot. Closure injection rather than calling `DisplayIdentity` directly: the test target compiles this file
    /// but does not include `Platform/` (same reason as `isAccessibilityTrusted`).
    private let connectedScreens: () -> [(uuid: String, title: String)]
    /// Screen snapshot cache. **The menu path only reads it and never computes it live**: `localizedName` reads IODisplay,
    /// and main-thread system I/O on the menu path makes macOS coalesce mouse-moved events (the menu can't be scrolled).
    private var connectedScreensCache: [(uuid: String, title: String)] = []
    private var screenParametersObserver: NSObjectProtocol?
    private var edgeDelaySubscription: AnyCancellable?
    private var systemTruthRefreshTask: Task<Void, Never>?
    private var isMenuOpen = false
    private var isPreparedForTaskbarPresentation = false
    /// Whether this menu was popped up by a right-click on the taskbar. The menu is anchored to the taskbar's top edge, and when the taskbar shrinks it dangles in mid-air,
    /// so this path does **no live preview** (owner 2026-08-03); the status-bar icon path is unaffected.
    private var isPresentedFromTaskbar = false

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let permissionWarningItem = NSMenuItem(title: String(localized: "Accessibility Permission Required"), action: #selector(openAccessibilitySettings), keyEquivalent: "")
    private let permissionWarningSeparator = NSMenuItem.separator()
    private let settingsItem = NSMenuItem(title: String(localized: "Settings…"), action: #selector(showSettings), keyEquivalent: ",")
    /// The login item moved twice on 2026-08-24 alone: it moved to the settings window to dedupe with the menu, then after the owner reconsidered it **came back to the menu as the first item**,
    /// and the settings window no longer has it (still no duplication). Don't move it back to the settings window unless the owner asks again.
    private let launchAtLoginItem = NSMenuItem(title: String(localized: "Open at Login"), action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
    private let openLoginItemsSettingsItem = NSMenuItem(title: String(localized: "Open Login Items Settings…"), action: #selector(openLoginItemsSettings), keyEquivalent: "")
    /// The group title of the NeoBar group, never clickable (the title is set in refreshEdgeSectionTitle according to the hotkey registration state).
    private let edgeSectionItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    // Relay Station / hover app name / maximize avoidance / taskbar size moved back from the settings window to the menu on 2026-09-01
    // (owner's call, reversing the 2026-08-03 split): these are toggled on the fly while tweaking appearance, and opening a window for that isn't worth it.
    // The four items merge into the NeoBar group (no separate header), in the same group as "Single/Multi-screen mode ▸".
    // Login item / check for updates / version number still follow the 2026-08-24 dedupe result: settings window only.

    /// The group title, never clickable (the title is set in configureMenu).
    private let nativeDockSectionItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    /// The sole commit entry for the slider draft, hidden by default. It hosts a **real button** rather than an ordinary menu text row:
    /// as a menu row it has the same visual weight as its neighbor ("Open System Dock Settings..."), blending into the menu and easy to miss,
    /// and the user's eyes are still on the slider just after dragging it; missing it turns "it flashes but took effect" into
    /// "thought it was set but it didn't take effect", which is worse than the original flash (pointed out by the owner during 2026-08-02 acceptance).
    private let nativeDockApplyItem = NSMenuItem()
    private let nativeDockApplyRow = NativeDockApplyRowView()
    private let openNativeDockSettingsItem = NSMenuItem(title: String(localized: "Dock Settings…"), action: #selector(openNativeDockSettings), keyEquivalent: "")
    /// "Single/Multi-screen mode ▸": a second-level submenu with two groups, single-screen / multi-screen (on 2026-08-26 the owner moved this
    /// setting from the settings window to the menu, not placing it in both). It is a submenu so that **the main menu gains only one row and its height stays constant**:
    /// changes in screen count don't change the main menu height, so the taskbar path that positions by the top-left corner won't drift.
    /// Showing/hiding the whole row may only be flipped in `prepareMenuForPresentation` (the old rule about adding/removing rows while the menu is open).
    private let taskbarScreenItem = NSMenuItem(title: String(localized: "Single/Multi-Display Mode"), action: nil, keyEquivalent: "")
    /// **Deliberately no delegate**: `menuWillOpen` / `menuDidClose` don't distinguish the menu parameter,
    /// so a submenu opening and closing would be treated as the main menu opening and closing, lifting the edge auto-hide suppression too early. The content is instead built
    /// before the parent menu is shown (`prepareMenuForPresentation`).
    private let taskbarScreenMenu = NSMenu()
    /// The four below are ordinary checkmark items, **always present** (rows must not be added or removed while the menu is open); their checked state is set by refreshCheckmarks.
    private let showShelfItem = NSMenuItem(title: String(localized: "Show Shelf"), action: #selector(toggleShowShelf), keyEquivalent: "")
    private let showTrashItem = NSMenuItem(title: String(localized: "Show Trash"), action: #selector(toggleShowTrash), keyEquivalent: "")
    private let hoverNameItem = NSMenuItem(title: String(localized: "Show app name on hover"), action: #selector(toggleHoverName), keyEquivalent: "")
    private let windowLiftItem = NSMenuItem(title: String(localized: "Keep maximized windows above the taskbar"), action: #selector(toggleWindowLift), keyEquivalent: "")
    private let nativeDockSliderView: PreferenceSliderMenuItemView
    private let edgeSliderView: PreferenceSliderMenuItemView
    /// Hat and row of the taskbar height slider; the same value as the grip on the bar.
    private let taskbarSizeSectionItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let taskbarSizeSliderView = TaskbarSizeMenuItemView(accessibilityTitle: String(localized: "Taskbar Size"))

    init(store: AppSettingsStore,
         settingsCoordinator: SettingsCoordinator,
         isAccessibilityTrusted: @escaping () -> Bool,
         onShowDebugConsole: @escaping () -> Void,
         onExportDebugSnapshot: @escaping () -> Void,
         onShowSettings: @escaping () -> Void,
         onMenuVisibilityChanged: @escaping (Bool) -> Void = { _ in },
         onQuit: @escaping () -> Void,
         hotKeyGlyphs: @escaping () -> String,
         isToggleHotKeyRegistered: @escaping () -> Bool = { false },
         connectedScreens: @escaping () -> [(uuid: String, title: String)] = { [] }) {
        self.store = store
        self.settingsCoordinator = settingsCoordinator
        self.isAccessibilityTrusted = isAccessibilityTrusted
        self.onShowDebugConsole = onShowDebugConsole
        self.onExportDebugSnapshot = onExportDebugSnapshot
        self.onShowSettings = onShowSettings
        self.onMenuVisibilityChanged = onMenuVisibilityChanged
        self.onQuit = onQuit
        self.hotKeyGlyphs = hotKeyGlyphs
        self.isToggleHotKeyRegistered = isToggleHotKeyRegistered
        self.connectedScreens = connectedScreens
        nativeDockSliderView = PreferenceSliderMenuItemView(accessibilityTitle: String(localized: "Dock wake delay"))
        edgeSliderView = PreferenceSliderMenuItemView(accessibilityTitle: String(localized: "NeoBar wake delay"))
        super.init()
        configureStatusItem()
        configureMenu()
        refreshCheckmarks()
        // The NeoBar slider is a local value that takes effect immediately: ⌥⇧⌘D and the settings window may both change it while the menu is open, and the slider must follow.
        // The sink uses the new value emitted by the publisher: @Published publishes before the assignment completes, so reading back the store now gives the old value.
        //
        // The system Dock group deliberately has **no** equivalent subscription: the system doesn't change until the draft is written to it on release, so the slider shouldn't move.
        // Its position is synced once in menuWillOpen and once after the commit completes.
        edgeDelaySubscription = store.$edgeAutoHideDelay
            .removeDuplicates()
            .sink { [weak self] delay in
                self?.edgeSliderView.sync(delay: delay)
            }
        refreshSystemTruth()
        // The screen list is recomputed only once on plug/unplug; when the menu opens it reads the cache (see connectedScreensCache).
        connectedScreensCache = connectedScreens()
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.connectedScreensCache = self.connectedScreens()
            }
        }
    }

    deinit {
        if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
        }
    }

    private func configureStatusItem() {
        refreshStatusItemImage()
        statusItem.menu = menu
    }

    private func configureMenu() {
        menu.delegate = self

        permissionWarningItem.target = self
        permissionWarningItem.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: String(localized: "Warning"))
        permissionWarningItem.isHidden = true
        permissionWarningSeparator.isHidden = true
        menu.addItem(permissionWarningItem)
        menu.addItem(permissionWarningSeparator)

        // Launch at login = the first menu item (set by the owner 2026-08-24; the permission warning appears only in abnormal states, so it doesn't count).
        launchAtLoginItem.target = self
        menu.addItem(launchAtLoginItem)
        openLoginItemsSettingsItem.target = self
        menu.addItem(openLoginItemsSettingsItem)
        menu.addItem(.separator())

        // The NeoBar group is placed before the system Dock group: this is NeoBar's own menu, so its own settings come first.
        // Both groups have a grey group title as a "header": previously only the system Dock had one, so the whole menu had a single header on top,
        // and the NeoBar commands under it looked like they were governed by it too (owner feedback 2026-08-03).
        edgeSectionItem.isEnabled = false
        menu.addItem(edgeSectionItem)

        // The NeoBar slider takes effect immediately: every notch dragged is written to the store. But **writing the value alone shows no effect**:
        // as soon as the menu opens, the `taskbarMenuOpen` suppressor is set, the taskbar is forced to stay visible and not allowed to hide,
        // so even dragging to 0.5s nothing moves until the menu is closed (the owner's 2026-08-03 report: "it only takes effect after dismissing the menu").
        //
        // So **touching this slider lifts the suppression**, letting the taskbar actually move at the new level: touching the slider = wanting to see the effect.
        // When the slider hasn't been touched, suppression stays as before, so the taskbar doesn't shrink out from under the menu while it sits open idle.
        //
        // **But the menu popped up by a taskbar right-click is an exception**: it is anchored to the taskbar's top edge, and when the taskbar shrinks the menu hangs in mid-air,
        // which is worse than not seeing the effect (owner 2026-08-03). That path only writes the value and doesn't lift the suppression;
        // it takes effect once the menu is closed. After `menuDidClose` false is set once more; it is idempotent.
        edgeSliderView.onDelayChange = { [weak self, weak store] delay in
            store?.setEdgeAutoHideDelay(delay)
            guard let self, !self.isPresentedFromTaskbar else { return }
            self.onMenuVisibilityChanged(false)
        }
        let edgeItem = NSMenuItem()
        edgeItem.view = edgeSliderView
        menu.addItem(edgeItem)
        menu.addItem(.separator())

        // Live on both entry points, the taskbar-anchored menu included: the bar grows under
        // the menu or leaves a gap below it, but never disappears from under it the way a
        // wake-delay change could.
        taskbarSizeSectionItem.attributedTitle = Self.sectionTitle(String(localized: "Taskbar Size"))
        taskbarSizeSectionItem.isEnabled = false
        menu.addItem(taskbarSizeSectionItem)
        taskbarSizeSliderView.onEditingChanged = { [weak self] editing in
            self?.settingsCoordinator.setTaskbarHeightEditing(editing)
        }
        taskbarSizeSliderView.onHeightChange = { [weak self] height in
            self?.settingsCoordinator.setTaskbarHeight(height)
        }
        let taskbarSizeItem = NSMenuItem()
        taskbarSizeItem.view = taskbarSizeSliderView
        menu.addItem(taskbarSizeItem)
        menu.addItem(.separator())

        nativeDockSectionItem.attributedTitle = Self.sectionTitle(AutoHideToggleMenuModel.nativeDockSectionTitle)
        nativeDockSectionItem.isEnabled = false
        menu.addItem(nativeDockSectionItem)

        // The system Dock slider is **not wired** to the store: as soon as `setNativeDockAutoHideDelay` is called it persists active + remembered
        // together, whereas the system side waits until the user clicks the confirm row to write; a half-dragged value shouldn't become persistent state.
        // onDraftChange is used only to refresh the confirm row and touches no persistent state.
        nativeDockSliderView.onDraftChange = { [weak self] draft in
            self?.refreshNativeDockApplyItem(draft: draft)
        }
        nativeDockSliderView.onDelayCommit = { [weak self] target in
            self?.scheduleNativeDockWrite(target: target)
        }
        let nativeDockSliderItem = NSMenuItem()
        nativeDockSliderItem.view = nativeDockSliderView
        menu.addItem(nativeDockSliderItem)

        nativeDockApplyRow.onApply = { [weak self] in
            self?.applyNativeDockDelay()
        }
        nativeDockApplyItem.view = nativeDockApplyRow
        nativeDockApplyItem.isHidden = true
        menu.addItem(nativeDockApplyItem)

        menu.addItem(.separator())

        // The taskbar's own five items (owner 2026-09-01, the result of two decisions that day): **a standalone block with no group title**,
        // placed after the two wake sliders. Merging into the NeoBar group was tried first, and after seeing it on a real device the owner wanted it separated from the sliders as its own block.
        // With no header, it is distinguished from what's before and after by the separator lines above and below, so **do not insert anything else into this block**:
        // once rows unrelated to the taskbar get mixed in, the reader can only guess from the wording what governs it.
        // The show/hide of `taskbarScreenItem` is still flipped only in `prepareMenuForPresentation`
        // (adding/removing rows while the menu is on screen makes the taskbar popup path's anchor drift).
        taskbarScreenItem.submenu = taskbarScreenMenu
        taskbarScreenItem.isHidden = true
        menu.addItem(taskbarScreenItem)

        // Four toggles. In the settings window each has a grey explanatory line; the menu has no place for a subtitle,
        // so the explanations were deleted along with the move (the owner decided 2026-09-01 to accept this cost).
        showShelfItem.target = self
        menu.addItem(showShelfItem)
        showTrashItem.target = self
        menu.addItem(showTrashItem)
        hoverNameItem.target = self
        menu.addItem(hoverNameItem)
        windowLiftItem.target = self
        menu.addItem(windowLiftItem)
        menu.addItem(.separator())
        #if DEBUG
        let debugMenu = NSMenu()
        let showDebug = NSMenuItem(title: String(localized: "Show Debug Console"), action: #selector(showDebugConsole), keyEquivalent: "")
        showDebug.target = self
        debugMenu.addItem(showDebug)
        let exportSnapshot = NSMenuItem(title: String(localized: "Export Taskbar Snapshot"), action: #selector(exportDebugSnapshot), keyEquivalent: "")
        exportSnapshot.target = self
        debugMenu.addItem(exportSnapshot)
        let debugItem = NSMenuItem(title: String(localized: "Debug"), action: nil, keyEquivalent: "")
        debugItem.submenu = debugMenu
        menu.addItem(debugItem)
        menu.addItem(.separator())
        #endif

        // "Settings..." and "Quit" are grouped at the bottom (owner 2026-08-03): the common habit for menu bar apps is
        // to put such "go to another interface" entries at the bottom, leaving the top for toggles used on the fly.
        // Login item / check for updates / version number were deduped on 2026-08-24 and remain only in the settings window.
        settingsItem.target = self
        settingsItem.keyEquivalentModifierMask = [.command]
        menu.addItem(settingsItem)

        // Sits alongside "Settings...": both are "open another interface". It therefore left the system Dock group
        // (owner 2026-08-03; it used to be the last row of that group, and looked like a pair with the first row of the next group).
        openNativeDockSettingsItem.target = self
        menu.addItem(openNativeDockSettingsItem)

        let quitItem = NSMenuItem(title: String(localized: "Quit NeoBar"), action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }


    /// Pop-up entry for the right-click on the taskbar / capsule.
    ///
    /// It **shares the same `NSMenu` instance** as the status-bar icon: the two sliders and the confirm button in the menu are stateful custom-drawn NSViews,
    /// and cloning a copy would immediately produce "two sliders each keeping its own draft". The existing logic of `menuWillOpen` (refeed the real system Dock values,
    /// refresh checkmarks, discard unconfirmed drafts) goes through the same delegate, so the two entries behave identically.
    func popUpFromTaskbar(with event: NSEvent, in view: NSView) {
        // Compute the anchor ourselves so the **menu's bottom edge sits on the taskbar's top edge** and its left edge aligns with the mouse, floating above the strip
        // like right-clicking the system Dock, without covering it. If left to `NSMenu.popUpContextMenu`'s automatic flipping, the menu's bottom edge was measured to land
        // 28pt below the mouse, covering the whole taskbar (half the reason for the owner's 2026-08-03 feedback that it "doesn't follow the cursor").
        //
        // `MenuHostNSView` is an ordinary NSView (`isFlipped == false`, origin at bottom-left) that fills the taskbar's
        // visible area, so `bounds.maxY` is the taskbar's top edge; `popUp(positioning:at:in:)` places the menu's
        // **top-left corner** at the given point, so we then lift it up by one menu height.
        isPresentedFromTaskbar = true
        prepareMenuForPresentation()
        isPreparedForTaskbarPresentation = true
        let local = view.convert(event.locationInWindow, from: nil)
        let anchor = NSPoint(x: local.x, y: view.bounds.maxY + menu.size.height)
        menu.popUp(positioning: nil, at: anchor, in: view)
        isPreparedForTaskbarPresentation = false
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
        isPresentedFromTaskbar = false
        // A menu dismissed mid-drag must not leave the bars in the resize transaction.
        settingsCoordinator.setTaskbarHeightEditing(false)
        onMenuVisibilityChanged(false)
        // Warm up once more after closing; all results go only into the cache, for direct use at the next presentation.
        refreshSystemTruth()
    }

    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
        onMenuVisibilityChanged(true)
        if !isPreparedForTaskbarPresentation {
            prepareMenuForPresentation()
        }
        isPreparedForTaskbarPresentation = false
        refreshSystemTruth()
    }

    /// Reads only the local cache and syncs AppKit objects, performing no system I/O.
    /// The taskbar entry goes through here before measuring `menu.size`, ensuring the anchor uses this time's real height.
    private func prepareMenuForPresentation() {
        let granted = isAccessibilityTrusted()
        permissionWarningItem.isHidden = granted
        permissionWarningSeparator.isHidden = granted
        refreshCheckmarks()
        // Closing the menu without clicking confirm = discard: nothing is written, and next time everything restarts from the real system values.
        // (Otherwise "just nudging it to have a look" would also trigger a killall Dock, and the screen suddenly flickering on closing a menu
        // is exactly the oddness this change is meant to remove.)
        //
        // **Discarding is done at "open time" rather than in `menuDidClose`**, so as not to depend on the form of the confirm control.
        // The confirm is currently an `NSButton` inside a custom view whose action is sent directly, so it is safe wherever it lives;
        // but as soon as someone changes it back to an ordinary `NSMenuItem`, `menuDidClose` becomes a trap: AppKit's order is
        // close the menu, call back `menuDidClose`, **and only then** send the menu item's action, so the draft would be cleared
        // before the confirm, `commitDraft()` would get nil, and the whole confirm feature would silently fail (stepped on and fixed in this round).
        nativeDockSliderView.discardDraft()
        nativeDockSliderView.sync(delay: store.nativeDockAutoHideDelay)
        nativeDockApplyItem.isHidden = true
        edgeSliderView.sync(delay: store.edgeAutoHideDelay)
        taskbarSizeSliderView.sync(height: store.dockPanelHeight)
        refreshEdgeSectionTitle()
        rebuildTaskbarScreenMenu()
    }

    /// Rebuilds "Single/Multi-screen mode ▸". **Call it only from `prepareMenuForPresentation`**: it is the only
    /// path allowed to change row visibility (adding/removing rows while the menu is on screen makes the taskbar anchor drift).
    private func rebuildTaskbarScreenMenu() {
        let presentation = TaskbarScreenMenuPresentation(
            placement: store.taskbarScreenPlacement,
            connectedScreens: connectedScreensCache
        )
        taskbarScreenItem.isHidden = presentation.isHidden
        taskbarScreenMenu.removeAllItems()
        for row in presentation.rows {
            switch row {
            case .header(let title):
                // The group title is the same as the two in the main menu: disabled + attributedTitle (secondary label color), no keyEquivalent.
                let header = NSMenuItem(title: "", action: nil, keyEquivalent: "")
                header.attributedTitle = Self.sectionTitle(title)
                header.isEnabled = false
                taskbarScreenMenu.addItem(header)
            case .separator:
                taskbarScreenMenu.addItem(.separator())
            case .option(let item):
                let menuItem = NSMenuItem(
                    title: item.title,
                    action: #selector(selectTaskbarScreen(_:)),
                    keyEquivalent: ""
                )
                menuItem.target = self
                // The selection travels via representedObject as a token string. **ClosureMenuItem can't be used**:
                // `AppMenuFragments.swift` is compiled only into the app target, while this file is also compiled in the test target.
                menuItem.representedObject = item.selection.token
                menuItem.state = item.isChecked ? .on : .off
                // Options sit one step in from their group header.
                menuItem.indentationLevel = 1
                // Same line, not `NSMenuItem.subtitle`: a subtitle makes the row taller than its siblings.
                if let hint = item.hint {
                    menuItem.attributedTitle = Self.titleWithHint(
                        item.title,
                        hint,
                        alignedAfter: TaskbarScreenMenuPresentation.pinnedTitlePrefix
                    )
                }
                taskbarScreenMenu.addItem(menuItem)
            }
        }
    }

    /// System reads run on a dedicated service queue. The taskbar menu is positioned by its top-left corner, and changing its height after display makes the bottom edge drift,
    /// so that path only updates the cache; the status-bar menu has no such anchor constraint and can absorb the new real values in place.
    /// (The login item half was deleted once on 2026-08-24 along with the dedupe, and restored when the owner reconsidered and put the login item back in the menu.)
    private func refreshSystemTruth() {
        systemTruthRefreshTask?.cancel()
        let settingsCoordinator = settingsCoordinator
        systemTruthRefreshTask = Task { @MainActor [weak self] in
            async let launchAccepted = settingsCoordinator.refreshLaunchAtLoginState()
            async let nativeDockAccepted = settingsCoordinator.reconcileNativeDockMirror()
            let accepted = await (launchAccepted, nativeDockAccepted)
            guard let self,
                  !Task.isCancelled,
                  self.isMenuOpen,
                  !self.isPresentedFromTaskbar else { return }
            if accepted.0 {
                self.refreshCheckmarks(allowsLayoutChange: false)
            }
            // The slider follows the real value only while the user hasn't started dragging: a dragging hand mustn't be jolted.
            if accepted.1, !self.nativeDockSliderView.hasDraft {
                self.nativeDockSliderView.sync(delay: self.store.nativeDockAutoHideDelay)
            }
        }
    }

    /// The group title **does not set `keyEquivalent`**: a disabled row that has one gets captured by the menu, and would also look clickable.
    /// ⌥⇧⌘D is written into the title as plain text only, and only mentioned when Carbon registration succeeded: if registration failed it can't be triggered, and printing it would be a lie.
    private func refreshEdgeSectionTitle() {
        edgeSectionItem.attributedTitle = Self.sectionTitle(
            AutoHideToggleMenuModel.edgeSectionTitle(
                isHotKeyRegistered: isToggleHotKeyRegistered(),
                glyphs: hotKeyGlyphs()
            )
        )
    }

    /// Only surface the confirm row when the draft differs from the effective value. The effective value is taken from the local mirror, which `menuWillOpen` just aligned with the real system value.
    private func refreshNativeDockApplyItem(draft: Double) {
        let shouldShow = AutoHideToggleMenuModel.shouldShowNativeApply(
            draft: draft,
            applied: store.nativeDockAutoHideDelay
        )
        nativeDockApplyItem.isHidden = !shouldShow
        if shouldShow {
            // The button title is always "Apply" (the title string is localized elsewhere); the target level goes only into accessibility: the slider already expresses it once with its value and endpoint dots,
            // and repeating it in the button would crowd it, but VoiceOver hears only this one sentence, so it must include the level.
            nativeDockApplyRow.updateTarget(description: AutoHideToggleMenuModel.nativeApplyTitle(draft: draft))
            // The previous round may have stopped in the hover state, and when this round surfaces the mouse is still over the slider, not the button.
            nativeDockApplyRow.resetInteractionState()
        }
    }

    private func applyNativeDockDelay() {
        nativeDockSliderView.commitDraft()
    }

    @objc private func openNativeDockSettings() {
        guard settingsCoordinator.openNativeDockSettings() else {
            presentError(
                title: String(localized: "Can’t Open Dock Settings"),
                message: String(localized: "Open System Settings and go to Desktop & Dock (on macOS 12, Dock & Menu Bar).")
            )
            return
        }
    }

    /// `allowsLayoutChange` = whether this refresh may add or remove menu rows. It may before presentation (`prepareMenuForPresentation`),
    /// but **may not** when the async real value comes back; see `refreshLaunchAtLoginState` for the reason.
    private func refreshCheckmarks(allowsLayoutChange: Bool = true) {
        refreshLaunchAtLoginState(allowsLayoutChange: allowsLayoutChange)
        refreshTaskbarPreferenceStates()
    }

    /// Checkmarks of the four NeoBar group items. **Only changes `state`; doesn't add/remove rows or flip `isHidden`**,
    /// so it is also safe to call while the menu is open (not bound by `allowsLayoutChange`).
    private func refreshTaskbarPreferenceStates() {
        showShelfItem.state = store.showShelf ? .on : .off
        showTrashItem.state = store.showTrash ? .on : .off
        hoverNameItem.state = store.hoverStyle.isExpressive ? .on : .off
        windowLiftItem.state = store.windowLiftEnabled ? .on : .off
    }

    private func refreshLaunchAtLoginState(allowsLayoutChange: Bool) {
        let presentation = LaunchAtLoginMenuPresentation(state: settingsCoordinator.launchAtLoginState)
        launchAtLoginItem.title = presentation.title
        launchAtLoginItem.state = presentation.isChecked ? .on : .off
        launchAtLoginItem.isEnabled = presentation.isEnabled
        // When the menu is already on screen, **only change text and checkmarks, never add or remove rows**. The login item is in `.requiresApproval`
        // (just registered, waiting for approval in System Settings) and this row would pop up; the async real value comes back late, and with one more row the menu height changes,
        // so the user sees "the content jumped by itself", and the taskbar path is positioned by its top-left corner so the bottom edge would drift once the height changes.
        // A round late is fine: the next `prepareMenuForPresentation` adds it **before** the menu is shown.
        guard allowsLayoutChange else { return }
        openLoginItemsSettingsItem.isHidden = !presentation.showsSettingsItem
    }

    /// Styles of the two group titles. **Must go through `attributedTitle`**: the group title is a disabled item with `action: nil`,
    /// so there is no `textColor` to set, and the system draws it as the faintest tier in the menu per disabled; the owner on 2026-09-01 found it too grey.
    /// Deepened to `secondaryLabelColor`: weaker than clickable menu items but readable; **don't turn it into
    /// enabled just to make it black**, as the mouse would then highlight it as a blue bar on hover, and group titles not highlighting is correct (owner 2026-08-04).
    ///
    /// ⚠️ The font must be given explicitly: without it `attributedTitle` falls back to the default system font size.
    /// ⚠️ After `attributedTitle` is set, **assigning `title` again has no effect**, so `refreshEdgeSectionTitle()`
    /// must also go through here; the two call sites can't be changed one at a time.
    private static func sectionTitle(_ text: String) -> NSAttributedString {
        NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.menuFont(ofSize: 0),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        )
    }

    /// Title followed by grey hint text on the same line. The hint starts where the screen name
    /// starts on the rows below (`prefix` = the localized "Pinned to " label): the gap after the title is one space
    /// kerned out by however much narrower the title is than the prefix. A title wider than the
    /// prefix (English) just gets the plain space.
    /// Fonts and colours must be explicit, same as `sectionTitle` — an attributed title without
    /// them falls back to black at the default size and vanishes in dark menus.
    private static func titleWithHint(_ title: String, _ hint: String, alignedAfter prefix: String) -> NSAttributedString {
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.menuFont(ofSize: 0),
            .foregroundColor: NSColor.labelColor
        ]
        // Measured without trailing whitespace on either side, so both widths mean the same thing.
        let prefixWidth = (prefix.trimmingCharacters(in: .whitespaces) as NSString).size(withAttributes: titleAttributes).width
        let titleWidth = (title as NSString).size(withAttributes: titleAttributes).width
        var gapAttributes = titleAttributes
        gapAttributes[.kern] = max(0, prefixWidth - titleWidth)
        let text = NSMutableAttributedString(string: title, attributes: titleAttributes)
        text.append(NSAttributedString(string: " ", attributes: gapAttributes))
        text.append(NSAttributedString(
            string: hint,
            attributes: [
                .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.tertiaryLabelColor
            ]
        ))
        return text
    }

    private func refreshStatusItemImage() {
        let image = NSImage(systemSymbolName: "dock.rectangle", accessibilityDescription: "NeoBar")
            ?? NSImage(systemSymbolName: "rectangle.3.offgrid.fill", accessibilityDescription: "NeoBar")
        image?.isTemplate = true
        image?.accessibilityDescription = "NeoBar"
        statusItem.button?.image = image
    }

    @objc private func toggleLaunchAtLogin() {
        guard let enable = LaunchAtLoginMenuModel.requestedEnabledValue(afterSelecting: settingsCoordinator.launchAtLoginState) else { return }
        if case .failure(let error) = settingsCoordinator.setLaunchAtLogin(enable) {
            presentError(title: String(localized: "Couldn’t Change Open at Login"), message: error.localizedDescription)
        }
        refreshCheckmarks()
    }

    @objc private func selectTaskbarScreen(_ sender: NSMenuItem) {
        guard let token = sender.representedObject as? String,
              let selection = TaskbarScreenMenuPresentation.Selection(token: token) else { return }
        switch selection {
        case .followMouse:
            store.setTaskbarScreenPlacement(.followMouse)
        case .allScreens:
            store.setTaskbarScreenPlacement(.allScreens)
        case .allScreensPerDisplay:
            store.setTaskbarScreenPlacement(.allScreensPerDisplay)
        case .screen(let uuid):
            // name is only a display snapshot: for an on-screen display take the deduplicated display name; when re-selecting that disconnected screen, keep the old snapshot.
            let name = connectedScreensCache.first(where: { $0.uuid == uuid })?.title
                ?? store.taskbarScreenPlacement.pinnedSelection?.name
                ?? ""
            store.setTaskbarScreenPlacement(.pinned(PinnedScreenSelection(uuid: uuid, name: name)))
        }
    }

    @objc private func toggleShowShelf() {
        store.setShowShelf(!store.showShelf)
        refreshCheckmarks()
    }

    @objc private func toggleShowTrash() {
        store.setShowTrash(!store.showTrash)
        refreshCheckmarks()
    }

    /// Hover app name = the two levels of `hoverStyle` (`.standard` shows / `.quiet` doesn't show),
    /// not a separate boolean field; the settings window read and wrote it this way too, so don't open a mirror of it here.
    @objc private func toggleHoverName() {
        store.setHoverStyle(store.hoverStyle.isExpressive ? .quiet : .standard)
        refreshCheckmarks()
    }

    @objc private func toggleWindowLift() {
        store.setWindowLiftEnabled(!store.windowLiftEnabled)
        refreshCheckmarks()
    }

    @objc private func openLoginItemsSettings() {
        settingsCoordinator.openLoginItemsSettings()
    }

    @objc private func openAccessibilitySettings() {
        guard let url = AccessibilitySettingsLink.url else { return }
        NSWorkspace.shared.open(url)
    }


    /// The sole write path for the system Dock. First dismiss the menu: the write ends with `killall Dock`,
    /// and the menu shouldn't still be open when the system Dock restarts; execute on the next turn.
    private func scheduleNativeDockWrite(target: Double) {
        menu.cancelTrackingWithoutAnimation()
        Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await self.settingsCoordinator.applyNativeDock(target: target)
            self.nativeDockSliderView.sync(delay: outcome.resolvedDelay)
            self.nativeDockApplyItem.isHidden = true
            if let error = outcome.error {
                self.presentError(title: String(localized: "Couldn’t Change Dock Settings"), message: error.localizedDescription)
            }
        }
    }

    private func presentError(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "OK"))
        Self.runModalInForeground(alert)
    }

    /// NeoBar is an `.accessory` app (no Dock icon). Calling `runModal()` directly on such an app does **not** bring itself
    /// to the foreground, and the dialog lands behind the frontmost app's windows: the user clicks a menu item and sees no reaction at all,
    /// which looks exactly like "the feature is broken" (real users reported it exactly that way: "check for updates doesn't work").
    /// It strikes whenever the foreground has any window, which is to say almost always.
    ///
    /// Every `runModal()` / panel presentation in `AppDelegate` calls `NSApp.activate` beforehand,
    /// only these four spots in the status menu missed it. All dialogs go through here; don't each call `runModal()` themselves again.
    @discardableResult
    private static func runModalInForeground(_ alert: NSAlert) -> NSApplication.ModalResponse {
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal()
    }

    @objc private func showDebugConsole() { onShowDebugConsole() }
    @objc private func exportDebugSnapshot() { onExportDebugSnapshot() }
    @objc private func showSettings() {
        menu.cancelTrackingWithoutAnimation()
        DispatchQueue.main.async { [onShowSettings] in onShowSettings() }
    }
    @objc private func quit() { onQuit() }
}
