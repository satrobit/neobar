import AppKit
import XCTest

@MainActor
final class AppSettingsStoreTests: XCTestCase {
    func testTrashDefaultsIgnoreLegacyKeyAndPersistIndependently() {
        let defaults = makeDefaults()
        defaults.set(false, forKey: "app.neobar.trash.visible")
        let store = AppSettingsStore(defaults: defaults)
        XCTAssertTrue(store.showTrash)
        store.setShowTrash(false)
        XCTAssertTrue(store.showShelf)
        XCTAssertFalse(AppSettingsStore(defaults: defaults).showTrash)
        store.setShowShelf(false)
        store.setShowTrash(true)
        let reloaded = AppSettingsStore(defaults: defaults)
        XCTAssertTrue(reloaded.showTrash)
        XCTAssertFalse(reloaded.showShelf)
    }
    /// Fresh install: NeoBar's own item is **always shown by default** (owner 2026-09-01); the system Dock's mirror seed is still 1.0.
    func testFreshInstallDefaultsToAlwaysVisibleForTheTaskbar() {
        let defaults = makeDefaults()

        let store = AppSettingsStore(defaults: defaults)

        XCTAssertEqual(store.edgeAutoHideDelay, AppSettingsStore.neverHideDelay)
        XCTAssertEqual(AppSettingsStore.sliderIndexFromDelay(store.edgeAutoHideDelay), 0)
        XCTAssertEqual(store.nativeDockAutoHideDelay, 1.0)
        XCTAssertEqual(AppSettingsStore.sliderIndexFromDelay(store.nativeDockAutoHideDelay), 10)
        XCTAssertNil(defaults.object(forKey: "app.neobar.autoHide.nativeDock.enabled"))
        XCTAssertNil(defaults.object(forKey: "app.neobar.autoHide.edge.enabled"))
    }

    /// ⚠️ **The easiest thing to trip on** after the default changed to always-shown: remembered must still be a finite level.
    /// If it became `-1` too, ⌥⇧⌘D would switch from always-shown to always-shown, and the shortcut would become a no-op on the spot.
    func testFreshInstallRemembersAFiniteDelayToToggleBackTo() {
        let defaults = makeDefaults()

        let store = AppSettingsStore(defaults: defaults)

        XCTAssertEqual(store.lastEnabledEdgeAutoHideDelay, AppSettingsStore.defaultEnabledEdgeAutoHideDelay)
        XCTAssertNotEqual(store.lastEnabledEdgeAutoHideDelay, AppSettingsStore.neverHideDelay)

        store.toggleEdgeAutoHideMode()
        XCTAssertEqual(store.edgeAutoHideDelay, AppSettingsStore.defaultEnabledEdgeAutoHideDelay, "常驻 → 自动隐藏")
        store.toggleEdgeAutoHideMode()
        XCTAssertEqual(store.edgeAutoHideDelay, AppSettingsStore.neverHideDelay, "再按一次切回常驻")
    }

    func testLegacyDisabledEnabledKeyMigratesToNeverHideOnlyWhenKeyExists() {
        let defaults = makeDefaults()
        defaults.set(false, forKey: "app.neobar.autoHide.nativeDock.enabled")
        defaults.set(0.0, forKey: "app.neobar.autoHide.nativeDock.delay")

        let store = AppSettingsStore(defaults: defaults)

        XCTAssertEqual(store.nativeDockAutoHideDelay, AppSettingsStore.neverHideDelay)
        XCTAssertEqual(AppSettingsStore.sliderIndexFromDelay(store.nativeDockAutoHideDelay), 0)
        XCTAssertNil(defaults.object(forKey: "app.neobar.autoHide.nativeDock.enabled"))
    }

    func testLegacyEnabledTrueWithZeroDelaySnapsToFiniteMinimum() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: "app.neobar.autoHide.nativeDock.enabled")
        defaults.set(0.0, forKey: "app.neobar.autoHide.nativeDock.delay")

        let store = AppSettingsStore(defaults: defaults)

        XCTAssertEqual(store.nativeDockAutoHideDelay, AppSettingsStore.finiteDelayMin)
        XCTAssertEqual(AppSettingsStore.sliderIndexFromDelay(store.nativeDockAutoHideDelay), 1)
        XCTAssertNil(defaults.object(forKey: "app.neobar.autoHide.nativeDock.enabled"))
    }

    func testLegacyEnabledTrueWithSubMinimumDelaySnapsToFiniteMinimum() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: "app.neobar.autoHide.edge.enabled")
        defaults.set(0.05, forKey: "app.neobar.autoHide.edge.delay")

        let store = AppSettingsStore(defaults: defaults)

        XCTAssertEqual(store.edgeAutoHideDelay, AppSettingsStore.finiteDelayMin)
        XCTAssertEqual(AppSettingsStore.sliderIndexFromDelay(store.edgeAutoHideDelay), 1)
        XCTAssertNil(defaults.object(forKey: "app.neobar.autoHide.edge.enabled"))
    }

    func testSliderDelayMappingKeepsSubMinimumSecondsDistinctFromNeverHide() {
        XCTAssertEqual(AppSettingsStore.delayFromSliderIndex(0), AppSettingsStore.neverHideDelay)
        XCTAssertEqual(AppSettingsStore.delayFromSliderIndex(1), AppSettingsStore.finiteDelayMin)
        XCTAssertEqual(AppSettingsStore.delayFromSliderIndex(30), AppSettingsStore.finiteDelayMax)
        XCTAssertEqual(AppSettingsStore.delayFromSliderIndex(31), AppSettingsStore.neverWakeDelay)

        XCTAssertEqual(AppSettingsStore.sliderIndexFromDelay(-99.0), 0)
        XCTAssertEqual(AppSettingsStore.sliderIndexFromDelay(AppSettingsStore.neverHideDelay), 0)
        XCTAssertEqual(AppSettingsStore.sliderIndexFromDelay(0.0), 1)
        XCTAssertEqual(AppSettingsStore.sliderIndexFromDelay(0.3), 3)
        XCTAssertEqual(AppSettingsStore.sliderIndexFromDelay(1.0), 10)
        XCTAssertEqual(AppSettingsStore.sliderIndexFromDelay(3.0), 30)
        XCTAssertEqual(AppSettingsStore.sliderIndexFromDelay(AppSettingsStore.neverWakeDelay), 31)
    }

    func testSnapDelayClampsOnlySentinelBoundsToSpecialStates() {
        XCTAssertEqual(AppSettingsStore.snapDelay(-99.0), AppSettingsStore.neverHideDelay)
        XCTAssertEqual(AppSettingsStore.snapDelay(-0.2), AppSettingsStore.finiteDelayMin)
        XCTAssertEqual(AppSettingsStore.snapDelay(0.0), AppSettingsStore.finiteDelayMin)
        XCTAssertEqual(AppSettingsStore.snapDelay(0.05), AppSettingsStore.finiteDelayMin)
        XCTAssertEqual(AppSettingsStore.snapDelay(0.3), 0.3)
        XCTAssertEqual(AppSettingsStore.snapDelay(3.3), AppSettingsStore.finiteDelayMax)
        XCTAssertEqual(AppSettingsStore.snapDelay(999.0), AppSettingsStore.neverWakeDelay)
        XCTAssertEqual(AppSettingsStore.snapDelay(1.34), 1.3)
    }

    @MainActor
    func testFrontWindowBarDefaultsToOffAndPersists() {
        let defaults = makeDefaults()
        let store = AppSettingsStore(defaults: defaults)
        XCTAssertFalse(store.frontWindowBar)
        store.setFrontWindowBar(true)
        XCTAssertTrue(AppSettingsStore(defaults: defaults).frontWindowBar)
    }

    func testShowShelfDefaultsToOnAndPersists() {
        let defaults = makeDefaults()
        XCTAssertTrue(AppSettingsStore(defaults: defaults).showShelf, "默认显示中转格，升级不改变现有观感")

        let store = AppSettingsStore(defaults: defaults)
        store.setShowShelf(false)
        XCTAssertFalse(store.showShelf)
        XCTAssertFalse(AppSettingsStore(defaults: defaults).showShelf, "关掉后要跨重启保持")

        store.setShowShelf(true)
        XCTAssertTrue(AppSettingsStore(defaults: defaults).showShelf)
    }

    @MainActor
    func testDockPanelHeightDefaultsToNativeAndPersists() {
        let defaults = makeDefaults()
        XCTAssertEqual(AppSettingsStore(defaults: defaults).dockPanelHeight, .native)
        XCTAssertEqual(defaults.double(forKey: "app.neobar.dockPanelHeight"), 54, "清洗后的值启动即写回")

        let store = AppSettingsStore(defaults: defaults)
        store.setDockPanelHeight(DockPanelHeight(clamping: 70))
        XCTAssertEqual(AppSettingsStore(defaults: defaults).dockPanelHeight.points, 70, "条高要跨重启保持")
        XCTAssertEqual(defaults.object(forKey: "app.neobar.dockPanelHeight") as? Double, 70)
    }

    @MainActor
    func testDockPanelHeightRewritesCorruptStoredValueToNative() {
        let defaults = makeDefaults()
        defaults.set("huge", forKey: "app.neobar.dockPanelHeight")
        XCTAssertEqual(AppSettingsStore(defaults: defaults).dockPanelHeight, .native)
        // Must **rewrite immediately**, otherwise the fallback is re-run on every launch.
        XCTAssertEqual(defaults.double(forKey: "app.neobar.dockPanelHeight"), 54)

        defaults.set(Double.nan, forKey: "app.neobar.dockPanelHeight")
        XCTAssertEqual(AppSettingsStore(defaults: defaults).dockPanelHeight, .native, "NaN 也要回退")

        defaults.set(999, forKey: "app.neobar.dockPanelHeight")
        XCTAssertEqual(AppSettingsStore(defaults: defaults).dockPanelHeight.points, DockPanelHeight.maximum, "越界夹到范围")
        XCTAssertEqual(defaults.double(forKey: "app.neobar.dockPanelHeight"), DockPanelHeight.maximum)
    }

    @MainActor
    func testLegacyDockSizeMigratesOnceAndIsNeverDeleted() {
        let defaults = makeDefaults()
        defaults.set("extraLarge", forKey: "app.neobar.dockSize")
        XCTAssertEqual(AppSettingsStore(defaults: defaults).dockPanelHeight.points, 70)
        XCTAssertEqual(defaults.double(forKey: "app.neobar.dockPanelHeight"), 70, "迁移结果写进新键")
        XCTAssertEqual(defaults.string(forKey: "app.neobar.dockSize"), "extraLarge", "旧键只读不删，回滚还读得回")
    }

    @MainActor
    func testNewHeightKeyWinsOverLegacyTier() {
        let defaults = makeDefaults()
        defaults.set("small", forKey: "app.neobar.dockSize")
        defaults.set(63, forKey: "app.neobar.dockPanelHeight")
        XCTAssertEqual(AppSettingsStore(defaults: defaults).dockPanelHeight.points, 63)
    }

    @MainActor
    func testUnknownLegacyTierFallsBackToNative() {
        let defaults = makeDefaults()
        defaults.set("gigantic", forKey: "app.neobar.dockSize")
        XCTAssertEqual(AppSettingsStore(defaults: defaults).dockPanelHeight, .native)
        XCTAssertEqual(defaults.string(forKey: "app.neobar.dockSize"), "gigantic", "旧键不动")
    }

    @MainActor
    func testHoverStyleDefaultsToQuietAndPersists() {
        let defaults = makeDefaults()
        XCTAssertEqual(AppSettingsStore(defaults: defaults).hoverStyle, .quiet, "全新安装不弹应用名气泡（owner 2026-09-01）")

        let store = AppSettingsStore(defaults: defaults)
        store.setHoverStyle(.standard)
        XCTAssertEqual(store.hoverStyle, .standard)
        XCTAssertEqual(AppSettingsStore(defaults: defaults).hoverStyle, .standard, "档位要跨重启保持")

        store.setHoverStyle(.quiet)
        XCTAssertEqual(AppSettingsStore(defaults: defaults).hoverStyle, .quiet)
    }

    @MainActor
    func testWindowLiftEnabledStaysOffForUpgradersAndPersists() {
        let defaults = makeDefaults()
        // Missing key means off was **a deliberate decision**, not a forgotten registration: maximize avoidance really rewrites other apps' window sizes,
        // so an upgrade must not turn it on for existing users. On a fresh install the seed method explicitly writes it on (see the next test),
        // so don't casually "fix" it into register: true, which would turn it on for all existing users at once.
        XCTAssertFalse(AppSettingsStore(defaults: defaults).windowLiftEnabled, "升级上来的老用户维持关")

        let store = AppSettingsStore(defaults: defaults)
        store.setWindowLiftEnabled(true)
        XCTAssertTrue(store.windowLiftEnabled)
        XCTAssertTrue(AppSettingsStore(defaults: defaults).windowLiftEnabled, "开启后要跨重启保持")

        store.setWindowLiftEnabled(false)
        XCTAssertFalse(AppSettingsStore(defaults: defaults).windowLiftEnabled)
    }

    /// A fresh install seeds it on (owner 2026-09-01), and **seeds only when the key has never been written**.
    func testWindowLiftSeedOnlyAppliesWhenTheUserNeverTouchedIt() {
        let fresh = makeDefaults()
        let store = AppSettingsStore(defaults: fresh)
        store.seedWindowLiftEnabledForFreshInstall(lineage: .pristine)
        XCTAssertTrue(store.windowLiftEnabled, "全新安装播种为开")
        XCTAssertTrue(AppSettingsStore(defaults: fresh).windowLiftEnabled, "要落盘")

        // The user turned it off themselves: even if seed is called again, it must not overwrite their choice.
        let chosen = makeDefaults()
        let existing = AppSettingsStore(defaults: chosen)
        existing.setWindowLiftEnabled(true)
        existing.setWindowLiftEnabled(false)
        existing.seedWindowLiftEnabledForFreshInstall(lineage: .pristine)
        XCTAssertFalse(existing.windowLiftEnabled, "键已存在 = 用户拨过，尊重")

        // Idempotent: calling again after seeding changes nothing.
        store.setWindowLiftEnabled(false)
        store.seedWindowLiftEnabledForFreshInstall(lineage: .pristine)
        XCTAssertFalse(store.windowLiftEnabled)
    }

    @MainActor
    func testFullscreenIntentDefaultsToOnAndPersists() {
        let defaults = makeDefaults()
        XCTAssertTrue(AppSettingsStore(defaults: defaults).fullscreenIntentEnabled)

        let store = AppSettingsStore(defaults: defaults)
        store.setFullscreenIntentEnabled(false)
        XCTAssertFalse(store.fullscreenIntentEnabled)
        XCTAssertFalse(AppSettingsStore(defaults: defaults).fullscreenIntentEnabled)

        store.setFullscreenIntentEnabled(true)
        XCTAssertTrue(AppSettingsStore(defaults: defaults).fullscreenIntentEnabled)
    }

    @MainActor
    func testHoverStyleRewritesCorruptStoredValueToTheDefault() {
        let defaults = makeDefaults()
        defaults.set("silent", forKey: "app.neobar.hoverStyle")
        XCTAssertEqual(AppSettingsStore(defaults: defaults).hoverStyle, HoverStyle.default)
        // Same as dockSize: must **rewrite immediately**, otherwise the fallback is re-run on every launch, and the stored value and the menu checkmark never line up.
        XCTAssertEqual(defaults.string(forKey: "app.neobar.hoverStyle"), HoverStyle.default.rawValue)

        defaults.set(7, forKey: "app.neobar.hoverStyle")
        XCTAssertEqual(AppSettingsStore(defaults: defaults).hoverStyle, HoverStyle.default, "类型不对也要回退")
    }

    @MainActor
    func testHoverStyleDoesNotDisturbOtherSettings() {
        let defaults = makeDefaults()
        let store = AppSettingsStore(defaults: defaults)
        store.setDockPanelHeight(DockPanelHeight(clamping: 62))
        store.setShowShelf(false)

        store.setHoverStyle(.quiet)

        let reloaded = AppSettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.hoverStyle, .quiet)
        XCTAssertEqual(reloaded.dockPanelHeight.points, 62, "悬停档位与条高是两把独立的钥匙")
        XCTAssertFalse(reloaded.showShelf)
    }

    func testHoverStyleRawValuesAreStableAcrossReleases() {
        // Same as dockSize back then: the raw value went into UserDefaults, so renaming would quietly reset all existing users back to the standard level.
        XCTAssertEqual(HoverStyle.allCases.map(\.rawValue), ["standard", "quiet"])
        // A fresh install defaults to not showing the app-name bubble (owner 2026-09-01; previously .standard).
        XCTAssertEqual(HoverStyle.default, .quiet)
        // isExpressive is the sole criterion for all chip views and also for the menu checkmark state; if it's backwards, a whole level stops working.
        XCTAssertTrue(HoverStyle.standard.isExpressive)
        XCTAssertFalse(HoverStyle.quiet.isExpressive)
    }

    /// Hover feedback of the quiet level: **the standard level must always be false**.
    ///
    /// Decided by the owner 2026-08-17: the standard level's feedback is the name bubble, with not a single pixel of change in look and feel;
    /// this only fills in the level that turns the name off (before this it had no feedback at all on hover).
    func testQuietHoverFeedbackOnlyExistsInTheQuietTier() {
        for hovering in [true, false] {
            XCTAssertFalse(
                HoverStyle.standard.showsQuietHoverFeedback(isHovering: hovering),
                "标准档任何输入都不该有反馈（hover=\(hovering)）"
            )
        }
        XCTAssertTrue(HoverStyle.quiet.showsQuietHoverFeedback(isHovering: true))
        XCTAssertFalse(HoverStyle.quiet.showsQuietHoverFeedback(isHovering: false))
    }

    func testLegacyDockSizeRawValuesStayReadable() {
        // The four raw strings are the frozen contract of UserDefaults from the four-level era: the migration table must always recognize them.
        XCTAssertEqual(["small", "medium", "large", "extraLarge"].compactMap { DockPanelHeight.migratingLegacyTier(rawValue: $0)?.points },
                       [46, 54, 62, 70])
    }

    @MainActor
    func testNativeDockSliderCommandsCoverResidentFiniteAndNeverWake() {
        // The always-shown level only turns off autohide and doesn't write the delay: the delay is meaningless then, and writing it would overwrite the user's original value.
        let resident = NativeDockPreferencesService.commands(for: AppSettingsStore.neverHideDelay)
        XCTAssertEqual(resident.count, 2)
        XCTAssertEqual(resident[0].executable, "/usr/bin/defaults")
        XCTAssertEqual(resident[0].arguments, ["write", "com.apple.dock", "autohide", "-bool", "false"])
        XCTAssertEqual(resident[1].arguments, ["Dock"])

        let finite = NativeDockPreferencesService.commands(for: 0.5)
        XCTAssertEqual(finite.count, 3)
        XCTAssertEqual(finite[0].arguments, ["write", "com.apple.dock", "autohide", "-bool", "true"])
        XCTAssertEqual(finite[1].arguments, ["write", "com.apple.dock", "autohide-delay", "-float", "0.5"])
        XCTAssertEqual(finite[2].arguments, ["Dock"])

        let neverWake = NativeDockPreferencesService.commands(for: AppSettingsStore.neverWakeDelay)
        XCTAssertEqual(neverWake[1].arguments, ["write", "com.apple.dock", "autohide-delay", "-float", "999.0"])
    }

    /// Batch write on the onboarding screen: **only one `killall Dock` at the end**. If every item restarted separately,
    /// the user would see the screen flash three times in a row.
    @MainActor
    func testWelcomeRecommendationCommandsRestartDockExactlyOnce() {
        let all = NativeDockPreferencesService.commands(for: NativeDockRecommendations(
            autoHideDelay: AppSettingsStore.neverWakeDelay,
            minimizeEffectScale: true,
            minimizeIntoAppIcon: true
        ))
        XCTAssertEqual(all.count, 5)
        XCTAssertEqual(all[0].arguments, ["write", "com.apple.dock", "autohide", "-bool", "true"])
        XCTAssertEqual(all[1].arguments, ["write", "com.apple.dock", "autohide-delay", "-float", "999.0"])
        XCTAssertEqual(all[2].arguments, ["write", "com.apple.dock", "mineffect", "-string", "scale"])
        XCTAssertEqual(all[3].arguments, ["write", "com.apple.dock", "minimize-to-application", "-bool", "true"])
        XCTAssertEqual(all[4].executable, "/usr/bin/killall")
        XCTAssertEqual(all.filter { $0.executable == "/usr/bin/killall" }.count, 1)
    }

    /// When "Hide system Dock" isn't checked, not a single autohide key may be written: not touching it is not the same as writing the default value.
    @MainActor
    func testMinimizeOnlyRecommendationCommandsSkipAutohideKeys() {
        let minimizeOnly = NativeDockPreferencesService.commands(for: NativeDockRecommendations(
            autoHideDelay: nil,
            minimizeEffectScale: true,
            minimizeIntoAppIcon: true
        ))
        XCTAssertEqual(minimizeOnly.count, 3)
        XCTAssertFalse(minimizeOnly.contains { $0.arguments.contains("autohide") })
        XCTAssertFalse(minimizeOnly.contains { $0.arguments.contains("autohide-delay") })
        XCTAssertEqual(minimizeOnly.last?.executable, "/usr/bin/killall")
    }

    /// None checked: no write, no restart, no flash.
    @MainActor
    func testEmptyRecommendationCommandsAreNoOp() {
        XCTAssertTrue(NativeDockPreferencesService.commands(for: NativeDockRecommendations(
            autoHideDelay: nil,
            minimizeEffectScale: false,
            minimizeIntoAppIcon: false
        )).isEmpty)
    }

    @MainActor
    func testNativeDockPreferenceServiceDoesNotRunWhenSandboxed() {
        var didRun = false
        let service = NativeDockPreferencesService(sandbox: SandboxEnvironment(isSandboxed: true)) { _, _ in
            didRun = true
        }

        XCTAssertFalse(service.isAvailable)
        XCTAssertThrowsError(try service.apply(delay: 0.5))
        XCTAssertFalse(didRun)
    }

    @MainActor
    func testNativeDockSliderApplyStopsAtFirstFailedCommand() {
        var ranCommands: [(String, [String])] = []
        let service = NativeDockPreferencesService(
            sandbox: SandboxEnvironment(isSandboxed: false),
            runner: { executable, arguments in
                ranCommands.append((executable, arguments))
                if arguments.contains("autohide-delay") {
                    throw NativeDockPreferencesError.commandFailed(executable: executable, status: 1)
                }
            },
            autohideReader: { nil }
        )

        XCTAssertThrowsError(try service.apply(delay: 0.5))
        XCTAssertEqual(ranCommands.count, 2, "第二条失败后不得继续 killall Dock")
    }

    func testNativeDockStateReadStopsBeforeValueAccessWhenSynchronizeFails() {
        var requestedKeys: [String] = []

        let state = NativeDockPreferencesService.readAutohideState(
            synchronize: { false },
            valueForKey: { key in
                requestedKeys.append(key)
                return nil
            }
        )

        XCTAssertNil(state)
        XCTAssertTrue(requestedKeys.isEmpty)
    }

    func testNativeDockStateDecoderDistinguishesMissingKeysFromCorruptValues() {
        XCTAssertEqual(
            NativeDockPreferencesService.decodeAutohideState(autohideValue: nil, delayValue: nil),
            NativeDockAutohideState(enabled: false, delay: nil)
        )
        XCTAssertEqual(
            NativeDockPreferencesService.decodeAutohideState(autohideValue: true, delayValue: 0.2),
            NativeDockAutohideState(enabled: true, delay: 0.2)
        )
        XCTAssertEqual(
            NativeDockPreferencesService.decodeAutohideState(autohideValue: nil, delayValue: 0.2),
            NativeDockAutohideState(enabled: false, delay: 0.2)
        )
        XCTAssertEqual(
            NativeDockPreferencesService.decodeAutohideState(autohideValue: false, delayValue: "bad"),
            NativeDockAutohideState(enabled: false, delay: nil),
            "系统明确关闭时，坏 delay 不得掩盖可信的 autohide 真值"
        )

        XCTAssertNil(NativeDockPreferencesService.decodeAutohideState(autohideValue: "true", delayValue: 0.2))
        XCTAssertNil(NativeDockPreferencesService.decodeAutohideState(autohideValue: NSNumber(value: 1), delayValue: 0.2))
        XCTAssertNil(NativeDockPreferencesService.decodeAutohideState(autohideValue: true, delayValue: "0.2"))
        XCTAssertNil(NativeDockPreferencesService.decodeAutohideState(autohideValue: true, delayValue: false))
        XCTAssertNil(NativeDockPreferencesService.decodeAutohideState(
            autohideValue: true,
            delayValue: NSNumber(value: Double.nan)
        ))
        XCTAssertNil(NativeDockPreferencesService.decodeAutohideState(
            autohideValue: true,
            delayValue: NSNumber(value: Double.infinity)
        ))
    }

    func testLaunchAtLoginMenuPresentationCoversFourStates() {
        XCTAssertEqual(
            LaunchAtLoginMenuPresentation(state: .unsupported),
            LaunchAtLoginMenuPresentation(title: String(localized: "Open at Login (Unavailable)"), isEnabled: false, isChecked: false, showsSettingsItem: false)
        )
        XCTAssertEqual(
            LaunchAtLoginMenuPresentation(state: .off),
            LaunchAtLoginMenuPresentation(title: String(localized: "Open at Login"), isEnabled: true, isChecked: false, showsSettingsItem: false)
        )
        XCTAssertEqual(
            LaunchAtLoginMenuPresentation(state: .on),
            LaunchAtLoginMenuPresentation(title: String(localized: "Open at Login"), isEnabled: true, isChecked: true, showsSettingsItem: false)
        )
        XCTAssertEqual(
            LaunchAtLoginMenuPresentation(state: .requiresApproval),
            LaunchAtLoginMenuPresentation(title: String(localized: "Open at Login (Pending Approval)"), isEnabled: true, isChecked: false, showsSettingsItem: true)
        )
    }

    func testLaunchAtLoginMenuToggleDecisionCoversFourStates() {
        XCTAssertNil(LaunchAtLoginMenuModel.requestedEnabledValue(afterSelecting: .unsupported))
        XCTAssertEqual(LaunchAtLoginMenuModel.requestedEnabledValue(afterSelecting: .off), true)
        XCTAssertEqual(LaunchAtLoginMenuModel.requestedEnabledValue(afterSelecting: .on), false)
        XCTAssertEqual(LaunchAtLoginMenuModel.requestedEnabledValue(afterSelecting: .requiresApproval), true)
    }

    func testLaunchAtLoginColdStartPresentationUsesRealStatusOverStoredIntent() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: "app.neobar.launchAtLogin")
        let store = AppSettingsStore(defaults: defaults)

        let presentation = LaunchAtLoginMenuPresentation(state: .off)

        XCTAssertTrue(store.launchAtLogin)
        XCTAssertFalse(presentation.isChecked)
    }

    func testPanelVisibilityKeepsHiddenUntilAllReasonsAreCleared() {
        var state = PanelVisibilityState()

        state.setFullscreen(true)
        state.setEdgeAutoHidden(true)
        XCTAssertFalse(state.isVisible)

        state.setFullscreen(false)
        XCTAssertFalse(state.isVisible)

        state.setEdgeAutoHidden(false)
        XCTAssertTrue(state.isVisible)
    }

    func testPanelVisibilityInhibitorClearsEdgeAutoHideEvenAfterFullscreenExit() {
        var state = PanelVisibilityState()

        state.setEdgeAutoHidden(true)
        state.setFullscreen(true)
        state.setInhibitor(.dragging, active: true)
        state.setFullscreen(false)
        state.reconcileEdgeAutoHide(isEnabled: true)

        XCTAssertFalse(state.hideReasons.contains(.edgeAutoHide))
        XCTAssertTrue(state.isVisible)
    }

    func testPanelVisibilityConstantModeClearsEdgeAutoHide() {
        var state = PanelVisibilityState()

        state.setEdgeAutoHidden(true)
        state.reconcileEdgeAutoHide(isEnabled: false)

        XCTAssertTrue(state.isVisible)
    }

    /// While the NeoBar menu (the same one opened from the status-bar icon or the taskbar right-click) is open, edge auto-hide must pause:
    /// otherwise the idle timer keeps running and the taskbar shrinks away from under the popped-up menu.
    func testTaskbarMenuOpenInhibitsIdleHideAndReleasesOnClose() {
        var state = PanelVisibilityState()
        XCTAssertTrue(EdgeAutoHideRuntimeRules.canArmIdleHide(state: state, delay: 0.9))

        state.setInhibitor(.taskbarMenuOpen, active: true)
        XCTAssertFalse(EdgeAutoHideRuntimeRules.canArmIdleHide(state: state, delay: 0.9))

        state.setInhibitor(.taskbarMenuOpen, active: false)
        XCTAssertTrue(EdgeAutoHideRuntimeRules.canArmIdleHide(state: state, delay: 0.9))
    }

    /// The menu was popped up with the taskbar already shrunk (the user opened it from the status-bar icon):
    /// the suppressor must pull it back, and not leave the menu dangling alone where there is no taskbar.
    func testTaskbarMenuOpenClearsAnAlreadyHiddenEdgeAutoHide() {
        var state = PanelVisibilityState()
        state.setEdgeAutoHidden(true)
        XCTAssertFalse(state.isVisible)

        state.setInhibitor(.taskbarMenuOpen, active: true)
        state.reconcileEdgeAutoHide(isEnabled: true)

        XCTAssertTrue(state.isVisible)
    }

    func testEdgeAutoHideWakeRulesRequireHiddenFiniteDelayAndNoInhibitors() {
        var state = PanelVisibilityState()

        XCTAssertFalse(EdgeAutoHideRuntimeRules.canArmWake(state: state, delay: 0.9))

        state.setEdgeAutoHidden(true)
        XCTAssertTrue(EdgeAutoHideRuntimeRules.canArmWake(state: state, delay: 0.9))
        XCTAssertFalse(EdgeAutoHideRuntimeRules.canArmWake(state: state, delay: AppSettingsStore.neverWakeDelay))
        XCTAssertFalse(EdgeAutoHideRuntimeRules.canArmWake(state: state, delay: AppSettingsStore.neverHideDelay))

        state.setInhibitor(.drawerOpen, active: true)
        XCTAssertFalse(EdgeAutoHideRuntimeRules.canArmWake(state: state, delay: 0.9))
    }

    func testEdgeAutoHideIdleRulesRequireVisibleAndNoInhibitors() {
        var state = PanelVisibilityState()

        XCTAssertTrue(EdgeAutoHideRuntimeRules.canArmIdleHide(state: state, delay: 0.9))
        XCTAssertEqual(EdgeAutoHideRuntimeRules.idleHideInterval(for: 0.9), EdgeAutoHideRuntimeRules.fixedIdleHideDelay)
        XCTAssertEqual(EdgeAutoHideRuntimeRules.idleHideInterval(for: AppSettingsStore.neverWakeDelay), EdgeAutoHideRuntimeRules.fixedIdleHideDelay)
        XCTAssertNil(EdgeAutoHideRuntimeRules.idleHideInterval(for: AppSettingsStore.neverHideDelay))

        state.setEdgeAutoHidden(true)
        XCTAssertFalse(EdgeAutoHideRuntimeRules.canArmIdleHide(state: state, delay: 0.9))

        state.setEdgeAutoHidden(false)
        state.setInhibitor(.dragging, active: true)
        XCTAssertFalse(EdgeAutoHideRuntimeRules.canArmIdleHide(state: state, delay: 0.9))
    }

    func testBottomHotZoneSuppressesIdleHideOnlyForFiniteWakeDelays() {
        XCTAssertTrue(EdgeAutoHideRuntimeRules.bottomHotZoneSuppressesIdleHide(delay: 0.1))
        XCTAssertTrue(EdgeAutoHideRuntimeRules.bottomHotZoneSuppressesIdleHide(delay: 0.9))
        XCTAssertTrue(EdgeAutoHideRuntimeRules.bottomHotZoneSuppressesIdleHide(delay: 3.0))

        // 999: auto-hide but no wake. With no wake action there is no risk of "fighting", and the bottom-edge hot zone shouldn't additionally suppress hiding.
        XCTAssertFalse(EdgeAutoHideRuntimeRules.bottomHotZoneSuppressesIdleHide(delay: AppSettingsStore.neverWakeDelay))

        // -1: always shown. It never hides anyway, so suppressing or not makes no difference; the rule should still return false (this doesn't mean it takes effect).
        XCTAssertFalse(EdgeAutoHideRuntimeRules.bottomHotZoneSuppressesIdleHide(delay: AppSettingsStore.neverHideDelay))
    }

    // MARK: - Always-shown toggle (toggleEdgeAutoHideMode) and remembered seeding

    func testToggleFromFiniteDelayEntersResidentAndRestoresSameDelay() {
        let defaults = makeDefaults()
        defaults.set(0.5, forKey: "app.neobar.autoHide.edge.delay")
        let store = AppSettingsStore(defaults: defaults)

        store.toggleEdgeAutoHideMode()
        XCTAssertEqual(store.edgeAutoHideDelay, AppSettingsStore.neverHideDelay)
        XCTAssertEqual(store.lastEnabledEdgeAutoHideDelay, 0.5)

        store.toggleEdgeAutoHideMode()
        XCTAssertEqual(store.edgeAutoHideDelay, 0.5)
    }

    func testToggleFromNeverWakeRoundTripsBackToNeverWake() {
        let defaults = makeDefaults()
        let store = AppSettingsStore(defaults: defaults)
        store.setEdgeAutoHideDelay(AppSettingsStore.neverWakeDelay)

        store.toggleEdgeAutoHideMode()
        XCTAssertEqual(store.edgeAutoHideDelay, AppSettingsStore.neverHideDelay)

        store.toggleEdgeAutoHideMode()
        XCTAssertEqual(store.edgeAutoHideDelay, AppSettingsStore.neverWakeDelay)
    }

    func testToggleFromResidentWithoutHistoryFallsBackToDefaultDelay() {
        let defaults = makeDefaults()
        defaults.set(AppSettingsStore.neverHideDelay, forKey: "app.neobar.autoHide.edge.delay")
        let store = AppSettingsStore(defaults: defaults)

        XCTAssertEqual(store.lastEnabledEdgeAutoHideDelay, AppSettingsStore.defaultEnabledEdgeAutoHideDelay)

        store.toggleEdgeAutoHideMode()
        XCTAssertEqual(store.edgeAutoHideDelay, AppSettingsStore.defaultEnabledEdgeAutoHideDelay)
    }

    func testRememberedSeedsFromCurrentFiniteValueOverStaleStoredValue() {
        let defaults = makeDefaults()
        defaults.set(0.5, forKey: "app.neobar.autoHide.edge.delay")
        defaults.set(2.0, forKey: "app.neobar.autoHide.edge.lastEnabledDelay")

        let store = AppSettingsStore(defaults: defaults)

        XCTAssertEqual(store.lastEnabledEdgeAutoHideDelay, 0.5)
        XCTAssertEqual(defaults.double(forKey: "app.neobar.autoHide.edge.lastEnabledDelay"), 0.5)
    }

    func testRememberedIsReadOnlyWhenCurrentIsResident() {
        let defaults = makeDefaults()
        defaults.set(AppSettingsStore.neverHideDelay, forKey: "app.neobar.autoHide.edge.delay")
        defaults.set(2.0, forKey: "app.neobar.autoHide.edge.lastEnabledDelay")

        let store = AppSettingsStore(defaults: defaults)

        XCTAssertEqual(store.lastEnabledEdgeAutoHideDelay, 2.0)
    }

    func testCorruptRememberedValuesFallBackToDefault() {
        let corruptValues: [Any] = ["字符串", Double.nan, AppSettingsStore.neverHideDelay, -50.0]
        for corrupt in corruptValues {
            let defaults = makeDefaults()
            defaults.set(AppSettingsStore.neverHideDelay, forKey: "app.neobar.autoHide.edge.delay")
            defaults.set(corrupt, forKey: "app.neobar.autoHide.edge.lastEnabledDelay")

            let store = AppSettingsStore(defaults: defaults)

            XCTAssertEqual(store.lastEnabledEdgeAutoHideDelay, AppSettingsStore.defaultEnabledEdgeAutoHideDelay, "corrupt=\(corrupt)")
        }
    }

    func testLegacyDisabledMigrationThenToggleRestoresDefaultDelay() {
        let defaults = makeDefaults()
        defaults.set(false, forKey: "app.neobar.autoHide.edge.enabled")
        defaults.set(0.7, forKey: "app.neobar.autoHide.edge.delay")

        let store = AppSettingsStore(defaults: defaults)
        XCTAssertEqual(store.edgeAutoHideDelay, AppSettingsStore.neverHideDelay)
        XCTAssertEqual(store.lastEnabledEdgeAutoHideDelay, AppSettingsStore.defaultEnabledEdgeAutoHideDelay)

        store.toggleEdgeAutoHideMode()
        XCTAssertEqual(store.edgeAutoHideDelay, AppSettingsStore.defaultEnabledEdgeAutoHideDelay)
    }

    func testCrossStoreRebuildKeepsRememberedDelay() {
        let defaults = makeDefaults()
        let first = AppSettingsStore(defaults: defaults)
        first.setEdgeAutoHideDelay(2.0)
        first.toggleEdgeAutoHideMode()
        XCTAssertEqual(first.edgeAutoHideDelay, AppSettingsStore.neverHideDelay)

        let second = AppSettingsStore(defaults: defaults)
        XCTAssertEqual(second.edgeAutoHideDelay, AppSettingsStore.neverHideDelay)
        XCTAssertEqual(second.lastEnabledEdgeAutoHideDelay, 2.0)

        second.toggleEdgeAutoHideMode()
        XCTAssertEqual(second.edgeAutoHideDelay, 2.0)
    }

    func testNonFiniteSetterInputsAreIgnored() {
        let defaults = makeDefaults()
        let store = AppSettingsStore(defaults: defaults)
        store.setEdgeAutoHideDelay(0.5)

        store.setEdgeAutoHideDelay(.nan)
        store.setEdgeAutoHideDelay(.infinity)
        store.setEdgeAutoHideDelay(-.infinity)
        store.setNativeDockAutoHideDelay(.nan)

        XCTAssertEqual(store.edgeAutoHideDelay, 0.5)
        XCTAssertEqual(store.lastEnabledEdgeAutoHideDelay, 0.5)
        XCTAssertEqual(store.nativeDockAutoHideDelay, AppSettingsStore.defaultNativeDockAutoHideDelay)
    }

    func testSnapDelayReturnsFallbackForNonFiniteInput() {
        XCTAssertEqual(AppSettingsStore.snapDelay(.nan), AppSettingsStore.defaultEnabledEdgeAutoHideDelay)
        XCTAssertEqual(AppSettingsStore.snapDelay(.infinity, fallbackForNonFinite: 1.0), 1.0)
        XCTAssertEqual(AppSettingsStore.snapDelay(-.infinity, fallbackForNonFinite: 2.0), 2.0)
    }

    func testStoredActiveDelayRejectsWrongTypesAndUsesPerGroupFallback() {
        XCTAssertEqual(AppSettingsStore.sanitizedStoredDelay("bad", fallback: 1.0), 1.0)
        XCTAssertEqual(AppSettingsStore.sanitizedStoredDelay(true, fallback: 1.0), 1.0)
        XCTAssertEqual(AppSettingsStore.sanitizedStoredDelay(NSNumber(value: Double.nan), fallback: 1.0), 1.0)
        XCTAssertEqual(AppSettingsStore.sanitizedStoredDelay(2.04, fallback: 1.0), 2.0)

        let defaults = makeDefaults()
        defaults.set("bad", forKey: "app.neobar.autoHide.nativeDock.delay")
        defaults.set(true, forKey: "app.neobar.autoHide.edge.delay")

        let store = AppSettingsStore(defaults: defaults)

        XCTAssertEqual(store.nativeDockAutoHideDelay, AppSettingsStore.defaultNativeDockAutoHideDelay)
        XCTAssertEqual(store.edgeAutoHideDelay, AppSettingsStore.defaultEnabledEdgeAutoHideDelay)
        XCTAssertEqual(defaults.double(forKey: "app.neobar.autoHide.nativeDock.delay"), 1.0)
        XCTAssertEqual(defaults.double(forKey: "app.neobar.autoHide.edge.delay"), 0.1)
    }

    func testSanitizedLastEnabledDelayNeverReturnsResident() {
        XCTAssertEqual(AppSettingsStore.sanitizedLastEnabledDelay(nil), AppSettingsStore.defaultEnabledEdgeAutoHideDelay)
        XCTAssertEqual(AppSettingsStore.sanitizedLastEnabledDelay(.nan), AppSettingsStore.defaultEnabledEdgeAutoHideDelay)
        XCTAssertEqual(AppSettingsStore.sanitizedLastEnabledDelay(AppSettingsStore.neverHideDelay), AppSettingsStore.defaultEnabledEdgeAutoHideDelay)
        XCTAssertEqual(AppSettingsStore.sanitizedLastEnabledDelay(-50.0), AppSettingsStore.defaultEnabledEdgeAutoHideDelay)
        XCTAssertEqual(AppSettingsStore.sanitizedLastEnabledDelay(0.05), AppSettingsStore.finiteDelayMin)
        XCTAssertEqual(AppSettingsStore.sanitizedLastEnabledDelay(2.0), 2.0)
        XCTAssertEqual(AppSettingsStore.sanitizedLastEnabledDelay(AppSettingsStore.neverWakeDelay), AppSettingsStore.neverWakeDelay)
    }

    // MARK: - Reverse mouse wheel

    func testAppearanceDefaultsToSystemAndRoundTrips() {
        let defaults = makeDefaults()
        let store = AppSettingsStore(defaults: defaults)
        XCTAssertEqual(store.appearanceMode, .system)
        XCTAssertNil(defaults.object(forKey: "app.neobar.appearance"),
                     "reading must not write the default back")

        store.setAppearanceMode(.dark)
        XCTAssertEqual(AppSettingsStore(defaults: defaults).appearanceMode, .dark)
        store.setAppearanceMode(.light)
        XCTAssertEqual(AppSettingsStore(defaults: defaults).appearanceMode, .light)
    }

    func testAppearanceFallsBackToSystemOnABadValueAndIgnoresTheOrphanKey() {
        let defaults = makeDefaults()
        defaults.set("midnight", forKey: "app.neobar.appearance")
        XCTAssertEqual(AppSettingsStore(defaults: defaults).appearanceMode, .system)

        // The pre-glass key is an orphan: a choice stored there must not come back.
        let orphaned = makeDefaults()
        orphaned.set("dark", forKey: "app.neobar.appearanceMode")
        XCTAssertEqual(AppSettingsStore(defaults: orphaned).appearanceMode, .system)
        XCTAssertEqual(orphaned.string(forKey: "app.neobar.appearanceMode"), "dark")
    }

    func testScrollReverserDefaultsOffAndRoundTrips() {
        let defaults = makeDefaults()
        let store = AppSettingsStore(defaults: defaults)
        XCTAssertFalse(store.scrollReverserEnabled, "改写全系统输入事件的能力必须默认关")

        store.setScrollReverserEnabled(true)
        XCTAssertTrue(store.scrollReverserEnabled)
        XCTAssertTrue(AppSettingsStore(defaults: defaults).scrollReverserEnabled, "跨启动往返")

        store.setScrollReverserEnabled(false)
        XCTAssertFalse(AppSettingsStore(defaults: defaults).scrollReverserEnabled)
    }

    // MARK: - Custom show/hide shortcut storage

    func testEdgeToggleShortcutDefaultsToNilAndRoundTrips() {
        let defaults = makeDefaults()
        let store = AppSettingsStore(defaults: defaults)
        XCTAssertNil(store.edgeToggleShortcut, "缺键 = 默认 ⌥⇧⌘D")

        let custom = StoredHotKeyShortcut(keyCode: 40, carbonModifiers: 4352, glyphs: "⌃⌘K")
        store.setEdgeToggleShortcut(custom)
        XCTAssertEqual(store.edgeToggleShortcut, custom)

        let reloaded = AppSettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.edgeToggleShortcut, custom, "跨启动往返")
    }

    func testEdgeToggleShortcutResetRemovesKeyAndMalformedFallsBackToNil() {
        let defaults = makeDefaults()
        let store = AppSettingsStore(defaults: defaults)
        store.setEdgeToggleShortcut(StoredHotKeyShortcut(keyCode: 40, carbonModifiers: 4352, glyphs: "⌃⌘K"))

        store.setEdgeToggleShortcut(nil)
        XCTAssertNil(store.edgeToggleShortcut)
        XCTAssertNil(defaults.dictionary(forKey: "app.neobar.hotKey.edgeAutoHideMode"), "恢复默认要删键，不是写空值")

        // Bad data (wrong type / missing fields / out of range) always falls back to nil; it must not blow up the launch read or store half a key.
        defaults.set(["keyCode": "not-a-number", "glyphs": "X"], forKey: "app.neobar.hotKey.edgeAutoHideMode")
        XCTAssertNil(AppSettingsStore(defaults: defaults).edgeToggleShortcut)
        defaults.set(["keyCode": 99999, "modifiers": 256, "glyphs": "X"], forKey: "app.neobar.hotKey.edgeAutoHideMode")
        XCTAssertNil(AppSettingsStore(defaults: defaults).edgeToggleShortcut, "keyCode 超出 16 位不认")
        defaults.set(["keyCode": 40, "modifiers": 256, "glyphs": ""], forKey: "app.neobar.hotKey.edgeAutoHideMode")
        XCTAssertNil(AppSettingsStore(defaults: defaults).edgeToggleShortcut, "空字形不认")
    }

    // MARK: - Pure logic of menu group titles

    /// The shortcut is written into the title only when Carbon registration succeeded: if registration failed it can't be triggered, and mentioning it would be a lie.
    /// Since 2026-08-24 the glyphs are passed in by the caller (the user can rebind), and the title follows the currently effective combination.
    func testEdgeSectionTitleMentionsShortcutOnlyWhenRegistered() {
        XCTAssertEqual(
            AutoHideToggleMenuModel.edgeSectionTitle(isHotKeyRegistered: true, glyphs: "⌥⇧⌘D"),
            String(format: String(localized: "NeoBar (%@ to show/hide)"), "⌥⇧⌘D")
        )
        XCTAssertEqual(
            AutoHideToggleMenuModel.edgeSectionTitle(isHotKeyRegistered: true, glyphs: "⌃⌘K"),
            String(format: String(localized: "NeoBar (%@ to show/hide)"), "⌃⌘K")
        )
        XCTAssertEqual(
            AutoHideToggleMenuModel.edgeSectionTitle(isHotKeyRegistered: false, glyphs: "⌃⌘K"),
            String(localized: "NeoBar"),
            "注册失败时不提任何组合"
        )
    }

    @MainActor
    func testEdgeSliderIsCompactAndKeepsAccessibilityContext() {
        let view = PreferenceSliderMenuItemView(accessibilityTitle: "NeoBar唤醒时间")
        view.sync(delay: 0.5)

        XCTAssertEqual(view.frame.height, 58)
        XCTAssertEqual(view.accessibilityLabel(), "NeoBar唤醒时间，0.5s")
        XCTAssertEqual(view.accessibilityValue() as? String, "0.5s")
    }

    @MainActor
    func testTaskbarSizeSliderSpansTheHeightRangeAndReportsWholePoints() {
        let view = TaskbarSizeMenuItemView(accessibilityTitle: "Taskbar Size")
        var heights: [DockPanelHeight] = []
        view.onHeightChange = { heights.append($0) }
        guard let slider = view.subviews.compactMap({ $0 as? NSSlider }).first else {
            return XCTFail("the row must hold a slider")
        }

        XCTAssertEqual(slider.minValue, Double(DockPanelHeight.minimum))
        XCTAssertEqual(slider.maxValue, Double(DockPanelHeight.maximum))

        view.sync(height: DockPanelHeight(clamping: 70))
        XCTAssertEqual(slider.doubleValue, 70)
        XCTAssertTrue(heights.isEmpty, "syncing from the store must not write back")

        slider.doubleValue = 61.6
        _ = slider.sendAction(slider.action, to: slider.target)
        XCTAssertEqual(heights, [DockPanelHeight(clamping: 62)])
    }

    @MainActor
    func testNativeDockApplyRowIsAButtonWiredToApply() {
        let row = NativeDockApplyRowView()
        var fired = 0
        row.onApply = { fired += 1 }

        // Must be a real button, not an ordinary menu text row: a menu row has the same visual weight as its neighbors, and the user's eyes are still
        // on the slider just after dragging it; missing it turns into "thought it was set but it didn't take effect".
        guard let button = row.subviews.compactMap({ $0 as? MenuActionButton }).first else {
            return XCTFail("确认行里必须有一个真按钮")
        }

        // A custom view in a menu isn't in the key window; without overriding acceptsFirstMouse the first click is swallowed,
        // and the user would think the button is broken. This override looks redundant, and deleting it reproduces the bug.
        XCTAssertTrue(button.acceptsFirstMouse(for: nil))

        // Subviews (text / icon) must not intercept the mouse, otherwise the middle of the button can't be clicked.
        let center = NSPoint(x: button.frame.midX, y: button.frame.midY)
        XCTAssertIdentical(button.hitTest(center), button)

        button.performClickForTesting()
        XCTAssertEqual(fired, 1, "按钮必须接到 onApply，否则确认整个是死的")
    }

    @MainActor
    func testNativeDockApplyRowCarriesTargetTierForVoiceOver() {
        let row = NativeDockApplyRowView()
        row.updateTarget(
            description: AutoHideToggleMenuModel.nativeApplyTitle(draft: AppSettingsStore.neverWakeDelay)
        )
        // The button title is always "Apply"; the level goes only through accessibility: VoiceOver users can't see the slider position.
        XCTAssertEqual(row.accessibilityLabel(),
                       String(format: String(localized: "Apply “%@” (the Dock will restart)"), String(localized: "Never Wake")))
    }

    func testNativeApplyRowAppearsOnlyWhenDraftDiffersFromAppliedTier() {
        // The same level (including floating-point representation error) shouldn't surface the confirm row: there is nothing to apply.
        XCTAssertFalse(AutoHideToggleMenuModel.shouldShowNativeApply(draft: 1.0, applied: 1.0))
        XCTAssertFalse(AutoHideToggleMenuModel.shouldShowNativeApply(
            draft: AppSettingsStore.neverHideDelay,
            applied: AppSettingsStore.neverHideDelay
        ))
        // Compares integer levels rather than floats: the slider can only rest on levels, and values between levels fold into the same level, which means "unchanged".
        XCTAssertFalse(AutoHideToggleMenuModel.shouldShowNativeApply(draft: 1.0 + 1e-12, applied: 1.0))

        XCTAssertTrue(AutoHideToggleMenuModel.shouldShowNativeApply(
            draft: AppSettingsStore.neverWakeDelay,
            applied: AppSettingsStore.neverHideDelay
        ))
        XCTAssertTrue(AutoHideToggleMenuModel.shouldShowNativeApply(draft: 0.5, applied: 1.0))
    }

    func testNativeApplyTitleNamesTheTargetTier() {
        XCTAssertEqual(
            AutoHideToggleMenuModel.nativeApplyTitle(draft: AppSettingsStore.neverWakeDelay),
            String(format: String(localized: "Apply “%@” (the Dock will restart)"), String(localized: "Never Wake"))
        )
        XCTAssertEqual(
            AutoHideToggleMenuModel.nativeApplyTitle(draft: AppSettingsStore.neverHideDelay),
            String(format: String(localized: "Apply “%@” (the Dock will restart)"), String(localized: "Always Visible"))
        )
        XCTAssertEqual(
            AutoHideToggleMenuModel.nativeApplyTitle(draft: 1.0),
            String(format: String(localized: "Apply “%@” (the Dock will restart)"), "1.0s")
        )
    }

    func testDelayDisplayNameIsSharedBySliderAndApplyRow() {
        // The slider itself and the confirm row must use the same criterion, otherwise the level the confirm row states isn't what the slider shows.
        XCTAssertEqual(AutoHideToggleMenuModel.delayDisplayName(sliderIndex: 0), String(localized: "Always Visible"))
        XCTAssertEqual(
            AutoHideToggleMenuModel.delayDisplayName(sliderIndex: AppSettingsStore.sliderIndexMax),
            String(localized: "Never Wake")
        )
        XCTAssertEqual(
            AutoHideToggleMenuModel.delayDisplayName(
                sliderIndex: AppSettingsStore.sliderIndexFromDelay(1.0)
            ),
            "1.0s"
        )
    }

    func testResolvedStoreDelayCoversWriteAndReadQuadrants() {
        let target = 0.5
        let previous = AppSettingsStore.neverHideDelay

        // If the system is readable, always go by the real system value, regardless of whether the write succeeded.
        XCTAssertEqual(
            AutoHideToggleMenuModel.resolvedStoreDelay(
                writeSucceeded: true,
                systemState: NativeDockAutohideState(enabled: true, delay: 0.5),
                target: target,
                previous: previous
            ),
            0.5
        )
        XCTAssertEqual(
            AutoHideToggleMenuModel.resolvedStoreDelay(
                writeSucceeded: false,
                systemState: NativeDockAutohideState(enabled: true, delay: 0.5),
                target: target,
                previous: previous
            ),
            0.5,
            "多步写入可能已部分生效，读得到就按读到的来"
        )
        // Write succeeded but can't read back: keep target. Rolling back would make the UI the opposite of the system setting that has already taken effect.
        XCTAssertEqual(
            AutoHideToggleMenuModel.resolvedStoreDelay(
                writeSucceeded: true,
                systemState: nil,
                target: target,
                previous: previous
            ),
            target
        )
        // Write failed and can't read back: can only revert wholesale to before the change.
        XCTAssertEqual(
            AutoHideToggleMenuModel.resolvedStoreDelay(
                writeSucceeded: false,
                systemState: nil,
                target: target,
                previous: previous
            ),
            previous
        )
    }

    func testPreferenceSliderCommitIsConsumedExactlyOnce() {
        var tracker = PreferenceSliderCommitTracker()
        tracker.begin(currentDelay: 0.5)
        tracker.stage(1.0)
        // Repeated begin during a drag must not overwrite the starting point, otherwise previous becomes an intermediate value.
        tracker.begin(currentDelay: 0.9)
        tracker.stage(1.5)

        let first = tracker.consume()
        XCTAssertEqual(first?.previous, 0.5)
        XCTAssertEqual(first?.target, 1.5)
        // The confirm row's commit and "discard the draft when the menu opens" both go through consume, and only the first one gets a value:
        // otherwise the confirmed value would be dialed back to the old value by the subsequent discard logic, or defaults + killall Dock would be written one more time.
        XCTAssertNil(tracker.consume())
        XCTAssertNil(tracker.consume())
    }

    func testPreferenceSliderCommitSkipsUnchangedAndUnstartedAdjustments() {
        var unchanged = PreferenceSliderCommitTracker()
        unchanged.begin(currentDelay: 0.5)
        unchanged.stage(0.5)
        XCTAssertNil(unchanged.consume(), "值没变不该写系统")

        var neverStarted = PreferenceSliderCommitTracker()
        neverStarted.stage(1.0)
        XCTAssertNil(neverStarted.consume(), "没有起点就没有 previous，不能提交")

        // After consuming, starting a new round still works normally.
        var reused = PreferenceSliderCommitTracker()
        reused.begin(currentDelay: 0.2)
        reused.stage(0.4)
        XCTAssertNotNil(reused.consume())
        reused.begin(currentDelay: 0.4)
        reused.stage(0.8)
        XCTAssertEqual(reused.consume()?.previous, 0.4)
    }

    func testNativeDockSectionTitleMentionsSystemShortcutAsPlainText() {
        // ⌥⌘D belongs to macOS; we neither define nor register it. With the show/hide command deleted it is the
        // only one-key entry to "bring the Dock back temporarily", so the title must mention it, but only as plain text: setting it as a keyEquivalent would get it captured by the menu.
        XCTAssertTrue(AutoHideToggleMenuModel.nativeDockSectionTitle.contains("⌥⌘D"))
        // "Dock" is present in both languages (Chinese "System Dock" / English "The Dock"); assert the language-independent part.
        XCTAssertTrue(AutoHideToggleMenuModel.nativeDockSectionTitle.contains("Dock"))
    }

    func testReconciledStoreDelayAlignsStoreWithSystemTruth() {
        // System off: if the stored value isn't always-shown, change it to always-shown; if it already is, no change is needed.
        XCTAssertEqual(
            AutoHideToggleMenuModel.reconciledStoreDelay(systemEnabled: false, systemDelay: nil, currentStoreDelay: 1.0),
            AppSettingsStore.neverHideDelay
        )
        XCTAssertNil(
            AutoHideToggleMenuModel.reconciledStoreDelay(systemEnabled: false, systemDelay: 0.5, currentStoreDelay: AppSettingsStore.neverHideDelay)
        )

        // System on: align to the system delay (snapped to a valid level); if the key doesn't exist, use the system default 0.5.
        XCTAssertEqual(
            AutoHideToggleMenuModel.reconciledStoreDelay(systemEnabled: true, systemDelay: 0.2, currentStoreDelay: AppSettingsStore.neverHideDelay),
            0.2
        )
        XCTAssertEqual(
            AutoHideToggleMenuModel.reconciledStoreDelay(systemEnabled: true, systemDelay: nil, currentStoreDelay: AppSettingsStore.neverHideDelay),
            AutoHideToggleMenuModel.systemDefaultAutohideDelay
        )
        // 999 (the no-wake level) round-trips as is; 0 snaps to the minimum level 0.1; already consistent returns nil.
        XCTAssertEqual(
            AutoHideToggleMenuModel.reconciledStoreDelay(systemEnabled: true, systemDelay: 999.0, currentStoreDelay: 1.0),
            AppSettingsStore.neverWakeDelay
        )
        XCTAssertEqual(
            AutoHideToggleMenuModel.reconciledStoreDelay(systemEnabled: true, systemDelay: 0.0, currentStoreDelay: 1.0),
            AppSettingsStore.finiteDelayMin
        )
        XCTAssertEqual(
            AutoHideToggleMenuModel.reconciledStoreDelay(systemEnabled: true, systemDelay: -1.0, currentStoreDelay: 1.0),
            AppSettingsStore.finiteDelayMin,
            "系统开关明确开启时，负 delay 不能被解释成 App 的常驻哨兵"
        )
        XCTAssertEqual(
            AutoHideToggleMenuModel.reconciledStoreDelay(systemEnabled: true, systemDelay: .nan, currentStoreDelay: 0.2),
            AppSettingsStore.defaultNativeDockAutoHideDelay
        )
        XCTAssertNil(
            AutoHideToggleMenuModel.reconciledStoreDelay(systemEnabled: true, systemDelay: 1.0, currentStoreDelay: 1.0)
        )
    }

    @MainActor
    func testNativeDockAutohideStateReadRespectsSandboxAndInjectedReader() async {
        let sandboxed = NativeDockPreferencesService(
            sandbox: SandboxEnvironment(isSandboxed: true),
            runner: { _, _ in },
            autohideReader: { NativeDockAutohideState(enabled: true, delay: 0.5) }
        )
        let sandboxedState = await sandboxed.currentAutohideState()
        XCTAssertNil(sandboxedState, "沙箱下读不到，返回 nil 让调用方回退存值")

        let readable = NativeDockPreferencesService(
            sandbox: SandboxEnvironment(isSandboxed: false),
            runner: { _, _ in },
            autohideReader: { NativeDockAutohideState(enabled: true, delay: 0.2) }
        )
        let readableState = await readable.currentAutohideState()
        XCTAssertEqual(readableState, NativeDockAutohideState(enabled: true, delay: 0.2))
    }

    @MainActor
    func testSystemTruthReadersRunOffMainThread() async {
        let launch = LaunchAtLoginService(backend: ThreadProbeLaunchBackend())
        let launchState = await launch.currentState()
        XCTAssertEqual(launchState, .on)

        let native = NativeDockPreferencesService(
            sandbox: SandboxEnvironment(isSandboxed: false),
            runner: { _, _ in },
            autohideReader: {
                NativeDockAutohideState(enabled: !Thread.isMainThread, delay: 0.4)
            }
        )
        let nativeState = await native.currentAutohideState()
        XCTAssertEqual(
            nativeState,
            NativeDockAutohideState(enabled: true, delay: 0.4)
        )
    }

    func testOpenSystemDockSettingsUsesDeepLinkFirst() {
        var openedURLs: [URL] = []
        let service = NativeDockPreferencesService(
            sandbox: SandboxEnvironment(isSandboxed: false),
            runner: { _, _ in },
            autohideReader: { nil },
            urlOpener: { url in
                openedURLs.append(url)
                return true
            }
        )

        XCTAssertTrue(service.openSystemSettings())
        XCTAssertEqual(openedURLs.map(\.absoluteString), ["x-apple.systempreferences:com.apple.preference.dock"])
    }

    func testOpenSystemDockSettingsFallsBackToPreferencePane() {
        var openedURLs: [URL] = []
        let service = NativeDockPreferencesService(
            sandbox: SandboxEnvironment(isSandboxed: false),
            runner: { _, _ in },
            autohideReader: { nil },
            urlOpener: { url in
                openedURLs.append(url)
                return url.isFileURL
            }
        )

        XCTAssertTrue(service.openSystemSettings())
        XCTAssertEqual(openedURLs.count, 2)
        XCTAssertEqual(openedURLs[0].absoluteString, "x-apple.systempreferences:com.apple.preference.dock")
        XCTAssertEqual(openedURLs[1].path, "/System/Library/PreferencePanes/Dock.prefPane")
    }

    func testOpenSystemDockSettingsReportsFailureAfterBothAttempts() {
        let service = NativeDockPreferencesService(
            sandbox: SandboxEnvironment(isSandboxed: false),
            runner: { _, _ in },
            autohideReader: { nil },
            urlOpener: { _ in false }
        )

        XCTAssertFalse(service.openSystemSettings())
    }

    func testOpenSystemDockSettingsIsNotBlockedBySandboxWriteGate() {
        var openedURLs: [URL] = []
        let service = NativeDockPreferencesService(
            sandbox: SandboxEnvironment(isSandboxed: true),
            runner: { _, _ in },
            autohideReader: { nil },
            urlOpener: { url in
                openedURLs.append(url)
                return true
            }
        )

        XCTAssertFalse(service.isAvailable)
        XCTAssertTrue(service.openSystemSettings())
        XCTAssertEqual(openedURLs.count, 1)
    }

    // MARK: - System Dock group remembered mirror

    func testNativeRememberedSeedsFromCurrentFiniteValueOverStaleStoredValue() {
        let defaults = makeDefaults()
        defaults.set(2.0, forKey: "app.neobar.autoHide.nativeDock.delay")
        defaults.set(0.5, forKey: "app.neobar.autoHide.nativeDock.lastEnabledDelay")

        let store = AppSettingsStore(defaults: defaults)

        XCTAssertEqual(store.lastEnabledNativeDockAutoHideDelay, 2.0)
        XCTAssertEqual(defaults.double(forKey: "app.neobar.autoHide.nativeDock.lastEnabledDelay"), 2.0)
    }

    func testNativeRememberedIsReadWhenCurrentIsResidentAndCorruptFallsBackToNativeDefault() {
        let defaults = makeDefaults()
        defaults.set(AppSettingsStore.neverHideDelay, forKey: "app.neobar.autoHide.nativeDock.delay")
        defaults.set(2.0, forKey: "app.neobar.autoHide.nativeDock.lastEnabledDelay")
        XCTAssertEqual(AppSettingsStore(defaults: defaults).lastEnabledNativeDockAutoHideDelay, 2.0)

        let corrupted = makeDefaults()
        corrupted.set(AppSettingsStore.neverHideDelay, forKey: "app.neobar.autoHide.nativeDock.delay")
        corrupted.set(AppSettingsStore.neverHideDelay, forKey: "app.neobar.autoHide.nativeDock.lastEnabledDelay")
        // The fallback is the native group's own default level 1.0, not the edge's 0.1.
        XCTAssertEqual(AppSettingsStore(defaults: corrupted).lastEnabledNativeDockAutoHideDelay, AppSettingsStore.defaultNativeDockAutoHideDelay)
    }

    func testNativeSetterSyncsRememberedBeforeActiveDedup() {
        let defaults = makeDefaults()
        let store = AppSettingsStore(defaults: defaults)

        store.setNativeDockAutoHideDelay(2.0)
        XCTAssertEqual(store.lastEnabledNativeDockAutoHideDelay, 2.0)

        store.setNativeDockAutoHideDelay(AppSettingsStore.neverHideDelay)
        XCTAssertEqual(store.nativeDockAutoHideDelay, AppSettingsStore.neverHideDelay)
        XCTAssertEqual(store.lastEnabledNativeDockAutoHideDelay, 2.0, "写入常驻不动 remembered")

        let rebuilt = AppSettingsStore(defaults: defaults)
        XCTAssertEqual(rebuilt.lastEnabledNativeDockAutoHideDelay, 2.0, "跨 Store 重建保留 remembered")
    }

    func testSanitizedLastEnabledDelayHonorsPerGroupFallback() {
        XCTAssertEqual(AppSettingsStore.sanitizedLastEnabledDelay(nil, fallback: AppSettingsStore.defaultNativeDockAutoHideDelay), 1.0)
        XCTAssertEqual(AppSettingsStore.sanitizedLastEnabledDelay(.nan, fallback: 1.0), 1.0)
        XCTAssertEqual(AppSettingsStore.sanitizedLastEnabledDelay(AppSettingsStore.neverHideDelay, fallback: 1.0), 1.0)
        XCTAssertEqual(AppSettingsStore.sanitizedLastEnabledDelay(2.0, fallback: 1.0), 2.0)
    }

    func testFullscreenPendingConfirmationIsAtomicAndStaleTimeoutCannotRevealPanels() {
        var state = PanelVisibilityState()
        state.beginFullscreenTransition(generation: 7)
        XCTAssertFalse(state.isVisible)
        XCTAssertFalse(state.timeoutFullscreenTransition(generation: 6))
        XCTAssertFalse(state.isVisible)

        XCTAssertTrue(state.confirmFullscreenTransition(generation: 7))
        XCTAssertFalse(state.isVisible)
        XCTAssertFalse(state.hideReasons.contains(.fullscreenTransitionPending))
        XCTAssertTrue(state.hideReasons.contains(.fullscreen))
    }

    func testFullscreenPendingTimeoutPreservesEdgeHiddenStateAndBlocksEdgeTimers() {
        var state = PanelVisibilityState()
        state.setEdgeAutoHidden(true)
        state.beginFullscreenTransition(generation: 8)
        XCTAssertFalse(EdgeAutoHideRuntimeRules.canArmWake(state: state, delay: 0.5))
        XCTAssertFalse(EdgeAutoHideRuntimeRules.canArmIdleHide(state: state, delay: 0.5))

        XCTAssertTrue(state.timeoutFullscreenTransition(generation: 8))
        XCTAssertFalse(state.isVisible)
        XCTAssertTrue(state.hideReasons.contains(.edgeAutoHide))
    }

    func testFullscreenSpaceHoldBeginsOnlyFromConfirmedFullscreen() {
        XCTAssertTrue(FullscreenSpaceHoldDecision.shouldBegin(isFullscreen: true, hasInputIntent: false))
        XCTAssertFalse(FullscreenSpaceHoldDecision.shouldBegin(isFullscreen: false, hasInputIntent: false))
        XCTAssertFalse(FullscreenSpaceHoldDecision.shouldBegin(isFullscreen: true, hasInputIntent: true))
    }

    // While the hold lasts, **neither direction's instantaneous verdict is let through**. Before 2026-08-30, true was applied directly with .apply,
    // so the false true that CG reported late at the moment of exiting fullscreen destroyed the 120ms hold, the correct AX false was dropped as .stale,
    // and the strip waited for the 5-second reconciliation to return (measured fingerprint in Docs/05). During the hold true has nothing to do anyway: the state is already
    // .fullscreen; everything waits for the final review.
    func testFullscreenSpaceHoldSuppressesTransientVerdictsInBothDirections() {
        XCTAssertEqual(
            FullscreenSpaceHoldDecision.disposition(
                isFullscreenVerdict: false,
                expectedGeneration: 4,
                activeGeneration: 4,
                isFinalWindowedConfirmation: false
            ),
            .hold
        )
        XCTAssertEqual(
            FullscreenSpaceHoldDecision.disposition(
                isFullscreenVerdict: true,
                expectedGeneration: 4,
                activeGeneration: 4,
                isFinalWindowedConfirmation: false
            ),
            .hold
        )
    }

    // Regression for the full script of exiting fullscreen: the space-switch arm starts a hold -> a false CG true during the transition must not kill the hold ->
    // the final-review false is let through to reveal; the final-review true (a real full -> full switch) is also let through, keeping hidden.
    func testFullscreenSpaceHoldExitScenarioRevealsOnFinalVerdictOnly() {
        let g: UInt64 = 9
        // Transition-period space-cg true: hold
        XCTAssertEqual(
            FullscreenSpaceHoldDecision.disposition(
                isFullscreenVerdict: true, expectedGeneration: g,
                activeGeneration: g, isFinalWindowedConfirmation: false
            ),
            .hold
        )
        // Subsequent space-ax false (same generation, not the final review): still hold
        XCTAssertEqual(
            FullscreenSpaceHoldDecision.disposition(
                isFullscreenVerdict: false, expectedGeneration: g,
                activeGeneration: g, isFinalWindowedConfirmation: false
            ),
            .hold
        )
        // 120ms final-review false: let through -> reveal
        XCTAssertEqual(
            FullscreenSpaceHoldDecision.disposition(
                isFullscreenVerdict: false, expectedGeneration: g,
                activeGeneration: g, isFinalWindowedConfirmation: true
            ),
            .apply
        )
        // 120ms final-review true (full -> full): also let through -> stays hidden
        XCTAssertEqual(
            FullscreenSpaceHoldDecision.disposition(
                isFullscreenVerdict: true, expectedGeneration: g,
                activeGeneration: g, isFinalWindowedConfirmation: true
            ),
            .apply
        )
    }

    func testFullscreenSpaceHoldRequiresFinalConfirmationBeforeWindowedReveal() {
        XCTAssertEqual(
            FullscreenSpaceHoldDecision.disposition(
                isFullscreenVerdict: false,
                expectedGeneration: 7,
                activeGeneration: 7,
                isFinalWindowedConfirmation: true
            ),
            .apply
        )
        XCTAssertEqual(FullscreenSpaceHoldDecision.postSpaceConfirmationDelay, 0.12)
        XCTAssertEqual(FullscreenSpaceHoldDecision.activationFallbackDelay, 0.5)
    }

    func testFullscreenSpaceHoldRejectsOldGenerationAndAppliesWithoutHold() {
        XCTAssertEqual(
            FullscreenSpaceHoldDecision.disposition(
                isFullscreenVerdict: false,
                expectedGeneration: 8,
                activeGeneration: 9,
                isFinalWindowedConfirmation: true
            ),
            .stale
        )
        XCTAssertEqual(
            FullscreenSpaceHoldDecision.disposition(
                isFullscreenVerdict: false,
                expectedGeneration: 9,
                activeGeneration: nil,
                isFinalWindowedConfirmation: true
            ),
            .stale
        )
        XCTAssertEqual(
            FullscreenSpaceHoldDecision.disposition(
                isFullscreenVerdict: false,
                expectedGeneration: nil,
                activeGeneration: nil,
                isFinalWindowedConfirmation: false
            ),
            .apply
        )
    }

    func testTaskbarScreenPlacementDefaultsToFollowMouseWithoutWritingKeys() {
        let defaults = makeDefaults()
        let store = AppSettingsStore(defaults: defaults)

        XCTAssertEqual(store.taskbarScreenPlacement, .followMouse)
        // A missing key means the default; init must not write the key out (existing users upgrade without noticing).
        XCTAssertNil(defaults.object(forKey: "app.neobar.taskbarScreen.mode"))
        XCTAssertNil(defaults.object(forKey: "app.neobar.taskbarScreen.pinned"))
    }

    func testTaskbarScreenPlacementPinnedRoundTrips() {
        let defaults = makeDefaults()
        let store = AppSettingsStore(defaults: defaults)
        let selection = PinnedScreenSelection(uuid: "UUID-1", name: "LG HDR 4K")

        store.setTaskbarScreenPlacement(.pinned(selection))

        XCTAssertEqual(store.taskbarScreenPlacement, .pinned(selection))
        let rebuilt = AppSettingsStore(defaults: defaults)
        XCTAssertEqual(rebuilt.taskbarScreenPlacement, .pinned(selection))
    }

    func testTaskbarScreenPlacementPinnedWithBrokenSelectionFallsBackAndRewritesMode() {
        let defaults = makeDefaults()
        defaults.set("pinned", forKey: "app.neobar.taskbarScreen.mode")
        defaults.set(["uuid": 42], forKey: "app.neobar.taskbarScreen.pinned")

        let store = AppSettingsStore(defaults: defaults)

        XCTAssertEqual(store.taskbarScreenPlacement, .followMouse)
        XCTAssertEqual(
            defaults.string(forKey: "app.neobar.taskbarScreen.mode"),
            "followMouse",
            "坏选择回退后要立刻重写 mode 键，否则每次启动重走回退且 UI 与存值对不上"
        )
    }

    func testTaskbarScreenPlacementUnknownModeDegradesWithoutRewritingKey() {
        let defaults = makeDefaults()
        defaults.set("someFutureMode", forKey: "app.neobar.taskbarScreen.mode")

        let store = AppSettingsStore(defaults: defaults)

        XCTAssertEqual(store.taskbarScreenPlacement, .followMouse)
        XCTAssertEqual(
            defaults.string(forKey: "app.neobar.taskbarScreen.mode"),
            "someFutureMode",
            "将来版本的档被老版本读到时只降级运行，不毁掉用户的选择"
        )
    }

    func testTaskbarScreenPlacementAllScreensRoundTrips() {
        let defaults = makeDefaults()
        let store = AppSettingsStore(defaults: defaults)

        store.setTaskbarScreenPlacement(.allScreens)

        XCTAssertEqual(store.taskbarScreenPlacement, .allScreens)
        XCTAssertEqual(defaults.string(forKey: "app.neobar.taskbarScreen.mode"), "allScreens")
        XCTAssertEqual(AppSettingsStore(defaults: defaults).taskbarScreenPlacement, .allScreens)

        store.setTaskbarScreenPlacement(.allScreensPerDisplay)
        XCTAssertEqual(defaults.string(forKey: "app.neobar.taskbarScreen.mode"), "allScreensPerDisplay")
        XCTAssertEqual(AppSettingsStore(defaults: defaults).taskbarScreenPlacement, .allScreensPerDisplay)
    }

    func testTaskbarScreenPlacementAllScreensKeepsPinnedSelectionRemembered() {
        let defaults = makeDefaults()
        let store = AppSettingsStore(defaults: defaults)
        let selection = PinnedScreenSelection(uuid: "UUID-1", name: "LG HDR 4K")
        store.setTaskbarScreenPlacement(.pinned(selection))

        store.setTaskbarScreenPlacement(.allScreens)

        XCTAssertNotNil(defaults.dictionary(forKey: "app.neobar.taskbarScreen.pinned"))
        store.setTaskbarScreenPlacement(.pinned(selection))
        XCTAssertEqual(AppSettingsStore(defaults: defaults).taskbarScreenPlacement, .pinned(selection))
    }

    func testTaskbarScreenPlacementSwitchingBackKeepsPinnedSelectionRemembered() {
        let defaults = makeDefaults()
        let store = AppSettingsStore(defaults: defaults)
        let selection = PinnedScreenSelection(uuid: "UUID-1", name: "LG HDR 4K")
        store.setTaskbarScreenPlacement(.pinned(selection))

        store.setTaskbarScreenPlacement(.followMouse)

        XCTAssertEqual(store.taskbarScreenPlacement, .followMouse)
        XCTAssertEqual(defaults.string(forKey: "app.neobar.taskbarScreen.mode"), "followMouse")
        XCTAssertNotNil(
            defaults.dictionary(forKey: "app.neobar.taskbarScreen.pinned"),
            "remembered 惯例：切回跟随鼠标保留上次选的屏"
        )
    }

    func testTaskbarPerDisplaySeedArmsOnlyForPristineInstallAndOnlyOnce() {
        let defaults = makeDefaults()
        let store = AppSettingsStore(defaults: defaults)

        store.armTaskbarPerDisplaySeedForFreshInstall(lineage: .priorUse)
        XCTAssertNil(defaults.object(forKey: "app.neobar.taskbarScreen.perDisplaySeedPending"))

        store.armTaskbarPerDisplaySeedForFreshInstall(lineage: .pristine)
        XCTAssertTrue(store.taskbarPerDisplaySeedPending)
        store.consumeTaskbarPerDisplaySeedIfPresent()
        store.armTaskbarPerDisplaySeedForFreshInstall(lineage: .pristine)
        XCTAssertFalse(store.taskbarPerDisplaySeedPending, "consumed marker must never re-arm")
    }

    func testAppSettingsStoreInitNeverArmsTaskbarPerDisplaySeed() {
        let defaults = makeDefaults()

        _ = AppSettingsStore(defaults: defaults)

        XCTAssertNil(defaults.object(forKey: "app.neobar.taskbarScreen.perDisplaySeedPending"))
    }

    func testExplicitUnchangedPlacementChoiceConsumesTaskbarPerDisplaySeed() {
        let defaults = makeDefaults()
        let store = AppSettingsStore(defaults: defaults)
        store.armTaskbarPerDisplaySeedForFreshInstall(lineage: .pristine)

        store.setTaskbarScreenPlacement(.followMouse)

        XCTAssertFalse(store.taskbarPerDisplaySeedPending)
        XCTAssertNil(defaults.object(forKey: "app.neobar.taskbarScreen.mode"))
    }

    func testTaskbarPerDisplaySeedWritesModeAndConsumesMarker() {
        let defaults = makeDefaults()
        let store = AppSettingsStore(defaults: defaults)
        store.armTaskbarPerDisplaySeedForFreshInstall(lineage: .pristine)

        store.applyTaskbarPerDisplaySeed()

        XCTAssertEqual(store.taskbarScreenPlacement, .allScreensPerDisplay)
        XCTAssertEqual(defaults.string(forKey: "app.neobar.taskbarScreen.mode"), "allScreensPerDisplay")
        XCTAssertFalse(store.taskbarPerDisplaySeedPending)
    }

    func testTaskbarPlacementChoiceDoesNotCreateSeedMarkerForUpgrader() {
        let defaults = makeDefaults()
        let store = AppSettingsStore(defaults: defaults)

        store.setTaskbarScreenPlacement(.allScreens)

        XCTAssertNil(defaults.object(forKey: "app.neobar.taskbarScreen.perDisplaySeedPending"))
    }

    func testPriorUseLineageCannotSeedWindowLift() {
        let defaults = makeDefaults()
        let store = AppSettingsStore(defaults: defaults)

        store.seedWindowLiftEnabledForFreshInstall(lineage: .priorUse)

        XCTAssertFalse(store.windowLiftEnabled)
        XCTAssertNil(defaults.object(forKey: "app.neobar.windowLiftEnabled"))
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "app.neobar.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

/// Only answers "whether we are on the main thread at the moment of reading state": not -> `.on`.
private struct ThreadProbeLaunchBackend: LaunchAtLoginBackend {
    func readState() -> LaunchAtLoginState { Thread.isMainThread ? .off : .on }
    func setEnabled(_ enabled: Bool) throws {}
    func openSettings() {}
}
