import XCTest

@MainActor
final class MessagingAppStoreTests: XCTestCase {

    private func makeDefaults() -> UserDefaults {
        let suite = "test-messaging-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func makeStore(_ ids: [String], defaults: UserDefaults? = nil) -> MessagingAppStore {
        let d = defaults ?? makeDefaults()
        let store = MessagingAppStore(defaults: d)
        for id in ids { store.mark(id) }
        return store
    }

    // MARK: - reorder

    func testReorderBeforeAndAfterTarget() {
        let store = makeStore(["a", "b", "c"])
        store.reorder(draggedID: "c", relativeTo: "a", after: false)
        XCTAssertEqual(store.bundleIDs, ["c", "a", "b"])
        store.reorder(draggedID: "c", relativeTo: "b", after: true)
        XCTAssertEqual(store.bundleIDs, ["a", "b", "c"])
    }

    func testReorderToHeadAndTail() {
        let store = makeStore(["a", "b", "c"])
        store.reorder(draggedID: "b", relativeTo: "a", after: false)   // first position
        XCTAssertEqual(store.bundleIDs, ["b", "a", "c"])
        store.reorder(draggedID: "b", relativeTo: "c", after: true)    // last position
        XCTAssertEqual(store.bundleIDs, ["a", "c", "b"])
    }

    func testReorderMiddle() {
        let store = makeStore(["a", "b", "c", "d"])
        store.reorder(draggedID: "d", relativeTo: "b", after: false)
        XCTAssertEqual(store.bundleIDs, ["a", "d", "b", "c"])
    }

    func testReorderOntoSelfIsNoOp() {
        let store = makeStore(["a", "b"])
        store.reorder(draggedID: "a", relativeTo: "a", after: true)
        XCTAssertEqual(store.bundleIDs, ["a", "b"])
    }

    func testReorderUnknownIDsAreNoOp() {
        let store = makeStore(["a", "b"])
        store.reorder(draggedID: "ghost", relativeTo: "a", after: true)
        XCTAssertEqual(store.bundleIDs, ["a", "b"])
        store.reorder(draggedID: "a", relativeTo: "ghost", after: true)
        XCTAssertEqual(store.bundleIDs, ["a", "b"])
    }

    /// Hidden members (tucked into the drawer / not running, not shown in the zone) keep their relative positions -- reorder directly changes the full persisted array.
    func testHiddenMemberKeepsRelativePosition() {
        let store = makeStore(["a", "hidden", "b"])
        store.reorder(draggedID: "a", relativeTo: "b", after: true)
        XCTAssertEqual(store.bundleIDs, ["hidden", "b", "a"])
    }

    func testReorderPersistsAcrossReload() {
        let defaults = makeDefaults()
        let store = makeStore(["a", "b", "c"], defaults: defaults)
        store.reorder(draggedID: "c", relativeTo: "a", after: false)
        let reloaded = MessagingAppStore(defaults: defaults)
        XCTAssertEqual(reloaded.bundleIDs, ["c", "a", "b"])
    }

    // MARK: - V2 key migration

    func testNameListMigratesFromLegacyKeyToV2AndFreezesLegacy() {
        let defaults = makeDefaults()
        defaults.set(["com.chat.legacy"], forKey: "messagingBundleIDs")
        let store = MessagingAppStore(defaults: defaults)
        XCTAssertTrue(store.contains("com.chat.legacy"))
        XCTAssertEqual(defaults.stringArray(forKey: "messagingBundleIDsV2"), ["com.chat.legacy"])
        // The old key is frozen and left untouched (readable on rollback).
        XCTAssertEqual(defaults.stringArray(forKey: "messagingBundleIDs"), ["com.chat.legacy"])
    }

    func testFreshInstallPersistsEmptyV2Markers() {
        let defaults = makeDefaults()
        _ = MessagingAppStore(defaults: defaults)
        XCTAssertEqual(defaults.stringArray(forKey: "messagingBundleIDsV2"), [])
        XCTAssertEqual(defaults.stringArray(forKey: "messagingOptOutBundleIDsV2"), [])
    }

    func testExistingV2KeyPreventsRemigrationFromLegacy() {
        let defaults = makeDefaults()
        defaults.set(["com.v2.only"], forKey: "messagingBundleIDsV2")
        defaults.set(["com.legacy.ignored"], forKey: "messagingBundleIDs")
        let store = MessagingAppStore(defaults: defaults)
        XCTAssertTrue(store.contains("com.v2.only"))
        XCTAssertFalse(store.contains("com.legacy.ignored"))
    }

    func testOptOutMigratesIndependentlyOfNameList() {
        // The list already has V2 and opt-out has only the old key -> opt-out migrates independently (partial-migration state).
        let defaults = makeDefaults()
        defaults.set([String](), forKey: "messagingBundleIDsV2")
        defaults.set(["com.tencent.qq"], forKey: "messagingOptOutBundleIDs") // builtin, opted out
        let store = MessagingAppStore(defaults: defaults)
        let added = store.autoRegister(runningBundleIDs: ["com.tencent.qq"],
                                       mainWindowIdentifiableBundleIDs: ["com.tencent.qq"])
        XCTAssertTrue(added.isEmpty) // the opt-out migration took effect; no re-registration
        XCTAssertEqual(defaults.stringArray(forKey: "messagingOptOutBundleIDsV2"), ["com.tencent.qq"])
    }

    func testMarkReturnsTrueOnFirstJoinFalseAfter() {
        let store = MessagingAppStore(defaults: makeDefaults())
        XCTAssertTrue(store.mark("com.chat.app"))
        XCTAssertFalse(store.mark("com.chat.app"))
    }

    func testAutoRegisterReturnsNewlyAddedIDs() {
        let store = MessagingAppStore(defaults: makeDefaults())
        let chat = "com.tencent.xinWeChat" // builtin whitelist
        let added = store.autoRegister(runningBundleIDs: [chat, "com.not.messaging"],
                                       mainWindowIdentifiableBundleIDs: [chat])
        XCTAssertEqual(added, [chat])
        // No additions in the second round
        XCTAssertTrue(store.autoRegister(runningBundleIDs: [chat],
                                         mainWindowIdentifiableBundleIDs: [chat]).isEmpty)
    }

    // MARK: - Admission capability threshold (an app whose main window can't be recognized doesn't enter the messaging zone)

    func testAutoRegisterSkipsWhitelistedAppWithoutIdentifiableMainWindow() {
        // Apple "Messages" is in the built-in list, but its Catalyst numbered title never lets the main window be recognized -> must not be registered.
        let store = MessagingAppStore(defaults: makeDefaults())
        let messages = "com.apple.MobileSMS"
        XCTAssertTrue(store.autoRegister(runningBundleIDs: [messages],
                                         mainWindowIdentifiableBundleIDs: []).isEmpty)
        XCTAssertFalse(store.contains(messages))
    }

    func testAutoRegisterAdmitsOnceMainWindowBecomesIdentifiable() {
        // Not registered while the main window is closed; it enters the list only in the round the main window appears.
        let store = MessagingAppStore(defaults: makeDefaults())
        let chat = "com.tencent.xinWeChat"
        XCTAssertTrue(store.autoRegister(runningBundleIDs: [chat],
                                         mainWindowIdentifiableBundleIDs: []).isEmpty)
        XCTAssertEqual(store.autoRegister(runningBundleIDs: [chat],
                                          mainWindowIdentifiableBundleIDs: [chat]), [chat])
    }

    func testMemberIsNeverReTestedSoItCannotFlapOutOfTheZone() {
        // Once passed it stays on the list permanently: WeChat's main window closing (unrecognizable at that moment) must not kick it out of the messaging zone.
        let store = MessagingAppStore(defaults: makeDefaults())
        let chat = "com.tencent.xinWeChat"
        XCTAssertEqual(store.autoRegister(runningBundleIDs: [chat],
                                          mainWindowIdentifiableBundleIDs: [chat]), [chat])
        _ = store.autoRegister(runningBundleIDs: [chat], mainWindowIdentifiableBundleIDs: [])
        XCTAssertTrue(store.contains(chat), "已注册成员不因当前认不出主窗口而被移除")
    }

    func testManualMarkBypassesTheCapabilityGate() {
        // owner 2026-07-21: manual marking isn't subject to the admission threshold.
        let store = MessagingAppStore(defaults: makeDefaults())
        XCTAssertTrue(store.mark("com.apple.MobileSMS"))
        XCTAssertTrue(store.contains("com.apple.MobileSMS"))
    }


    // MARK: - isMessagingApp: identity is separate from "being in the messaging zone" (2026-08-23)

    func testBuiltinAppIsMessagingAppWithoutEnteringZone() {
        let store = makeStore([])
        XCTAssertTrue(store.isMessagingApp("com.apple.MobileSMS"), "内置名单 = 身份，不需要进区")
        XCTAssertFalse(store.contains("com.apple.MobileSMS"), "身份不等于消息区成员")
    }

    func testManualPinGrantsIdentityUntilUnpinnedForUnknownApp() {
        let store = makeStore(["custom.chat"])
        XCTAssertTrue(store.isMessagingApp("custom.chat"))
        store.unmark("custom.chat")
        XCTAssertFalse(store.isMessagingApp("custom.chat"), "既不在名单也不在白名单的 app，取消固定后没有任何身份来源")
    }

    /// 2026-08-23 acceptance rework: the owner had earlier removed Messages from the messaging zone, and the red dot disappeared. Removing it via "Pinned on the Dock's left side"
    /// only expresses "don't pin it in the zone"; the red dot of a built-in messaging app must not vanish with it.
    func testUnpinningBuiltinKeepsIdentity() {
        let store = makeStore(["com.apple.MobileSMS"])
        store.unmark("com.apple.MobileSMS")
        XCTAssertFalse(store.contains("com.apple.MobileSMS"), "取消后不在区里")
        XCTAssertTrue(store.isMessagingApp("com.apple.MobileSMS"), "但仍是消息应用，红点照画")
    }

    func testUnknownAppIsNotMessagingApp() {
        let store = makeStore([])
        XCTAssertFalse(store.isMessagingApp("com.example.nothing"))
        XCTAssertFalse(store.isMessagingApp(""))
    }
}
