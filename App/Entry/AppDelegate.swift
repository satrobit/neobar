import AppKit
import Combine
import QuartzCore
import SwiftUI
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Window titles for the guide windows follow the localized bundle name (`InfoPlist.xcstrings`):
    /// only zh-Hans carries the "NeoBar" suffix, every other language shows plain "NeoBar".
    static var localizedDisplayName: String {
        (Bundle.main.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
            ?? (Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String)
            ?? "NeoBar"
    }

    /// Must be the **first** stored property: every other store writes defaults inside its own
    /// init, so a snapshot taken one step later can no longer tell a prior install apart.
    private let installLineage = InstallLineage.capture()
    private let inventoryLog = WindowInventoryAnomalyLog()
    /// Sole source of the present-screens table: the window inventory (ownership key) and the taskbar projection (per-screen filtering under multi-screen ④) both read it.
    let displayTopologyStore = DisplayTopologyStore(initialSnapshot: DisplayIdentity.topologySnapshot())
    private(set) lazy var runtime = AppRuntime(
        inventoryLog: inventoryLog,
        displayTableProvider: { [displayTopologyStore] in displayTopologyStore.table },
        isAccessibilityTrusted: { [weak self] in self?.cachedAccessibilityTrusted ?? false }
    )
    let drawerStore = DrawerStore()
    let messagingStore = MessagingAppStore()
    let badgeStore = BadgeStore()
    let keptAppStore = KeptAppStore()
    lazy var stripOrderStore = StripOrderStore(
        keptIDsProvider: { [keptAppStore] in Set(keptAppStore.bundleIDs) },
        stableKeptOrderProvider: { [keptAppStore, messagingStore] in
            keptAppStore.bundleIDs.filter { !messagingStore.contains($0) }
        },
        inventoryLog: inventoryLog
    )
    let drawerOrderStore = DrawerOrderStore()
    let settingsStore = AppSettingsStore()
    let pinnedFolderStore = PinnedFolderStore()
    let shelfStore = ShelfStore()
    let runningApplicationStore = RunningApplicationStore()
    private(set) lazy var appMembershipController = AppMembershipController(
        keptAppStore: keptAppStore,
        drawerStore: drawerStore,
        messagingStore: messagingStore
    )
    /// lazy: sortOrderProvider needs to reference pinnedFolderStore (the cover follows the first file in that folder's current sort order).
    private(set) lazy var folderCoverStore = PinnedFolderCoverStore(
        sortOrderProvider: { [pinnedFolderStore] path in pinnedFolderStore.sortOrder(for: path) },
        isUnopenedSeed: { [pinnedFolderStore] path in pinnedFolderStore.isUnopenedSeed(path) }
    )
    private var panelCoordinator: TaskbarScreenOrchestrator?
    private var windowLiftAvoidanceController: WindowLiftAvoidanceController?
    private lazy var launchAtLoginService = LaunchAtLoginService()
    private lazy var nativeDockPreferencesService = NativeDockPreferencesService()
    private lazy var settingsCoordinator = SettingsCoordinator(
        store: settingsStore,
        launchAtLoginService: launchAtLoginService,
        nativeDockPreferencesService: nativeDockPreferencesService,
        // Real registration entry point for rebinding keys. A temporary copy has no monitor (and can't reach the Settings window), so it reports failure as a fallback.
        hotKeyRegistrar: { [weak self] shortcut in
            self?.edgeToggleHotKey?.update(shortcut: shortcut) ?? .monitorUnavailable
        }
    )
    private lazy var settingsWindowController = SettingsWindowController(
        store: settingsStore,
        coordinator: settingsCoordinator,
        // Goes straight to showWelcomeWindow() instead of presentWelcomeGuideIfNeeded(): that one always silently skips
        // existing users who already have hasSeenWelcome set, and existing users are exactly the whole audience of this entry point.
        // On 2026-09-01 the entry point moved from the status-bar menu into the "General" page of the Settings card (owner's call); going straight through is unchanged.
        onShowWelcomeGuide: { [weak self] in self?.showWelcomeWindow() }
    )
    /// Resident global hotkey for toggling. The callback only flips the setting (via settingsStore) and does not go through panelCoordinator:
    /// the latter is nil until the permission guide completes, while settingsStore exists from AppDelegate construction.
    private var edgeToggleHotKey: GlobalHotKeyMonitor?
    private var terminationTask: Task<Void, Never>?
    private var debugWindow: NSWindow?
    /// Exists only when `DOCK_HOVER_TRACE=1`; see `startMainLoopStallProbeIfTracing`.
    private var mainLoopStallProbe: Timer?
    private var permissionWindow: NSWindow?
    private var permissionHostingView: NSHostingView<PermissionOnboardingWindowContent>?
    private var welcomeWindow: NSWindow?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var messagingAutoRegisterSubscription: AnyCancellable?
    private var badgeContextSubscription: AnyCancellable?
    private var windowLiftSettingSubscription: AnyCancellable?
    private var trashSettingSubscription: AnyCancellable?
    /// Global mouse-wheel reversal. The active tap needs Accessibility authorization, so it hangs off the taskbar runtime
    /// (built in startTaskbarRuntime, torn down on suspend/terminate), with the same lifecycle semantics as the fullscreen tap.
    private var scrollReverserMonitor: ScrollReverserMonitor?
    private var scrollReverserSettingSubscription: AnyCancellable?
    /// Lives for the whole process: the guide windows need the appearance too, so it is never
    /// cancelled with the taskbar's subscriptions.
    private var appearanceSubscription: AnyCancellable?
    private let permissionService = PermissionService()
    private var installLocation: AppInstallLocation = .other
    private var permissionCoordinator: PermissionRecoveryCoordinator?
    private var permissionWatchdogTimer: Timer?
    private var permissionWatchdogGate = PermissionWatchdogGate()
    private let permissionProbeQueue = DispatchQueue(label: "app.neobar.NeoBar.permission-probe", qos: .utility)
    private var cachedAccessibilityTrusted = false
    private var hasStartedApp = false
    private let permissionLogger = Logger(subsystem: "app.neobar.NeoBar", category: "permissions")
    private lazy var statusMenuController = StatusMenuController(
        store: settingsStore,
        settingsCoordinator: settingsCoordinator,
        isAccessibilityTrusted: { [weak self] in self?.cachedAccessibilityTrusted ?? false },
        onShowDebugConsole: { [weak self] in self?.showDebugConsole() },
        onExportDebugSnapshot: { [weak self] in self?.exportDebugSnapshot() },
        onShowSettings: { [weak self] in self?.openSettings(nil) },
        onMenuVisibilityChanged: { [weak self] isOpen in
            self?.panelCoordinator?.setTaskbarMenuOpen(isOpen)
        },
        onQuit: { NSApp.terminate(nil) },
        hotKeyGlyphs: { [weak self] in
            self?.edgeToggleHotKey?.shortcut.displayGlyphs
                ?? GlobalHotKeyShortcut.edgeAutoHideMode.displayGlyphs
        },
        isToggleHotKeyRegistered: { [weak self] in self?.edgeToggleHotKey?.isRegistered ?? false },
        connectedScreens: { DisplayIdentity.connectedScreenOptions() }
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Line-buffer stdout: when launched from the command line / in the background, print() output to a file is block-buffered by default,
        // so logs only hit disk once the buffer fills. With line buffering every print is written immediately, making it easy to read logs in real time.
        setvbuf(stdout, nil, _IOLBF, 0)

        startMainLoopStallProbeIfTracing()
        StackPopupSnapshotProbe.runIfRequested()

        // Install lineage was captured before any store was constructed.
        let isFreshInstall = installLineage == .pristine
        // On a fresh install, seed window-lift avoidance as on; existing users keep it off (it rewrites other apps' window sizes,
        // so it must not be silently turned on by an upgrade). See `AppSettingsStore.seedWindowLiftEnabledForFreshInstall` for the rationale.
        if isFreshInstall {
            settingsStore.seedWindowLiftEnabledForFreshInstall(lineage: installLineage)
            settingsStore.armTaskbarPerDisplaySeedForFreshInstall(lineage: installLineage)
            pinnedFolderStore.seedDownloadsForFreshInstall(lineage: installLineage)
            keptAppStore.seedSystemAppLauncherForFreshInstall(lineage: installLineage) {
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil
            }
        }

        // The appearance setting is applied here and only here (`nil` = follow macOS). The frosted
        // material and Liquid Glass follow the **window's** `effectiveAppearance`, and SwiftUI's
        // `colorScheme` — which picks the `DockThemeTokens` column — comes from the same place, so
        // text and plate flip together. Do not set `appearance` on an individual panel or hosting
        // view: every window leaves it unset and inherits this one, including those created later
        // on demand (drawer, bubble, drag carrier) and the menus. The stack popups pin `darkAqua`
        // on their glass view alone (`stack-popup.md`).
        //
        // It stays ahead of the three launch branches (relocation guide, permission guide, normal
        // start) so each one's first window opens in the right appearance. `@Published` emits the
        // current value on subscription, which is what applies it at launch.
        appearanceSubscription = settingsStore.$appearanceMode
            .sink { NSApp.appearance = $0.nsAppearance }

        // Location classification must come **before** taking over other instances and registering the hotkey.
        // When run by double-clicking from a mounted disk image, if that temporary copy ran terminateOtherInstances(),
        // it would kill the /Applications instance the user is actually using, while itself showing only a move-to-Applications guide;
        // and if it grabbed the global hotkey, the normal instance's ⌥⇧⌘D would stop working.
        let location = AppInstallLocation(
            bundleURL: Bundle.main.bundleURL,
            isReadOnlyVolume: { [permissionService] in permissionService.isReadOnlyVolume($0) }
        )
        installLocation = location
        let trusted = permissionService.hasRequiredPermissions()
        cachedAccessibilityTrusted = trusted
        logPermissionLaunch(installLocation: location, isTrusted: trusted)

        if !location.isTransient {
            terminateOtherInstances()

            // Register the hotkey before building the status menu: the menu build reads the registration state to decide whether to show the shortcut hint.
            // Carbon hotkeys don't depend on Accessibility permission, so there's no need to wait for the permission-guide branch.
            // If the user customized it, use the saved combination; bad data has already fallen back to nil when the store read it (= default ⌥⇧⌘D).
            let shortcut = settingsStore.edgeToggleShortcut.map(GlobalHotKeyShortcut.init(stored:))
                ?? .edgeAutoHideMode
            let hotKey = GlobalHotKeyMonitor(shortcut: shortcut) { [weak self] in
                self?.settingsStore.toggleEdgeAutoHideMode()
            }
            edgeToggleHotKey = hotKey
            let hotKeyStatus = hotKey.start()
            if hotKeyStatus != .registered {
                Logger(subsystem: "app.neobar.NeoBar", category: "hotkey")
                    .warning("常驻切换全局快捷键注册失败：\(String(describing: hotKeyStatus), privacy: .public)，本次启动不重试")
            }

            _ = statusMenuController
        }

        let coordinator = PermissionRecoveryCoordinator(
            handler: self,
            permissionService: permissionService,
            installLocation: location
        )
        permissionCoordinator = coordinator
        coordinator.launched(trusted: trusted)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Re-check immediately when the user switches back from System Settings, without waiting for the next poll.
        permissionCoordinator?.applicationDidBecomeActive()
        if !installLocation.isTransient {
            Task { @MainActor [weak self] in
                _ = await self?.settingsCoordinator.refreshLaunchAtLoginState()
            }
        }
    }

    private func logPermissionLaunch(installLocation: AppInstallLocation, isTrusted: Bool) {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String ?? "unknown"
        permissionLogger.info("""
            permission launch version=\(version, privacy: .public) \
            build=\(build, privacy: .public) \
            location=\(installLocation.rawValue, privacy: .public) \
            trusted=\(isTrusted, privacy: .public) \
            bundlePath=\(Bundle.main.bundleURL.path, privacy: .private(mask: .hash))
            """)
    }

    /// Another bundle with the same bundle id (the official `/Applications` build vs. a dev build in the build directory) can
    /// run at the same time, so two identical taskbars appear on screen and nobody can say which version was measured;
    /// on 2026-07-21 this led to a fix that was never actually verified being judged "doesn't work" and the whole thing being rolled back.
    ///
    /// We take a "later launch takes over" approach: the new instance kicks out the old one. The reverse (the new one quitting itself) would block the
    /// verification build during development, and also contradicts the existing behavior of `Scripts/build_and_run.sh` which pkills first and then launches.
    /// It uses a polite `terminate()` rather than a hard kill, so the old instance's `stopAndRestore` restores the lifted windows
    /// to their places; it only force-quits if the old instance is slow to exit, to avoid the original "two taskbars" symptom recurring.
    private func terminateOtherInstances() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let myPID = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != myPID && !$0.isTerminated }
        guard !others.isEmpty else { return }

        let logger = Logger(subsystem: "app.neobar.NeoBar", category: "instance")
        for app in others {
            logger.warning("""
                发现另一个NeoBar实例，终止它：pid=\(app.processIdentifier, privacy: .public) \
                path=\(app.bundleURL?.path ?? "(unknown)", privacy: .public)
                """)
            app.terminate()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            for app in others where !app.isTerminated {
                logger.error("旧实例 pid=\(app.processIdentifier, privacy: .public) 3 秒内未退出，强制结束")
                app.forceTerminate()
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // The event loop is still running while waiting for cleanup (stopAndRestore): first cut off hotkey input so settings can't keep being toggled,
        // and have the coordinator cancel in-flight restore tasks. Setting a phase alone can't stop a Task that has already entered an await,
        // which would go on to launch a new instance after quit.
        edgeToggleHotKey?.stop()
        // The wheel tap is torn down first for the same reason: each extra second the process lives before exiting means another second of system-wide scrolling passing through it.
        scrollReverserMonitor?.stop()
        scrollReverserMonitor = nil
        permissionCoordinator?.terminationRequested()

        guard let controller = windowLiftAvoidanceController else { return .terminateNow }
        // Without permission AX can't write to windows, so waiting on stopAndRestore would be a wasted wait.
        guard permissionService.hasRequiredPermissions() else { return .terminateNow }
        guard terminationTask == nil else { return .terminateLater }

        terminationTask = Task { @MainActor [weak self] in
            await controller.stopAndRestore()
            self?.terminationTask = nil
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        SystemResizeCursor.shared.reset()   // never leave the ▲▼ or a hidden pointer behind us
        SystemCursorHider.shared.show()
        trashSettingSubscription = nil
        TrashStateStore.shared.stop()
        edgeToggleHotKey?.stop()
        scrollReverserMonitor?.stop()
        scrollReverserMonitor = nil
        DocumentUsageStore.shared.stop()
        permissionCoordinator?.terminationRequested()
        windowLiftAvoidanceController?.stop()
        // The private Space is reclaimed by WindowServer when the process dies; this just avoids leaving a junk Space behind.
        panelCoordinator?.overlaySpaceHost?.tearDown()
        runtime.stop()
    }

    // MARK: - First-run welcome guide

    /// One-time first-run guide: suggests collapsing the system Dock.
    ///
    /// Called once at the end of `startTaskbarRuntime()`, that is, the moment when "permission is granted, panels are built, and the taskbar is really running".
    /// A temporary copy (the one double-clicked from within a DMG) never gets here: in
    /// `PermissionRecoveryMachine` it has only the one effect `showGuide`. This is correct, since that copy
    /// disappears once unmounted and shouldn't teach it to configure the system.
    private func presentWelcomeGuideIfNeeded() {
        // First block with two conditions that need no I/O, saving the async read on the vast majority of launches.
        guard !settingsStore.hasSeenWelcome else { return }

        let canWrite = nativeDockPreferencesService.isAvailable
        guard canWrite else {
            _ = WelcomeGuideDecision.evaluate(
                hasSeenWelcome: false,
                canWriteDockPreferences: false,
                dockAutohideEnabled: nil
            )
            settingsStore.setHasSeenWelcome(true)
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            let state = await self.nativeDockPreferencesService.currentAutohideState()
            // The user may have already seen/changed it elsewhere during this await, so re-read the flag.
            switch WelcomeGuideDecision.evaluate(
                hasSeenWelcome: self.settingsStore.hasSeenWelcome,
                canWriteDockPreferences: true,
                dockAutohideEnabled: state?.enabled
            ) {
            case .present:
                self.showWelcomeWindow()
            case .skipAndMarkSeen:
                self.settingsStore.setHasSeenWelcome(true)
            case .skipWithoutMarking:
                break
            }
        }
    }

    private func showWelcomeWindow() {
        if let welcomeWindow {
            welcomeWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let content = WelcomeGuideWindowContent(
            onApply: { [weak self] selection in self?.applyWelcomeSelection(selection) },
            onDismiss: { [weak self] in self?.dismissWelcomeGuide() }
        )
        let hosting = NSHostingView(rootView: content)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: WelcomeGuideView.contentWidth, height: 320),
            // Unlike the permission guide, this window is **closable**: without permission the app can't be used at all, so closing that window would be meaningless;
            // this one is only a suggestion and the user has the right to just close it (closing equals "later", see windowWillClose).
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = Self.localizedDisplayName
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.delegate = self
        welcomeWindow = window

        // Height is measured the same way as the permission guide: the root view is wrapped in a ScrollView, so a one-shot probe measures the natural height without scrolling.
        let probe = NSHostingView(rootView: WelcomeGuideView(onApply: { _ in }, onDismiss: {}))
        probe.setFrameSize(NSSize(width: WelcomeGuideView.contentWidth, height: 0))
        probe.layoutSubtreeIfNeeded()
        let available = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? 900
        window.setContentSize(NSSize(
            width: WelcomeGuideView.contentWidth,
            height: max(200, min(probe.fittingSize.height, available - 80))
        ))

        window.center()
        window.makeKeyAndOrderFront(nil)
        // NeoBar is an accessory app right now; without an explicit activate, this window would be stacked behind the foreground app,
        // which is the same pitfall as the 2026-07-29 "Check for Updates seems broken" incident.
        // Note: **do not** casually change it to .regular -- that would make a NeoBar icon appear in the Dock,
        // which contradicts exactly what this window is trying to say.
        NSApp.activate(ignoringOtherApps: true)
    }

    /// "Apply recommended settings": writes the system Dock preferences according to which items the user ticked. The hide tier is auto-hide + no wake
    /// (the recommended tier decided by the owner on 2026-08-20).
    ///
    /// It goes through `applyNativeDock(recommendations:)`, the sole write entry point, so the four-quadrant readback and mirror sync come for free;
    /// don't start a separate defaults write here. The three items are merged into a single `killall Dock`, so the screen flashes only once.
    private func applyWelcomeSelection(_ selection: WelcomeGuideSelection) {
        settingsStore.setHasSeenWelcome(true)
        closeWelcomeWindow()

        let recommendations = selection.recommendations(hideDelay: AppSettingsStore.neverWakeDelay)
        // When nothing is ticked the button is already grayed out; this is a fallback: write nothing, and so don't restart the Dock and flash the screen for no reason.
        guard !recommendations.isEmpty else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await self.settingsCoordinator.applyNativeDock(
                recommendations: recommendations
            )
            guard let error = outcome.error else { return }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(localized: "Couldn’t Change Dock Settings")
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: String(localized: "OK"))
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    /// "Later", and also closing the window directly. **Still recorded as seen**, so it won't nag again;
    /// people who want to change it can use the system Dock slider in the status-bar menu.
    private func dismissWelcomeGuide() {
        settingsStore.setHasSeenWelcome(true)
        closeWelcomeWindow()
    }

    private func closeWelcomeWindow() {
        guard let window = welcomeWindow else { return }
        welcomeWindow = nil
        window.delegate = nil
        window.orderOut(nil)
        window.close()
    }

    /// The guide window. The copy length varies a lot with state (it nearly doubles when the troubleshooting section expands),
    /// so the width is fixed, the height follows the content, and it is capped by the current screen's visible height.
    private func showPermissionWindow() {
        guard let coordinator = permissionCoordinator else { return }
        if let permissionWindow {
            resizePermissionWindowToFit()
            permissionWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingView(rootView: PermissionOnboardingWindowContent(coordinator: coordinator))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: PermissionOnboardingView.contentWidth, height: 260),
            styleMask: [.titled, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = Self.localizedDisplayName
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        permissionWindow = window
        permissionHostingView = hosting
        resizePermissionWindowToFit()
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func resizePermissionWindowToFit() {
        guard let window = permissionWindow, let coordinator = permissionCoordinator else { return }

        // Use a one-shot probe to measure the "natural height without scrolling": the real root view is wrapped in a ScrollView,
        // so its own fittingSize can't tell how tall the content is.
        let probe = NSHostingView(rootView: PermissionOnboardingView(coordinator: coordinator))
        probe.setFrameSize(NSSize(width: PermissionOnboardingView.contentWidth, height: 0))
        probe.layoutSubtreeIfNeeded()
        let natural = probe.fittingSize.height

        let available = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? 900
        let height = max(200, min(natural, available - 80))
        let size = NSSize(width: PermissionOnboardingView.contentWidth, height: height)
        guard window.contentView?.frame.size != size else { return }

        let before = window.frame
        window.setContentSize(size)
        // Keep the visual center fixed so the window doesn't drift downward when the copy gets longer.
        let after = window.frame
        window.setFrameOrigin(NSPoint(
            x: before.midX - after.width / 2,
            y: before.midY - after.height / 2
        ))
    }

    private func closePermissionWindow() {
        permissionWindow?.orderOut(nil)
        permissionWindow?.close()
        permissionWindow = nil
        permissionHostingView = nil
    }

    private func startTaskbarRuntime() {
        DiagnosticReport.armFirstActivationSnapshot()
        appMembershipController.reconcileInvalidMemberships()
        runningApplicationStore.start()
        runtime.start()

        // Auto tier of the messaging list: register an app only when it both matches the
        // whitelist / social-networking category **and** currently has an identifiable main
        // window, then seed kept on first registration (default-keep). Kept no longer excludes
        // messaging, so there is no kept filter.
        //
        // The window snapshot is combined in because the capability gate needs titles — the
        // process store alone cannot tell whether the zone can represent the app. Registration
        // is once-and-for-all (see `MessagingAppStore.autoRegister`), so the "identifiable right
        // now" reading is only ever consumed for apps not yet in the list; existing members are
        // never re-tested and therefore never flap out of the zone.
        messagingAutoRegisterSubscription = runningApplicationStore.$runningBundleIDs
            .combineLatest(runtime.$snapshot)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] running, snapshot in
                guard let self else { return }
                let identifiable = MessagingZoneAdmission.mainWindowIdentifiableBundleIDs(
                    windows: StripItem.items(from: snapshot).map {
                        .init(bundleID: $0.bundleIdentifier ?? "",
                              title: $0.title,
                              isAppLevelFallback: $0.isAppLevelFallback)
                    },
                    titleMatchesAppName: { title, bundleID in
                        AppDisplayNameResolver.titleMatchesAppName(title, bundleID: bundleID)
                    }
                )
                self.appMembershipController.autoRegisterMessaging(
                    runningBundleIDs: running,
                    mainWindowIdentifiableBundleIDs: identifiable
                )
            }

        // Badge read scope = messaging-app **identity** ∩ running - drawer (since 2026-08-23 no longer requires being in the messaging area:
        // single-window apps like Messages / Slack that can't enter the area get their red dot drawn on the card in their regular area). Whenever the list or the running set
        // changes it is pushed to BadgeStore: when the readable set is empty it generates zero AX traffic per tick; a set change triggers a re-walk of the Dock tree,
        // and "messaging app just launched, badge on the new tile" relies on this to catch up within ~1s. The subscription precedes badgeStore.start(),
        // so the context is in place before the first read (a @Published subscription emits the current value immediately).
        // `isMessagingApp` reads back from the store: there's a receive(on:) async dispatch here, publishing has long completed, and what's read is the new value.
        badgeContextSubscription = Publishers.CombineLatest3(
            messagingStore.$bundleIDs,
            drawerStore.$bundleIDs,
            runningApplicationStore.$runningBundleIDs
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _, drawer, running in
            guard let self else { return }
            self.badgeStore.updateMessagingContext(
                visibleMessagingIDs: AppMembershipProjection.badgeEligibleIDs(
                    isMessagingApp: { self.messagingStore.isMessagingApp($0) },
                    drawerIDs: drawer,
                    runningIDs: running
                ),
                runningBundleIDs: running
            )
        }

        let coordinator = TaskbarScreenOrchestrator(
            runtime: runtime,
            drawerStore: drawerStore,
            messagingStore: messagingStore,
            badgeStore: badgeStore,
            stripOrderStore: stripOrderStore,
            drawerOrderStore: drawerOrderStore,
            settingsStore: settingsStore,
            pinnedFolderStore: pinnedFolderStore,
            folderCoverStore: folderCoverStore,
            shelfStore: shelfStore,
            keptAppStore: keptAppStore,
            runningApplicationStore: runningApplicationStore,
            appMembershipController: appMembershipController,
            displayTopologyStore: displayTopologyStore
        )
        panelCoordinator = coordinator
        runtime.onToggleDrawer = { [weak coordinator] in coordinator?.toggleDrawer() }
        // Menu height slider ↔ every bar's grip-drag transaction. Weak: the orchestrator is
        // dropped on permission loss.
        settingsCoordinator.taskbarHeightSessionHandler = { [weak coordinator] editing in
            coordinator?.setSettingsHeightSessionActive(editing)
        }
        settingsCoordinator.taskbarHeightUpdateHandler = { [weak coordinator] in
            coordinator?.commitSettingsPanelHeight()
        }
        coordinator.onAddFolder = { [weak self] in self?.presentAddPinnedFolderPanel() }
        // Right-clicking the taskbar / capsule shows the NeoBar menu. Reaching here means permission is granted and this isn't a temporary copy,
        // so the status-bar menu has necessarily already been built (the non-temporary branch of `applicationDidFinishLaunching`),
        // and there is no problem of "conjuring a status-bar icon out of thin air".
        coordinator.onRequestTaskbarMenu = { [weak self] event, view in
            self?.statusMenuController.popUpFromTaskbar(with: event, in: view)
        }
        coordinator.start()
        let windowLiftAvoidanceController = WindowLiftAvoidanceController(host: coordinator)
        self.windowLiftAvoidanceController = windowLiftAvoidanceController
        // Avoidance is off by default; at startup first feed the persisted switch state in. start() itself honors this flag,
        // and when unchecked it simply returns idly, so neither timer (the global scan at idle 1 Hz / in-session 5 Hz,
        // nor the 20 Hz tracked probe) will start.
        windowLiftAvoidanceController.setEnabledBySetting(settingsStore.windowLiftEnabled)
        windowLiftAvoidanceController.start()
        // The sink uses the new value from the closure parameter: @Published publishes before the assignment completes, so reading the store back at this moment gives the old value.
        // Go through self?.windowLiftAvoidanceController rather than strongly capturing the controller: the permission-recovery path sets it to nil.
        windowLiftSettingSubscription = settingsStore.$windowLiftEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in
                self?.windowLiftAvoidanceController?.setEnabledBySetting(enabled)
            }
        // Ledger counting the most-used files: directory watching + activation resampling both hang off the taskbar runtime.
        DocumentUsageStore.shared.start()
        TrashStateStore.shared.setEnabled(settingsStore.showTrash)
        TrashStateStore.shared.start(revealOpenedWindow: TrashStateStore.revealTrashWindow(runtime: runtime))
        trashSettingSubscription = settingsStore.$showTrash
            .removeDuplicates()
            .sink { enabled in TrashStateStore.shared.setEnabled(enabled) }
        // Same wiring as wheel reversal. The sink uses the new value from the closure parameter and does not read the store back (@Published publishes before assignment).
        applyScrollReverser(enabled: settingsStore.scrollReverserEnabled)
        scrollReverserSettingSubscription = settingsStore.$scrollReverserEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in
                self?.applyScrollReverser(enabled: enabled)
            }
        badgeStore.start()
        // Only once the taskbar is really up does "how to configure it" make sense. It's placed here rather than at the launch moment because
        // the user has to see what the taskbar looks like first for the line "when both sit on the bottom edge they obscure each other" to have a referent.
        presentWelcomeGuideIfNeeded()
        // Probe conclusion (2026-07-06, phase 0 probe 3): Finder windows' AX attribute table lists AXDocument but it never has a value
        // (kAXErrorNoValue), and AXProxy/AXTitleUIElement have only the folder name and no path -- "drag a Finder
        // window icon on the taskbar to pin a folder" is infeasible and was cut per the contingency plan; dropping into the pinned area only goes through real file URLs (system drag and drop).
    }

    /// Entry point for right-clicking a folder chip / staging cell, "Add Pinned Folder...".
    /// An accessory app must activate first, otherwise NSOpenPanel won't come to the foreground.
    func presentAddPinnedFolderPanel() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Pin")
        panel.message = String(localized: "Choose a folder to pin to the taskbar")
        if panel.runModal() == .OK {
            for url in panel.urls { pinnedFolderStore.add(url.path) }
        }
    }

    /// The precondition for the Settings window to exist is "the taskbar is running normally".
    ///
    /// For a temporary copy, before authorization, and in the recovery state after permission loss, the only thing the user should do right now is deal with the guide window;
    /// opening a full settings surface then would only cover the guide window, and all its switches would act on a taskbar that never came up
    /// (this self-contradictory picture is exactly what a user on Sspai reported on 2026-08-03). So in all these cases we bring the guide window to the front instead.
    @objc func openSettings(_ sender: Any?) {
        guard !installLocation.isTransient,
              hasStartedApp,
              permissionService.hasRequiredPermissions() else {
            showPermissionWindow()
            return
        }
        settingsWindowController.present()
    }

    func exportDebugSnapshot() {
        runtime.exportDebugSnapshot()
    }

    func showDebugConsole() {
        if let existing = debugWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "任务条调试台"
        window.contentView = NSHostingView(
            rootView: DebugConsoleView()
                .environmentObject(runtime)
                .environmentObject(runtime.debugState)
        )
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        debugWindow = window
    }

    /// Main-thread stall probe: installed only when `DOCK_HOVER_TRACE=1` (`HoverTrace.isEnabled` is a constant,
    /// so when off this timer is never created, with zero everyday overhead).
    ///
    /// Fires every 8ms, running in `.common` -- **it must be `.common`**, otherwise it would stop on its own during menu/drag interactions,
    /// which are exactly the periods we most want to measure.
    private func startMainLoopStallProbeIfTracing() {
        guard HoverTrace.isEnabled else { return }
        // The timer callback is a Sendable closure and can't mutate a captured var directly; wrap it in a box used only on the main thread.
        let clock = StallProbeClock(expected: CACurrentMediaTime() + 0.008)
        let timer = Timer(timeInterval: 0.008, repeats: true) { _ in
            let now = CACurrentMediaTime()
            HoverTrace.mainLoopStall(lateMs: (now - clock.expected) * 1000)
            clock.expected = now + 0.008
        }
        RunLoop.main.add(timer, forMode: .common)
        mainLoopStallProbe = timer
    }

}

// MARK: - Side-effect execution for the permission state machine

extension AppDelegate: PermissionEffectHandler {
    func startApp() {
        guard !hasStartedApp else { return }
        hasStartedApp = true
        startTaskbarRuntime()
    }

    func setActivationPolicy(_ policy: PermissionActivationPolicy) {
        switch policy {
        case .accessory:
            NSApp.setActivationPolicy(.accessory)
        case .regular:
            // With no permission the taskbar creates no panels, and staying .accessory would leave the user with only a possibly
            // not-obvious status-bar icon; first use the regular app policy to bring the guide window to the foreground.
            NSApp.setActivationPolicy(.regular)
        }
    }

    func showGuideWindow() { showPermissionWindow() }
    func updateGuideWindow() { resizePermissionWindowToFit() }
    func closeGuideWindow() { closePermissionWindow() }

    func openAccessibilitySettings() {
        guard let url = AccessibilitySettingsLink.url else { return }
        NSWorkspace.shared.open(url)
    }

    func openApplicationsFolder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications", isDirectory: true))
    }

    func releaseHotKey() { edgeToggleHotKey?.stop() }

    func registerHotKey() { _ = edgeToggleHotKey?.start() }

    /// Sole open/close entry point for wheel reversal: on = build monitor + start tap, off = tear down cleanly.
    /// `settingEnabled` is passed by the caller (the subscription's new value or the store value at startup) and is not read back from the store here:
    /// @Published publishes before the assignment completes, so reading back inside the sink gets the old value (repo convention).
    private func applyScrollReverser(enabled settingEnabled: Bool) {
        let enabled = ScrollReverserDecision.isEnabled(
            settingEnabled: settingEnabled,
            environment: ProcessInfo.processInfo.environment
        )
        if enabled {
            guard scrollReverserMonitor == nil else { return }
            let monitor = ScrollReverserMonitor()
            scrollReverserMonitor = monitor
            monitor.start()
        } else {
            scrollReverserMonitor?.stop()
            scrollReverserMonitor = nil
        }
    }

    func terminateSelf() { NSApp.terminate(nil) }

    // MARK: Runtime recovery

    /// Sampled every 5 seconds. The debounce decision lives in the pure `PermissionLossDetector`; this only feeds it data.
    /// Note this is **not** the protection mechanism for window snapshots: that is self-checked by `WindowLiftAvoidanceController`
    /// in its own polling; with a session / pending-restore state it is still 0.2 seconds, dropping to 1 second only when idle with no snapshot.
    func startWatchdog() {
        stopWatchdog()
        permissionWatchdogGate.start()
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.schedulePermissionProbe()
            }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        permissionWatchdogTimer = timer
    }

    func stopWatchdog() {
        permissionWatchdogTimer?.invalidate()
        permissionWatchdogTimer = nil
        permissionWatchdogGate.stop()
    }

    private func schedulePermissionProbe() {
        guard let generation = permissionWatchdogGate.beginProbe() else { return }
        let permissionService = permissionService
        permissionProbeQueue.async { [weak self] in
            let trusted = permissionService.hasRequiredPermissions()
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.permissionWatchdogGate.completeProbe(generation: generation) else { return }
                self.cachedAccessibilityTrusted = trusted
                self.permissionCoordinator?.sampleTrust(trusted)
            }
        }
    }

    func freezeLiftSnapshots() {
        windowLiftAvoidanceController?.beginPermissionUncertainty()
    }

    func unfreezeLiftSnapshots() {
        windowLiftAvoidanceController?.endPermissionUncertainty()
    }

    func suspendPanelsAndStores() {
        trashSettingSubscription = nil
        TrashStateStore.shared.stop()
        // The Settings window must be closed too: once permission is lost the whole taskbar is torn down, and leaving a window that changes taskbar appearance
        // is meaningless and would also block the recovery guide that pops up right after.
        settingsWindowController.close()
        // The welcome guide likewise, and more glaringly: the taskbar is gone, yet a window teaching you how to configure it remains on screen.
        closeWelcomeWindow()
        messagingAutoRegisterSubscription?.cancel()
        messagingAutoRegisterSubscription = nil
        badgeContextSubscription?.cancel()
        badgeContextSubscription = nil
        runtime.onToggleDrawer = nil
        scrollReverserSettingSubscription?.cancel()
        scrollReverserSettingSubscription = nil
        scrollReverserMonitor?.stop()
        scrollReverserMonitor = nil
        DocumentUsageStore.shared.stop()
        panelCoordinator?.suspendAndRelease()
        panelCoordinator = nil
        badgeStore.stop()
        runtime.stop()
        runningApplicationStore.stop()
    }

    /// Permission has just returned, so AX can write to windows -- deferring the restore to this moment in the whole recovery chain is for exactly this reason.
    func restoreLiftedWindows(episode: UInt64) async {
        await windowLiftAvoidanceController?.restoreAndStopForPermissionRecovery()
        windowLiftAvoidanceController = nil
    }

    func launchNewInstance(episode: UInt64) async -> Result<Void, Error> {
        let configuration = NSWorkspace.OpenConfiguration()
        // Spawning a second instance here is **deliberate**: the new instance's terminateOtherInstances() will come and reap this one.
        // This is not the same thing as the guardrail "disable open -n in build_and_run.sh": that one forbids the build script
        // from conjuring an extra copy without waiting for the old process to exit, producing two identical taskbars.
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        let url = Bundle.main.bundleURL

        return await withCheckedContinuation { continuation in
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
                // This completion is called back on a concurrent queue. Only resume here;
                // the follow-up work touching the state machine / hotkey / UI is all done in the coordinator's @MainActor Task.
                if let error {
                    continuation.resume(returning: .failure(error))
                } else {
                    continuation.resume(returning: .success(()))
                }
            }
        }
    }
}

extension AppDelegate: NSWindowDelegate {
    /// The user closing the welcome guide directly equals "later" -- **still must be recorded as seen**,
    /// otherwise closing it once would make it pop up again on the next launch.
    ///
    /// The path where the program closes the window itself (`closeWelcomeWindow()`) never reaches here: it first sets `welcomeWindow`
    /// to nil and detaches the delegate, and only then calls `close()`. So this callback only means "the user closed it themselves"
    /// and never double-marks with `applyWelcomeSelection(_:)` / `dismissWelcomeGuide()`.
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === welcomeWindow else { return }
        welcomeWindow = nil
        window.delegate = nil
        settingsStore.setHasSeenWelcome(true)
    }
}

/// Clock for the main-loop stall probe (read/written only inside the main-thread timer callback; `@unchecked` because the Timer closure requires Sendable).
private final class StallProbeClock: @unchecked Sendable {
    var expected: CFTimeInterval
    init(expected: CFTimeInterval) { self.expected = expected }
}

private extension AppearanceMode {
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}
