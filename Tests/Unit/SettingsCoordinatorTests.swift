import Carbon.HIToolbox
import Combine
import XCTest

@MainActor
final class SettingsCoordinatorTests: XCTestCase {
    func testTaskbarHeightCommitReadsTheNewHeightBeforeTheSetterReturns() {
        let store = makeStore()
        let coordinator = makeCoordinator(store: store)
        var committed: [DockPanelHeight] = []
        coordinator.taskbarHeightUpdateHandler = { committed.append(store.dockPanelHeight) }

        let heights = [63, 32, 120, 54].map { DockPanelHeight(clamping: CGFloat($0)) }
        for (index, height) in heights.enumerated() {
            coordinator.setTaskbarHeight(height)
            XCTAssertEqual(store.dockPanelHeight, height)
            XCTAssertEqual(committed, Array(heights.prefix(index + 1)))
        }
    }

    func testUnchangedTaskbarHeightDoesNotCommitAgain() {
        let store = makeStore()
        let coordinator = makeCoordinator(store: store)
        var commits = 0
        coordinator.taskbarHeightUpdateHandler = { commits += 1 }

        coordinator.setTaskbarHeight(store.dockPanelHeight)
        XCTAssertEqual(commits, 0)
        coordinator.setTaskbarHeight(DockPanelHeight(clamping: 80))
        coordinator.setTaskbarHeight(DockPanelHeight(clamping: 80))
        XCTAssertEqual(commits, 1)
    }

    func testTaskbarHeightStillUpdatesWithoutARunningTaskbar() {
        let store = makeStore()
        let coordinator = makeCoordinator(store: store)
        let height = DockPanelHeight(clamping: 63)

        coordinator.setTaskbarHeight(height)

        XCTAssertEqual(store.dockPanelHeight, height)
    }

    func testLaunchStateStartsFromCacheThenRefreshesFromService() async {
        let store = makeStore(launchAtLogin: true)
        let launch = LaunchServiceStub(state: .off)
        let coordinator = makeCoordinator(store: store, launch: launch)

        XCTAssertEqual(coordinator.launchAtLoginState, .on)
        let firstRefreshAccepted = await coordinator.refreshLaunchAtLoginState()
        XCTAssertTrue(firstRefreshAccepted)
        XCTAssertEqual(coordinator.launchAtLoginState, .off)

        launch.state = .requiresApproval
        let secondRefreshAccepted = await coordinator.refreshLaunchAtLoginState()
        XCTAssertTrue(secondRefreshAccepted)
        XCTAssertEqual(coordinator.launchAtLoginState, .requiresApproval)
    }

    func testLaunchFailureDoesNotChangeStoredMirror() {
        let store = makeStore(launchAtLogin: false)
        let launch = LaunchServiceStub(state: .off)
        launch.setError = TestError.failed
        let coordinator = makeCoordinator(store: store, launch: launch)

        guard case .failure = coordinator.setLaunchAtLogin(true) else {
            return XCTFail("expected failure")
        }
        XCTAssertFalse(store.launchAtLogin)
        XCTAssertEqual(coordinator.launchAtLoginState, .off)
    }

    func testLaunchSuccessUpdatesMirrorAndPublishedState() {
        let store = makeStore(launchAtLogin: false)
        let launch = LaunchServiceStub(state: .off)
        launch.stateAfterSet = .on
        let coordinator = makeCoordinator(store: store, launch: launch)

        guard case .success = coordinator.setLaunchAtLogin(true) else {
            return XCTFail("expected success")
        }
        XCTAssertTrue(store.launchAtLogin)
        XCTAssertEqual(coordinator.launchAtLoginState, .on)
    }

    func testNativeApplyReadsLivePreviousAndPublishesReadback() async {
        let store = makeStore(nativeDelay: AppSettingsStore.neverHideDelay)
        let native = NativeDockServiceStub(states: [
            NativeDockAutohideState(enabled: true, delay: 0.4),
            NativeDockAutohideState(enabled: true, delay: 0.7),
        ])
        let coordinator = makeCoordinator(store: store, native: native)

        let outcome = await coordinator.applyNativeDock(target: 1.0)

        XCTAssertEqual(native.appliedDelays, [1.0])
        XCTAssertEqual(outcome.resolvedDelay, 0.7)
        XCTAssertNil(outcome.error)
        XCTAssertEqual(store.nativeDockAutoHideDelay, 0.7)
    }

    func testNativeApplyFallsBackToMirrorWhenBothReadsFail() async {
        let store = makeStore(nativeDelay: 0.3)
        let native = NativeDockServiceStub(states: [nil, nil])
        let coordinator = makeCoordinator(store: store, native: native)

        let outcome = await coordinator.applyNativeDock(target: 1.0)

        XCTAssertEqual(outcome.resolvedDelay, 1.0)
        XCTAssertEqual(store.nativeDockAutoHideDelay, 1.0)
    }

    func testNativeFailureAndUnreadableReadbackKeepsLivePrevious() async {
        let store = makeStore(nativeDelay: 0.2)
        let native = NativeDockServiceStub(states: [
            NativeDockAutohideState(enabled: true, delay: 0.6),
            nil,
        ])
        native.applyError = TestError.failed
        let coordinator = makeCoordinator(store: store, native: native)

        let outcome = await coordinator.applyNativeDock(target: 1.0)

        XCTAssertNotNil(outcome.error)
        XCTAssertEqual(outcome.resolvedDelay, 0.6)
        XCTAssertEqual(store.nativeDockAutoHideDelay, 0.6)
    }

    func testNativeFailureStillUsesReadablePartialResult() async {
        let store = makeStore(nativeDelay: 0.2)
        let native = NativeDockServiceStub(states: [
            NativeDockAutohideState(enabled: true, delay: 0.6),
            NativeDockAutohideState(enabled: true, delay: 0.8),
        ])
        native.applyError = TestError.failed
        let coordinator = makeCoordinator(store: store, native: native)

        let outcome = await coordinator.applyNativeDock(target: 1.0)

        XCTAssertNotNil(outcome.error)
        XCTAssertEqual(outcome.resolvedDelay, 0.8)
        XCTAssertEqual(store.nativeDockAutoHideDelay, 0.8)
    }

    /// With only the two minimize toggles checked: no system state should be read at all, and the mirror must not change at all.
    /// Reading would mean "what it becomes after writing autohide", but this round never touched autohide.
    func testMinimizeOnlyRecommendationsSkipReadbackAndLeaveMirrorAlone() async {
        let store = makeStore(nativeDelay: 0.3)
        let native = NativeDockServiceStub(states: [
            NativeDockAutohideState(enabled: true, delay: 0.9),
            NativeDockAutohideState(enabled: true, delay: 0.9),
        ])
        let coordinator = makeCoordinator(store: store, native: native)

        let recommendations = WelcomeGuideSelection(
            hidesDock: false,
            usesScaleMinimizeEffect: true,
            minimizesIntoAppIcon: true
        ).recommendations(hideDelay: AppSettingsStore.neverWakeDelay)
        let outcome = await coordinator.applyNativeDock(recommendations: recommendations)

        XCTAssertEqual(native.appliedRecommendations, [recommendations])
        XCTAssertTrue(native.appliedDelays.isEmpty)
        XCTAssertEqual(native.states.count, 2, "一条系统状态都不该被消费")
        XCTAssertNil(outcome.error)
        XCTAssertEqual(outcome.resolvedDelay, 0.3)
        XCTAssertEqual(store.nativeDockAutoHideDelay, 0.3)
    }

    /// All three checked: the two minimize items are written together, and the autohide half still goes through the four-quadrant read-back.
    func testFullRecommendationsWriteEverythingAndStillResolveMirror() async {
        let store = makeStore(nativeDelay: AppSettingsStore.neverHideDelay)
        let native = NativeDockServiceStub(states: [
            NativeDockAutohideState(enabled: false, delay: nil),
            NativeDockAutohideState(enabled: true, delay: 999.0),
        ])
        let coordinator = makeCoordinator(store: store, native: native)

        let recommendations = WelcomeGuideSelection.recommended
            .recommendations(hideDelay: AppSettingsStore.neverWakeDelay)
        let outcome = await coordinator.applyNativeDock(recommendations: recommendations)

        XCTAssertEqual(native.appliedRecommendations, [recommendations])
        XCTAssertEqual(recommendations.autoHideDelay, AppSettingsStore.neverWakeDelay)
        XCTAssertNil(outcome.error)
        XCTAssertEqual(outcome.resolvedDelay, AppSettingsStore.neverWakeDelay)
        XCTAssertEqual(store.nativeDockAutoHideDelay, AppSettingsStore.neverWakeDelay)
    }

    func testSandboxUnavailableDoesNotWriteOrChangeMirror() async {
        let store = makeStore(nativeDelay: 0.5)
        let native = NativeDockServiceStub(isAvailable: false)
        let coordinator = makeCoordinator(store: store, native: native)

        let outcome = await coordinator.applyNativeDock(target: 1.0)

        XCTAssertNotNil(outcome.error)
        XCTAssertEqual(outcome.resolvedDelay, 0.5)
        XCTAssertTrue(native.appliedDelays.isEmpty)
        XCTAssertEqual(store.nativeDockAutoHideDelay, 0.5)
    }

    func testOlderLaunchRefreshCannotOverwriteNewerResult() async {
        let reader = ControlledLaunchStateReader()
        let launch = ControlledLaunchService(reader: reader)
        let coordinator = SettingsCoordinator(
            store: makeStore(),
            launchAtLoginService: launch,
            nativeDockPreferencesService: NativeDockServiceStub(),
            hotKeyRegistrar: { _ in .registered }
        )

        let older = Task { await coordinator.refreshLaunchAtLoginState() }
        await reader.waitForReadCount(1)
        let newer = Task { await coordinator.refreshLaunchAtLoginState() }
        await reader.waitForReadCount(2)

        await reader.resume(id: 1, state: .on)
        let newerAccepted = await newer.value
        XCTAssertTrue(newerAccepted)
        await reader.resume(id: 0, state: .off)
        let olderAccepted = await older.value
        XCTAssertFalse(olderAccepted)
        XCTAssertEqual(coordinator.launchAtLoginState, .on)
    }

    func testPrewarmReadCannotOverwriteNativeDockWrite() async {
        let reader = ControlledNativeDockStateReader()
        let native = ControlledNativeDockService(reader: reader)
        let store = makeStore(nativeDelay: 0.1)
        let coordinator = SettingsCoordinator(
            store: store,
            launchAtLoginService: LaunchServiceStub(state: .off),
            nativeDockPreferencesService: native,
            hotKeyRegistrar: { _ in .registered }
        )

        let prewarm = Task { await coordinator.reconcileNativeDockMirror() }
        await reader.waitForReadCount(1)
        let write = Task { await coordinator.applyNativeDock(target: 0.9) }
        await reader.waitForReadCount(2)

        await reader.resume(id: 0, state: NativeDockAutohideState(enabled: true, delay: 0.2))
        let prewarmAccepted = await prewarm.value
        XCTAssertFalse(prewarmAccepted)
        await reader.resume(id: 1, state: NativeDockAutohideState(enabled: true, delay: 0.3))
        await reader.waitForReadCount(3)
        await reader.resume(id: 2, state: NativeDockAutohideState(enabled: true, delay: 0.9))

        let outcome = await write.value
        XCTAssertEqual(native.appliedDelays, [0.9])
        XCTAssertEqual(outcome.resolvedDelay, 0.9)
        XCTAssertEqual(store.nativeDockAutoHideDelay, 0.9)
    }

    // MARK: Show/hide shortcut

    func testApplyShortcutRejectionNeverReachesRegistrar() {
        let store = makeStore()
        var registrarCalls = 0
        let coordinator = makeCoordinator(store: store, hotKeys: { _ in
            registrarCalls += 1
            return .registered
        })

        let result = coordinator.applyEdgeToggleShortcut(
            StoredHotKeyShortcut(keyCode: 0, carbonModifiers: 0, glyphs: "A")
        )

        guard case .failure(let error) = result else { return XCTFail("无主修饰键的组合必须被拒") }
        XCTAssertEqual(error, .rejected(.missingPrimaryModifier))
        XCTAssertEqual(registrarCalls, 0, "纯校验被拒时不许碰真实注册")
        XCTAssertNil(store.edgeToggleShortcut)
    }

    func testApplyShortcutRegistrationFailureLeavesStoreUnchanged() {
        let store = makeStore()
        let coordinator = makeCoordinator(store: store, hotKeys: { _ in .registrationFailed(-9878) })

        let result = coordinator.applyEdgeToggleShortcut(
            StoredHotKeyShortcut(keyCode: 40, carbonModifiers: UInt32(cmdKey | controlKey), glyphs: "⌃⌘K")
        )

        guard case .failure(let error) = result else { return XCTFail("注册失败必须上报") }
        XCTAssertEqual(error, .registrationFailed)
        XCTAssertNil(store.edgeToggleShortcut, "注册失败不许落盘")
    }

    func testApplyShortcutSuccessPersistsAndResetRemoves() {
        let store = makeStore()
        var registered: [GlobalHotKeyShortcut] = []
        let coordinator = makeCoordinator(store: store, hotKeys: { shortcut in
            registered.append(shortcut)
            return .registered
        })

        let custom = StoredHotKeyShortcut(keyCode: 40, carbonModifiers: UInt32(cmdKey | controlKey), glyphs: "⌃⌘K")
        if case .failure = coordinator.applyEdgeToggleShortcut(custom) { XCTFail("合法组合应当成功") }
        XCTAssertEqual(store.edgeToggleShortcut, custom)
        XCTAssertEqual(registered.last?.keyCode, 40)
        XCTAssertEqual(registered.last?.signature, GlobalHotKeyShortcut.edgeAutoHideMode.signature, "换键不换身份")

        if case .failure = coordinator.applyEdgeToggleShortcut(nil) { XCTFail("恢复默认应当成功") }
        XCTAssertNil(store.edgeToggleShortcut)
        XCTAssertEqual(registered.last, .edgeAutoHideMode)
    }

    private func makeCoordinator(
        store: AppSettingsStore? = nil,
        launch: LaunchServiceStub? = nil,
        native: NativeDockServiceStub? = nil,
        hotKeys: ((GlobalHotKeyShortcut) -> GlobalHotKeyMonitor.RegistrationStatus)? = nil
    ) -> SettingsCoordinator {
        SettingsCoordinator(
            store: store ?? makeStore(),
            launchAtLoginService: launch ?? LaunchServiceStub(state: .off),
            nativeDockPreferencesService: native ?? NativeDockServiceStub(),
            hotKeyRegistrar: hotKeys ?? { _ in .registered }
        )
    }

    private func makeStore(
        launchAtLogin: Bool = false,
        nativeDelay: Double = AppSettingsStore.defaultNativeDockAutoHideDelay
    ) -> AppSettingsStore {
        let suite = "SettingsCoordinatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set(launchAtLogin, forKey: "app.neobar.launchAtLogin")
        defaults.set(nativeDelay, forKey: "app.neobar.autoHide.nativeDock.delay")
        return AppSettingsStore(defaults: defaults)
    }
}

@MainActor
private final class LaunchServiceStub: LaunchAtLoginServicing {
    var state: LaunchAtLoginState
    var stateAfterSet: LaunchAtLoginState?
    var setError: Error?

    init(state: LaunchAtLoginState) {
        self.state = state
    }

    func currentState() async -> LaunchAtLoginState { state }

    func setEnabled(_ enabled: Bool) throws {
        if let setError { throw setError }
        state = stateAfterSet ?? (enabled ? .on : .off)
    }

    func openSystemSettings() {}
}

@MainActor
private final class NativeDockServiceStub: NativeDockPreferencesServicing {
    let isAvailable: Bool
    var states: [NativeDockAutohideState?]
    var applyError: Error?
    var appliedDelays: [Double] = []
    var appliedRecommendations: [NativeDockRecommendations] = []

    init(isAvailable: Bool = true, states: [NativeDockAutohideState?] = []) {
        self.isAvailable = isAvailable
        self.states = states
    }

    func apply(delay: Double) throws {
        appliedDelays.append(delay)
        if let applyError { throw applyError }
    }

    func apply(recommendations: NativeDockRecommendations) throws {
        appliedRecommendations.append(recommendations)
        if let delay = recommendations.autoHideDelay { appliedDelays.append(delay) }
        if let applyError { throw applyError }
    }

    func currentAutohideState() async -> NativeDockAutohideState? {
        states.isEmpty ? nil : states.removeFirst()
    }

    func openSystemSettings() -> Bool { true }
}

private actor ControlledLaunchStateReader {
    private var nextID = 0
    private var continuations: [Int: CheckedContinuation<LaunchAtLoginState, Never>] = [:]

    func read() async -> LaunchAtLoginState {
        let id = nextID
        nextID += 1
        return await withCheckedContinuation { continuations[id] = $0 }
    }

    func waitForReadCount(_ count: Int) async {
        while nextID < count { await Task.yield() }
    }

    func resume(id: Int, state: LaunchAtLoginState) {
        continuations.removeValue(forKey: id)?.resume(returning: state)
    }
}

@MainActor
private final class ControlledLaunchService: LaunchAtLoginServicing {
    private let reader: ControlledLaunchStateReader

    init(reader: ControlledLaunchStateReader) {
        self.reader = reader
    }

    func currentState() async -> LaunchAtLoginState { await reader.read() }
    func setEnabled(_ enabled: Bool) throws {}
    func openSystemSettings() {}
}

private actor ControlledNativeDockStateReader {
    private var nextID = 0
    private var continuations: [Int: CheckedContinuation<NativeDockAutohideState?, Never>] = [:]

    func read() async -> NativeDockAutohideState? {
        let id = nextID
        nextID += 1
        return await withCheckedContinuation { continuations[id] = $0 }
    }

    func waitForReadCount(_ count: Int) async {
        while nextID < count { await Task.yield() }
    }

    func resume(id: Int, state: NativeDockAutohideState?) {
        continuations.removeValue(forKey: id)?.resume(returning: state)
    }
}

@MainActor
private final class ControlledNativeDockService: NativeDockPreferencesServicing {
    let isAvailable = true
    private let reader: ControlledNativeDockStateReader
    private(set) var appliedDelays: [Double] = []
    private(set) var appliedRecommendations: [NativeDockRecommendations] = []

    init(reader: ControlledNativeDockStateReader) {
        self.reader = reader
    }

    func apply(delay: Double) throws { appliedDelays.append(delay) }

    func apply(recommendations: NativeDockRecommendations) throws {
        appliedRecommendations.append(recommendations)
        if let delay = recommendations.autoHideDelay { appliedDelays.append(delay) }
    }
    func currentAutohideState() async -> NativeDockAutohideState? { await reader.read() }
    func openSystemSettings() -> Bool { true }
}

private enum TestError: Error {
    case failed
}
