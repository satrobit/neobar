import Combine
import Foundation

struct NativeDockApplyOutcome {
    let resolvedDelay: Double
    let error: Error?
}

/// Two forms of failure when changing the show/hide shortcut: pure validation rejection (with a reason) / Carbon registration failure (the combination is taken by another app, etc.).
enum HotKeyChangeError: Error, Equatable {
    case rejected(HotKeyShortcutRejection)
    case registrationFailed
}

/// The action layer **shared** by the status-bar menu and the settings window.
///
/// Responsibility is deliberately narrowed to the two things that "write outside this app": the login item and the system Dock.
/// NeoBar's own local toggles (Relay Station / hover / avoidance / taskbar size / wake delay) don't go through here:
/// they are local values that take effect immediately, and if both UIs observe the same `AppSettingsStore` directly they can't drift apart.
@MainActor
final class SettingsCoordinator: ObservableObject {
    /// The result of the latest system read or this app's successful write. System I/O runs on a dedicated service queue,
    /// and the menu and settings window show this cache first, then refresh asynchronously.
    @Published private(set) var launchAtLoginState: LaunchAtLoginState

    private let store: AppSettingsStore
    private let launchAtLoginService: LaunchAtLoginServicing
    private let nativeDockPreferencesService: NativeDockPreferencesServicing
    /// The real registration entry when changing the key (`GlobalHotKeyMonitor.update(shortcut:)` held by AppDelegate).
    /// Closure injection: the monitor is owned by AppDelegate, and a temporary copy (DMG) doesn't have it at all.
    private let hotKeyRegistrar: (GlobalHotKeyShortcut) -> GlobalHotKeyMonitor.RegistrationStatus
    /// Injected by AppDelegate while the taskbar runs; both callbacks capture it weakly.
    var taskbarHeightSessionHandler: ((Bool) -> Void)?
    var taskbarHeightUpdateHandler: (() -> Void)?
    private var launchRefreshGeneration: UInt64 = 0
    private var nativeDockRefreshGeneration: UInt64 = 0
    private var nativeDockWriteInFlight = false

    init(
        store: AppSettingsStore,
        launchAtLoginService: LaunchAtLoginServicing,
        nativeDockPreferencesService: NativeDockPreferencesServicing,
        hotKeyRegistrar: @escaping (GlobalHotKeyShortcut) -> GlobalHotKeyMonitor.RegistrationStatus
    ) {
        self.store = store
        self.launchAtLoginService = launchAtLoginService
        self.nativeDockPreferencesService = nativeDockPreferencesService
        self.hotKeyRegistrar = hotKeyRegistrar
        // **The mirror is only a first-frame seed, not the source of truth.** `SMAppService.mainApp.status` is XPC,
        // and reading it synchronously in init would carry the cost into every UI construction; but every presentation entry (the menu's `menuWillOpen`,
        // the settings window's `present()`, `applicationDidBecomeActive`) refreshes asynchronously right away,
        // so reading the local mirror here only gives the first frame something to show.
        //
        // Spell out the cost: if the user changed the login item in System Settings while this app wasn't running, the first-frame checkmark may be wrong
        // (`.requiresApproval` will also show as `.on` at first), self-healing within one refresh cycle. **Never** treat the mirror
        // as a long-term source of truth because of this: `launchAtLoginState` is written in only two places, `refreshLaunchAtLoginState`
        // and the optimistic update after a successful write.
        launchAtLoginState = store.launchAtLogin ? .on : .off
    }

    // MARK: Taskbar height

    func setTaskbarHeightEditing(_ editing: Bool) {
        taskbarHeightSessionHandler?(editing)
    }

    func setTaskbarHeight(_ height: DockPanelHeight) {
        guard store.dockPanelHeight != height else { return }
        store.setDockPanelHeight(height)
        // Published emits before assignment. Commit after the setter returns so every
        // hosting root and panel reads the new height in this same input event.
        taskbarHeightUpdateHandler?()
    }

    // MARK: Login item

    /// Returning false means the result is stale or the task was cancelled; the caller must not use it to refresh the on-screen UI.
    @discardableResult
    func refreshLaunchAtLoginState() async -> Bool {
        launchRefreshGeneration &+= 1
        let generation = launchRefreshGeneration
        let next = await launchAtLoginService.currentState()
        guard !Task.isCancelled, generation == launchRefreshGeneration else { return false }
        if launchAtLoginState != next { launchAtLoginState = next }
        return true
    }

    /// Update the local mirror only on **successful write**: the mirror exists to hold "the state we believe in",
    /// and when a write fails the system side didn't change, so letting the mirror change would make the next presentation lie.
    func setLaunchAtLogin(_ enabled: Bool) -> Result<Void, Error> {
        launchRefreshGeneration &+= 1
        do {
            try launchAtLoginService.setEnabled(enabled)
            store.setLaunchAtLogin(enabled)
            let optimistic: LaunchAtLoginState = enabled ? .on : .off
            if launchAtLoginState != optimistic { launchAtLoginState = optimistic }
            refreshLaunchAtLoginStateSoon()
            return .success(())
        } catch {
            refreshLaunchAtLoginStateSoon()
            return .failure(error)
        }
    }

    private func refreshLaunchAtLoginStateSoon() {
        Task { @MainActor [weak self] in
            _ = await self?.refreshLaunchAtLoginState()
        }
    }

    func openLoginItemsSettings() {
        launchAtLoginService.openSystemSettings()
    }

    // MARK: Show/hide shortcut

    /// The sole entry for changing the key: pure validation first (`HotKeyShortcutValidation`), then real registration,
    /// and **persist only after registration succeeds**; the other way around would split the stored key from the key actually in effect.
    /// `nil` = restore the default ⌥⇧⌘D. When registration fails, `GlobalHotKeyMonitor.update` has already rolled back to the old key itself,
    /// so no cleanup is needed here, only report the failure to the UI.
    func applyEdgeToggleShortcut(_ stored: StoredHotKeyShortcut?) -> Result<Void, HotKeyChangeError> {
        let target: GlobalHotKeyShortcut
        if let stored {
            if let rejection = HotKeyShortcutValidation.validate(
                keyCode: stored.keyCode,
                carbonModifiers: stored.carbonModifiers
            ) {
                return .failure(.rejected(rejection))
            }
            target = GlobalHotKeyShortcut(stored: stored)
        } else {
            target = .edgeAutoHideMode
        }
        guard hotKeyRegistrar(target) == .registered else {
            return .failure(.registrationFailed)
        }
        store.setEdgeToggleShortcut(stored)
        return .success(())
    }

    // MARK: System Dock

    /// Only change the local mirror to align the UI with the real system value, **never apply in reverse**: showing a settings UI once
    /// shouldn't trigger a `killall Dock`. No competing reads are started during a write; late stale reads are discarded by generation.
    /// Returning false means this result was not accepted; the caller must not use it to refresh the on-screen UI.
    @discardableResult
    func reconcileNativeDockMirror() async -> Bool {
        guard !nativeDockWriteInFlight else { return false }
        nativeDockRefreshGeneration &+= 1
        let generation = nativeDockRefreshGeneration
        let state = await nativeDockPreferencesService.currentAutohideState()
        guard !Task.isCancelled,
              !nativeDockWriteInFlight,
              generation == nativeDockRefreshGeneration else { return false }
        _ = reconcileNativeDockMirror(using: state)
        return true
    }

    @discardableResult
    private func reconcileNativeDockMirror(using state: NativeDockAutohideState?) -> Double {
        guard let state else {
            // When the real system value can't be read (sandbox, etc.), leave the mirror unchanged and the caller continues with the current mirror.
            return store.nativeDockAutoHideDelay
        }
        if let target = AutoHideToggleMenuModel.reconciledStoreDelay(
            systemEnabled: state.enabled,
            systemDelay: state.delay,
            currentStoreDelay: store.nativeDockAutoHideDelay
        ) {
            store.setNativeDockAutoHideDelay(target)
        }
        return store.nativeDockAutoHideDelay
    }

    /// The **sole** write path for the system Dock.
    ///
    /// `previous` isn't passed in by the UI: while the draft sits on screen the user may at any time change the real value with ⌥⌘D or
    /// System Settings, and the starting point the UI holds is long stale. So re-read the real system value once before writing.
    ///
    /// defaults + killall is a multi-step, non-transactional sequence; after writing, always re-read the real system value to decide what the mirror records
    /// (see `AutoHideToggleMenuModel.resolvedStoreDelay` for the four quadrants). It **doesn't show a dialog** here:
    /// dialogs belong to the caller, since the two UIs present them differently (the menu uses NSAlert, the settings window uses an attached alert).
    func applyNativeDock(target: Double) async -> NativeDockApplyOutcome {
        await applyNativeDock(recommendations: NativeDockRecommendations(
            autoHideDelay: target,
            minimizeEffectScale: false,
            minimizeIntoAppIcon: false
        ))
    }

    /// Batch write on the onboarding screen. **The four-quadrant read-back is responsible only for the `autohide` half**: when only the two minimize items are checked,
    /// no system state is read at all and the mirror doesn't change by a word; without touching autohide there is no "what it becomes after writing" to resolve.
    func applyNativeDock(recommendations: NativeDockRecommendations) async -> NativeDockApplyOutcome {
        guard nativeDockPreferencesService.isAvailable else {
            return NativeDockApplyOutcome(
                resolvedDelay: store.nativeDockAutoHideDelay,
                error: NativeDockPreferencesError.sandboxed
            )
        }

        nativeDockWriteInFlight = true
        nativeDockRefreshGeneration &+= 1
        defer { nativeDockWriteInFlight = false }

        var previous: Double?
        if recommendations.autoHideDelay != nil {
            let previousState = await nativeDockPreferencesService.currentAutohideState()
            previous = reconcileNativeDockMirror(using: previousState)
        }

        var writeError: Error?
        do {
            try nativeDockPreferencesService.apply(recommendations: recommendations)
        } catch {
            writeError = error
        }

        guard let target = recommendations.autoHideDelay, let previous else {
            return NativeDockApplyOutcome(resolvedDelay: store.nativeDockAutoHideDelay, error: writeError)
        }

        let readback = await nativeDockPreferencesService.currentAutohideState()
        let resolved = AutoHideToggleMenuModel.resolvedStoreDelay(
            writeSucceeded: writeError == nil,
            systemState: readback,
            target: target,
            previous: previous
        )
        store.setNativeDockAutoHideDelay(resolved)
        return NativeDockApplyOutcome(resolvedDelay: resolved, error: writeError)
    }

    func openNativeDockSettings() -> Bool {
        nativeDockPreferencesService.openSystemSettings()
    }

    // MARK: Version

    /// The version row is used by both the menu and the settings window. After release the main line doesn't bump the version number, so the number alone can't tell a development build from
    /// a user-installed package, hence the source is displayed too (the decision lives in the pure `BuildProvenance`, with unit tests).
    var versionTitle: String? {
        let info = Bundle.main.infoDictionary
        #if DEBUG
        let isDebugBuild = true
        #else
        let isDebugBuild = false
        #endif
        return BuildProvenance.versionTitle(
            version: info?["CFBundleShortVersionString"] as? String,
            build: info?["CFBundleVersion"] as? String,
            isDebugBuild: isDebugBuild,
            bundlePath: Bundle.main.bundleURL.path
        )
    }
}
