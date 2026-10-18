import AppKit
import CoreServices
import SwiftUI

/// A chip that represents an app by bundle identifier rather than a concrete window.
/// Renders the three launcher states (not running / running-no-window / running-hidden)
/// and handles tap-to-launch, tap-to-reopen, and the launch bounce animation.
///
/// Shared by the drawer (collected apps, scale 0.7) and the main strip (messaging
/// and kept apps, scale 1.0). Call-site differences are injected via
/// `membershipItems` (Keep in Dock / Pin to the left of the Dock bar).

/// How a `LauncherChip` is laid out: a card on the bar, or a cell of the drawer's stack grid
/// (`StackCellMetrics.drawer`: the system Apps grid's proportions, the app's name under the icon).
enum LauncherChipLayout {
    case bar
    case stackCell
}

struct LauncherChip: View {
    let bundleID: String
    let isRunning: Bool   // supplied by the displayed zone's runtime/process projection
    let isHidden: Bool    // supplied by the displayed zone's runtime/process projection
    /// Whether Finder currently has a real window (not the app-level fallback). **Only the Finder branch of the default left-click behavior reads it.**
    /// Finder cannot be hidden, and with no window it must open the home directory, hence "finder" in the name; do not use it as a general "has a window" flag.
    /// **Deliberately has no default value**: if the drawer misses passing it, every click on Finder would open a new home-directory window, and that kind of mistake must be a compile error.
    let finderHasRealWindow: Bool
    /// Runtime-owned launch session state. The chip only renders this state; it does
    /// not infer readiness from process state or own a second launch timeout.
    let isLaunching: Bool
    /// Height factor (the strip passes `DockPanelHeight.scale`; the drawer is fixed at 0.7). **Deliberately has no default value**: a missed argument must be a compile error,
    /// see AGENTS "Taskbar Size Tiers".
    let scale: CGFloat
    /// Bar card or drawer grid cell. No default, same reason as `scale`.
    let layout: LauncherChipLayout
    /// Hover effect tier. **Also deliberately has no default value**: a missed argument must be a compile error, same reason as `scale`.
    /// The drawer call site intentionally hardcodes `.quiet` (the drawer is unaffected by that setting, owner 2026-08-02 / 2026-08-17).
    let hoverStyle: HoverStyle
    /// Where hover comes from. The task strip passes `.resolved(...)` (computed by the single tracking region covering the whole strip); the drawer passes `.selfTracked`
    /// (that panel has no tracking region). **Deliberately has no default value**, same reason as `scale` / `hoverStyle`.
    let hoverInput: ChipHoverInput
    /// Data source for the Dock-style window list (evaluated only at the moment the right-click menu is built; reads the snapshot, no AX).
    /// **Deliberately has no default value**: for app-level icons a missed argument = the whole window list silently disappears, and that kind of mistake must be a compile error.
    let windowEntriesProvider: () -> [WindowMenuEntry]
    /// Click a window row -> activate (minimized windows are restored). **Deliberately has no default value**, same reason as above.
    let onActivateWindow: (String) -> Void
    /// Membership / management menu items (at the end of the right-click menu), such as "Keep in Dock" and "Pin to the left of the Dock bar".
    /// Empty array = no membership items.
    var membershipItems: [LauncherMembershipItem] = []
    /// Unread badge text (for messaging-app cards: the icon in the messaging zone, or the keep placeholder in the regular zone); `nil` = draw nothing. Drawn inside the chip rather than layered in a ZStack by the caller,
    /// so hover enlargement, press rebound, and tier scaling all carry it along; see `ChipBadgeView` for the reason.
    var badgeText: String? = nil
    /// Whether this icon's cell is currently empty because the icon is **being held in the hand** (`DragController.hiddenSlotPayload`).
    /// As soon as it becomes true, clear the press scale: reordering moves it and SwiftUI cancels the press gesture, so `isTapPressed` can only be reset by the 1s
    /// watchdog, and on reveal at drop it may still be 0.93, a bit off from the carrier that settles at 1.0. Same reason as `ChipView.slotHidden`.
    var slotHidden: Bool = false
    /// Hover feedback hold (needed only by the `.selfTracked` drawer): the cell that has just settled with the pointer not yet moved
    /// (`DragController.hoverHoldPayload`) and the cell currently being held. `.onHover` is still
    /// true while the cell is transparent, so without holding, the moment of reveal on drop would jump straight to 1.10: the form the quiet tier's "drop-in jitter" takes in the drawer.
    /// The task strip uses `.resolved(...)`, where hover is suppressed at the source by the whole-strip tracking region, so the default false is passed here.
    var hoverSuppressed: Bool = false
    /// When set, replaces the default tap behavior (drawer show/hide toggle). Used by
    /// app-level strip entries that must reopen a missing main window.
    var onTap: (() -> Void)? = nil
    /// Starts the runtime-owned launch session and returns whether launch dispatch
    /// succeeded. A false result keeps the drawer open and never starts local bounce.
    var onLaunch: () -> Bool = { false }
    /// Fired when the tap dispatches an "open" action: unhide+activate (running but not active) or launch (not running).
    /// Hide taps (app is active → minimize) do NOT fire this — the drawer stays open for those.
    /// Only set by DrawerView; strip messaging chips leave it nil.
    var onPrimaryAction: (() -> Void)? = nil

    @Environment(\.colorScheme) private var colorScheme
    private var theme: DockThemeTokens { .resolved(for: colorScheme) }
    /// See `EnvironmentValues.isDragCarrierSnapshot`: when snapshotting a copy, do not draw the dot or bake in the shadow.
    @Environment(\.isDragCarrierSnapshot) private var isDragCarrierSnapshot
    @Environment(\.displayScale) private var displayScale
    /// A height drag is a new icon size every tick: reuse the rendered bitmap until it ends.
    @Environment(\.isPanelHeightResizing) private var isPanelHeightResizing

    /// Only useful for `.selfTracked` (the drawer). The task strip uses `.resolved(...)`, and this state stays untouched.
    @State private var selfHovering = false
    @State private var bounceUp = false
    @State private var bounceTimer: Timer?
    /// Press confirmation pulse. Before 2026-08-11 this component had **no press feedback at all**: the messaging zone (main window closed / not running),
    /// kept icons, and drawer icons did not move at all when pressed, while window cards and drawer capsules did. A pure view-layer signal, never fed to the
    /// planner / frontmost axis (AGENTS).
    @State private var isTapPressed = false
    private static let launchTraceEnabled =
        DebugSwitch.launchTrace.isEnabled(in: ProcessInfo.processInfo.environment)

    private var isHovering: Bool {
        guard !hoverSuppressed else { return false }
        switch hoverInput {
        case let .resolved(value): return value
        case .selfTracked: return selfHovering
        }
    }

    /// Master gate for hover visuals: always false under the "quiet" tier, so the icon does not scale, the name does not float out, and not even an animation transaction is produced.
    private var showsHover: Bool { hoverStyle.showsExpressiveHover(isHovering: isHovering) }
    /// Hover feedback for the quiet tier (always false on the standard tier). See `HoverStyle.showsQuietHoverFeedback`.
    private var quietHoverFeedback: Bool {
        hoverStyle.showsQuietHoverFeedback(isHovering: isHovering)
    }

    var body: some View {
        let visual = LauncherChipVisualPlan.visual(isRunning: isRunning)
        // **Hover changes no pixels, so no animation driver is attached**, word for word the same as `ChipView.bareIconChip`
        // (2026-08-17: it was removed there first and missed here, wasting a round of empty 0.18s animation).
        // For the reason see the comment on `bareIconChip`: once the main thread is busy macOS coalesces mouse-move events, and a sweep misses cells.
        //
        // **Here in particular the transaction must not reach the ancestor chain**: the launch bounce (`bounceUp`) lives in the icon below,
        // and an ancestor's hover transaction would hijack it. The quiet tier's highlight therefore goes through a sibling `.background` layer.
        let hover = ChipHoverVisual.resolve(progress: 0, scale: scale)
        let _ = ChipAnimationTrace.record(
            chipID: bundleID,
            kind: "launcher",
            visual: hover,
            isTapPressed: isTapPressed,
            showsHover: showsHover
        )
        return face(visual: visual, hover: hover)
        // Unread badge: **must be attached before the two scales** (owner 2026-08-17). See `ChipBadgeView`.
        .overlay(alignment: .topTrailing) {
            if let badgeText {
                ChipBadgeView(text: badgeText, scale: scale)
            }
        }
        // The running dot used to be attached **after** the enlargement (the dot did not enlarge with it), inconsistent with `ChipView.bareIconChip`;
        // this time both are aligned: in both places "icon + dot + badge" scale as a whole.
        .chipQuietHoverScale(quietHoverFeedback,
                             cardWidth: faceWidth,
                             scale: scale)
        .chipPressScale(isTapPressed)
        .contentShape(Rectangle())
        // On the task strip, hover is computed by the whole-strip tracking region and passed in; only the drawer (`.selfTracked`) attaches its own
        // `.onHover`, since that panel has no tracking region. For the cause see `StripHoverResolution`.
        .modifier(SelfTrackedHover(enabled: hoverInput == .selfTracked, isHovering: $selfHovering))
        .onChange(of: isHovering) { hovering in
            trace("isHovering=\(hovering)")
            ChipAnimationTrace.event(
                chipID: bundleID,
                kind: "launcher",
                event: ChipAnimationTraceEvent.hover(hovering),
                isTapPressed: isTapPressed,
                showsHover: hoverStyle.isExpressive && hovering
            )
        }
        .onTapGesture { handlePrimaryTap() }
        // A click during a launch session is a no-op anyway (AGENTS), so giving press feedback would be deceptive; this also avoids sharing an animation transaction with the
        // finite bounce (bounceUp offset) on the same icon.
        .chipPressGesture(
            isPressed: $isTapPressed,
            isEnabled: !isLaunching,
            onEvent: { pressed in
                ChipAnimationTrace.event(
                    chipID: bundleID,
                    kind: "launcher",
                    event: ChipAnimationTraceEvent.tap(pressed),
                    isTapPressed: pressed,
                    showsHover: showsHover
                )
            }
        )
        .nativeContextMenu { buildLauncherMenu() }
        .help(displayName)
        // Clear the press as soon as the cell is empty (see `slotHidden`). The icon is transparent now, so nobody sees this rebound.
        .onChange(of: slotHidden) { hidden in
            if hidden, isTapPressed { isTapPressed = false }
        }
        .onAppear {
            trace("appear isLaunching=\(isLaunching)")
            if isLaunching { startBounce() }
        }
        .onDisappear {
            trace("disappear cleanup")
            cleanupBounce()
        }
        .onChange(of: isLaunching) { newValue in
            trace("isLaunching=\(newValue)")
            if newValue { startBounce() } else { stopBounce() }
        }
        .onChange(of: bounceUp) { trace("bounceUp=\($0)") }
    }

    /// Width of what the hover lift scales: the bar card, or the whole grid cell.
    private var faceWidth: CGFloat {
        switch layout {
        case .bar: return ChipPillMetrics.cardWidth * scale
        case .stackCell: return StackCellMetrics.drawer.cellSize.width
        }
    }

    private func icon(size: CGFloat, bounceLift: CGFloat) -> some View {
        Image(nsImage: AppIconResolver.icon(for: bundleID, points: size, displayScale: displayScale,
                                             colorScheme: colorScheme, allowsRendering: !isPanelHeightResizing))
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size / 4, style: .continuous))
            .offset(y: bounceUp ? -bounceLift : 0)
            .animation(.easeInOut(duration: 0.25), value: bounceUp)
    }

    /// Same as `ChipView`: the dragged copy draws no dot (same as the native Dock).
    @ViewBuilder
    private func runningDot(visual: LauncherChipVisualPlan.Visual, diameter: CGFloat, bottomPadding: CGFloat) -> some View {
        if visual.showsRunningDot && !isDragCarrierSnapshot {
            Circle()
                .fill(theme.runningDot.color)
                .frame(width: diameter, height: diameter)
                .padding(.bottom, bottomPadding)
        }
    }

    @ViewBuilder
    private func face(visual: LauncherChipVisualPlan.Visual, hover: ChipHoverVisual) -> some View {
        switch layout {
        case .bar:
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                icon(size: hover.bareIconSize, bounceLift: 6)
                // Slot height = **resting** icon size. A slot smaller than the icon makes the whole block overflow downward (.top alignment),
                // with the result that "a running app's icon and a non-running one differ in height"; this view draws exactly the non-running kind.
                // Must be word for word the same as the iconOnly branch of `ChipView`.
                .frame(width: ChipPillMetrics.cardWidth * scale,
                       height: ChipPillMetrics.bareIconSlot * scale,
                       alignment: .top)
                Spacer(minLength: 0)
            }
            .frame(width: ChipPillMetrics.cardWidth * scale,
                   height: ChipPillMetrics.chipHeight * scale)
            .overlay(alignment: .bottom) {
                runningDot(visual: visual, diameter: ChipPillMetrics.runningDotSize * scale,
                           bottomPadding: ChipPillMetrics.runningDotBottomPadding * scale)
            }
        case .stackCell:
            // The folder popup's cell with an app in it. The dot sits in the icon's own
            // transparent bottom margin (~7pt of the 76pt icon) and hangs 1pt below the icon frame,
            // into the label gap: ~4pt clear of the artwork, 1pt above the label box.
            let cell = StackCellMetrics.drawer
            VStack(spacing: cell.labelGap) {
                icon(size: cell.iconSize, bounceLift: 6 * scale)
                    .overlay(alignment: .bottom) { runningDot(visual: visual, diameter: 4, bottomPadding: -1) }
                StackCellLabel(text: displayName, metrics: cell)
            }
            .padding(.top, cell.iconTop)
            .frame(width: cell.cellSize.width, height: cell.cellSize.height, alignment: .top)
        }
    }

    private func buildLauncherMenu() -> NSMenu {
        let menu = NSMenu()
        // Evaluated only once at the moment of right-click; for the non-running display state it is not even fetched (the list criterion follows the display zone).
        let windowEntries = isRunning ? windowEntriesProvider() : []
        // The menu's running state follows the "display state of the zone the icon is in" (isRunning prop) and no longer asks NSWorkspace independently; otherwise, in the pending-launch zone,
        // icons whose process is still alive (closing the window does not quit / resident) would wrongly report "Hide / Quit", contradicting their grayed-out "quit" look.
        let kinds = LauncherMenuPlan.itemKinds(isRunning: isRunning,
                                               isHidden: isHidden,
                                               hasWindows: !windowEntries.isEmpty,
                                               hasMembership: !membershipItems.isEmpty)
        // Fetch the app object only when Show/Hide/Quit really has to run; if it cannot be fetched, skip the item (a fallback for a briefly stale snapshot).
        let runningApps = Self.regularRunningApplications(bundleID: bundleID)
        for kind in kinds {
            switch kind {
            case .windowList:
                AppMenuBuilder.appendWindowList(to: menu, entries: windowEntries, activate: onActivateWindow)
            case .open:
                // Right-click "Open": reuse the runtime launch path but do not trigger onPrimaryAction,
                // otherwise right-click Open on a drawer icon would also close the drawer.
                menu.addItem(ClosureMenuItem(String(localized: "Open")) { launch(firePrimaryAction: false) })
            case .recentDocuments:
                // Finder's "Recents" is recently used folders (FXRecentFolders), the same criterion as the Finder card on the strip.
                if FinderTaskbarPolicy.isFinder(bundleID) {
                    AppMenuBuilder.appendFinderRecentFolders(to: menu)
                } else {
                    AppMenuBuilder.appendRecentDocuments(to: menu, bundleID: bundleID)
                }
            case .show:
                if !runningApps.isEmpty {
                    menu.addItem(ClosureMenuItem(String(localized: "Show")) {
                        for app in runningApps { _ = app.unhide() }
                        runningApps.first?.activate(options: .activateIgnoringOtherApps)
                    })
                }
            case .hide:
                if !runningApps.isEmpty {
                    menu.addItem(ClosureMenuItem(String(localized: "Hide")) {
                        for app in runningApps { _ = app.hide() }
                    })
                }
            case .quit:
                if !runningApps.isEmpty {
                    // Quit is always the last item, so the leading separator is added by this branch itself (the membership zone is already ordered before it);
                    // the guard is the same as .membership: do not add one if the menu is empty or the last item is already a separator, to avoid a double line.
                    if !menu.items.isEmpty, menu.items.last?.isSeparatorItem == false {
                        menu.addItem(.separator())
                    }
                    AppMenuBuilder.appendQuitItems(
                        to: menu,
                        bundleID: bundleID,
                        onForceQuit: { for app in runningApps { _ = app.forceTerminate() } }
                    ) {
                        for app in runningApps { _ = app.terminate() }
                    }
                }
            case .membership:
                // Before the membership zone, add a separator only when "the menu is non-empty and the last item is not a separator": it adds the
                // separator between Open/Recent Files and the membership items, while avoiding a double line when the recent-files zone already carries a trailing separator (and also covering the case where a running-state action is skipped by a race).
                if !menu.items.isEmpty, menu.items.last?.isSeparatorItem == false {
                    menu.addItem(.separator())
                }
                for item in membershipItems {
                    menu.addItem(AppMenuBuilder.membershipItem(item))
                }
            }
        }
        return menu
    }

    /// The single left-click gate covers both injected app-level behavior and the
    /// default drawer behavior. Runtime still performs the authoritative duplicate
    /// check for clicks that arrive before SwiftUI publishes the new launch state.
    private func handlePrimaryTap() {
        guard !isLaunching else {
            trace("tap ignored while launching")
            return
        }
        if let onTap { onTap() } else { handleTap() }
    }

    private func handleTap() {
        Self.performDefaultTap(bundleID: bundleID, isRunning: isRunning,
                               finderHasRealWindow: finderHasRealWindow,
                               launch: { launch() }, onOpen: onPrimaryAction)
    }

    /// Default left-click behavior when no `onTap` is injected (this is what drawer icons use). The only reason it is factored out as a static for `DrawerView` to reuse
    /// is that clicking the carrier during its return flight (`DragController.carrierClicks`) must also go through **the same** logic,
    /// and must not copy "collapse if frontmost, otherwise bring up" elsewhere.
    ///
    /// Finder is the sole exception (a path that appeared only after the drawer opened up on 2026-08-20): it **cannot be hidden** (`hide()` fails outright),
    /// and with no window `openApplication` only activates and opens no window, so a click looks like it does nothing. Hence Finder never collapses;
    /// with no real window it opens a new window per Finder's own "New Finder windows show" setting, sharing
    /// `FinderNewWindowOpener` with the resident card on the strip (it blocks waiting for Finder's reply, so it runs on the `actionQueue`).
    /// - Parameters:
    ///   - finderHasRealWindow: whether Finder currently has a real window. Only the Finder branch uses it, but it has no default value:
    ///     omitting it would silently take the wrong branch.
    ///   - launch: how to launch when not running (the caller decides whether to also call `onOpen`).
    ///   - onOpen: the side action when bringing up (unhide + open): the drawer passes "close the drawer".
    static func performDefaultTap(bundleID: String, isRunning: Bool, finderHasRealWindow: Bool,
                                  launch: () -> Void, onOpen: (() -> Void)?) {
        if isRunning {
            let runningApps = regularRunningApplications(bundleID: bundleID)
            if FinderTaskbarPolicy.isFinder(bundleID) {
                for app in runningApps { _ = app.unhide() }
                if finderHasRealWindow {
                    runningApps.first?.activate(options: .activateIgnoringOtherApps)
                } else {
                    AppRuntime.actionQueue.async { FinderNewWindowOpener.openNewWindow() }
                }
                onOpen?()
                return
            }
            if runningApps.contains(where: \.isActive) {
                // Frontmost -> collapse (minimize): the drawer stays open
                for app in runningApps { _ = app.hide() }
            } else {
                // Not active / hidden / window closed -> bring up: close the drawer
                guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
                for app in runningApps { _ = app.unhide() }
                NSWorkspace.shared.openApplication(at: appURL, configuration: .init(), completionHandler: nil)
                onOpen?()
            }
        } else {
            launch()
        }
    }

    private var displayName: String {
        AppDisplayNameResolver.displayName(for: bundleID)
    }

    private static func regularRunningApplications(bundleID: String) -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter {
            $0.activationPolicy == .regular
                && ProcessLiveness.isAlive(pid: $0.processIdentifier)
        }
    }

    /// Every leg is a finite animation. The common-mode timer only schedules the next
    /// leg, so hover/layout transactions cannot turn the bounce into a repeatForever
    /// animation that survives launch completion.
    private func startBounce() {
        guard bounceTimer == nil else { return }
        bounceUp = true

        let timer = Timer(timeInterval: 0.25, repeats: true) { _ in
            bounceUp.toggle()
        }
        timer.tolerance = 0.02
        bounceTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        trace("bounce timer started")
    }

    private func stopBounce() {
        bounceTimer?.invalidate()
        bounceTimer = nil
        bounceUp = false
        trace("bounce timer stopped")
    }

    /// View teardown is local cleanup only. It must not cancel the runtime session;
    /// a newly-created drawer chip resumes from the external `isLaunching` value.
    private func cleanupBounce() {
        bounceTimer?.invalidate()
        bounceTimer = nil
        bounceUp = false
    }

    /// - Parameter firePrimaryAction: pass true for a left click (keeps the original behavior: close the drawer after launching a drawer icon);
    ///   pass false for right-click "Open", which only launches and does not close the drawer. runtime owns URL resolution,
    ///   launch dispatch, readiness, timeout, and duplicate-session rejection.
    private func launch(firePrimaryAction: Bool = true) {
        guard !isLaunching else {
            trace("launch ignored while launching")
            return
        }
        guard onLaunch() else {
            trace("runtime rejected launch")
            return
        }
        trace("runtime accepted launch")
        if firePrimaryAction { onPrimaryAction?() }
    }

    private func trace(_ message: String) {
        guard Self.launchTraceEnabled else { return }
        let timestamp = String(format: "%.3f", ProcessInfo.processInfo.systemUptime)
        print("[launch] BOUNCE bid=\(bundleID) t=\(timestamp) \(message)")
    }
}

// MARK: - App Display Name Resolver

/// Resolves human-readable names for a bundle identifier, with caching (bundle plist
/// reads involve disk IO and these get called from SwiftUI body evaluations).
/// Also answers "does this window title look like the app's main window?" — the
/// Scheme B heuristic: a messaging app's main window is the one titled like the app
/// itself (WeChat / Telegram... in their local-language names), verified to hold for WeChat/QQ/Telegram.
enum AppDisplayNameResolver {
    private static let displayNameCache = AppDisplayNameCache()
    /// App-name matching goes through a monotonic registry and **no longer queries LaunchServices live every frame** (for the cause and cost see the comment on
    /// `AppNameRegistry`: a single transient empty lookup made Feishu/WeChat drop out of the messaging-zone absorption at the same time).
    private static let nameRegistry = AppNameRegistry(
        bundleNamesLoader: bundleDerivedNames(for:),
        runningNameLoader: { bundleID in
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .first?.localizedName
        }
    )
    private static let workspaceObservers: [NSObjectProtocol] = {
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification
        ]
        return names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { notification in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication,
                      let bundleID = app.bundleIdentifier else { return }
                invalidateDisplayName(for: bundleID)
                // The launch notification carries its own `NSRunningApplication`, so the name comes for free: this saves a query
                // and also gives a just-launched app an authoritative name to compare against from its very first frame.
                if name == NSWorkspace.didLaunchApplicationNotification,
                   let localized = app.localizedName {
                    nameRegistry.observe(name: localized, for: bundleID)
                }
            }
        }
    }()

    static func displayName(for bundleID: String) -> String {
        _ = workspaceObservers
        return displayNameCache.value(for: bundleID) {
            if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
               let name = running.localizedName, !name.isEmpty {
                nameRegistry.observe(name: name, for: bundleID)   // recorded into the registry as a freebie
                return name
            }
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
                return nil
            }
            return notRunningDisplayName(at: url)
        }
    }

    /// Display name of a not-yet-launched app. **Must come from the same source as the running `localizedName`**, otherwise the same app would flip names back and forth
    /// across "not launched -> launched -> quit" (v0.9.6 user feedback: on a Chinese system, "System Settings"
    /// showed in English when not launched).
    ///
    /// The order reflects the strength of evidence, measured one by one in a real .app on 2026-08-27 (a CLI measures inaccurately, since a command-line process's
    /// preferred language is en, see `Docs/05-known-platform-quirks.md`):
    /// 1. Spotlight's `kMDItemDisplayName` follows the **system language**, the same source as `localizedName`;
    ///    the `Bundle` chain follows **this process's** preferred language, and diverges if it was changed separately under "Language & Region > Apps".
    /// 2. Only when Spotlight indexing is off does it fall back to the bundle. Both keys must be tried here: system apps like "System Settings" have no
    ///    `zh-Hans.lproj`, the Chinese name exists only in `InfoPlist.loctable`, and the loctable contains only
    ///    `CFBundleName`; the original implementation asked only `CFBundleDisplayName` in the localization dictionary, and on a miss jumped straight to
    ///    the **unlocalized** `CFBundleName`, which was the direct cause of that bug.
    private static func notRunningDisplayName(at url: URL) -> String? {
        if let item = MDItemCreateWithURL(nil, url as CFURL),
           let spotlight = sanitizedDisplayName(MDItemCopyAttribute(item, kMDItemDisplayName) as? String) {
            return spotlight
        }
        let bundle = Bundle(url: url)
        for dict in [bundle?.localizedInfoDictionary, bundle?.infoDictionary] {
            for key in ["CFBundleDisplayName", "CFBundleName"] {
                if let name = sanitizedDisplayName(dict?[key] as? String) { return name }
            }
        }
        return url.deletingPathExtension().lastPathComponent
    }

    /// When Finder's "Show all filename extensions" is on, the sources above carry the `.app` suffix; it should not appear in the bubble.
    private static func sanitizedDisplayName(_ raw: String?) -> String? {
        guard var name = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return nil
        }
        if name.hasSuffix(".app"), name.count > 4 {
            name = String(name.dropLast(4)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return name.isEmpty ? nil : name
    }

    static func invalidateDisplayName(for bundleID: String) {
        displayNameCache.invalidate(bundleID: bundleID)
        nameRegistry.invalidate(bundleID: bundleID)
    }

    static func titleMatchesAppName(_ title: String, bundleID: String) -> Bool {
        _ = workspaceObservers
        return nameRegistry.matches(title: title, bundleID: bundleID)
    }

    /// For diagnostics: which spellings of this app the name table currently recognizes (`MessagingZoneDiagnostics`).
    static func knownAppNames(for bundleID: String) -> Set<String> {
        _ = workspaceObservers
        return nameRegistry.knownNames(for: bundleID)
    }

    /// Localized + unlocalized bundle names (covers e.g. the Chinese vs English names of WeChat). After normalization, handed to the registry cache.
    /// Note, measured on this machine: Feishu/WeChat resolve here only to English names (`{feishu, lark}` / `{wechat}`),
    /// and the Chinese titles can match only through the `localizedName` remembered in the registry.
    private static func bundleDerivedNames(for bundleID: String) -> Set<String> {
        var names: Set<String> = []
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let bundle = Bundle(url: url)
            for dict in [bundle?.localizedInfoDictionary, bundle?.infoDictionary] {
                for key in ["CFBundleDisplayName", "CFBundleName"] {
                    if let name = dict?[key] as? String, !name.isEmpty {
                        names.insert(AppNameRegistry.normalize(name))
                    }
                }
            }
            names.insert(AppNameRegistry.normalize(url.deletingPathExtension().lastPathComponent))
        }
        return names
    }
}

/// Attach `.onHover` only on panels with no external tracking region (the drawer).
///
/// The condition is written as `if`/`else` rather than "always attach and ignore the value if unused": each extra tracking region means one more event dispatch,
/// and this round of changes is **precisely to stop depending on each card's own enter/exit events** (see `StripHoverResolution`).
/// `enabled` never flips at the same call site, so the identity switch of `_ConditionalContent` never actually happens.
private struct SelfTrackedHover: ViewModifier {
    let enabled: Bool
    @Binding var isHovering: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.onHover { isHovering = $0 }
        } else {
            content
        }
    }
}
