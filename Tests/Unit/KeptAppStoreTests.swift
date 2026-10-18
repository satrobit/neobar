import XCTest
@testable import NeoBar

@MainActor
final class KeptAppStoreTests: XCTestCase {

    /// By default seeds the Finder seeding marker as true first, so migration cases examine only the migration itself; seeding behavior is covered by dedicated cases.
    private func makeDefaults(finderSeeded: Bool = true) -> UserDefaults {
        let suite = "test-kept-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        if finderSeeded { defaults.set(true, forKey: KeptAppStore.finderSeedKey) }
        return defaults
    }

    func testFreshInstallPersistsEmptyV3MigrationMarker() {
        let defaults = makeDefaults()
        let store = KeptAppStore(defaults: defaults)
        XCTAssertTrue(store.bundleIDs.isEmpty)
        XCTAssertEqual(defaults.stringArray(forKey: KeptAppStore.defaultsKey), [])
    }

    // MARK: - Finder one-time seeding (owner, 2026-08-20: ticked by default)

    func testFreshInstallSeedsFinderAsKept() {
        let defaults = makeDefaults(finderSeeded: false)
        let store = KeptAppStore(defaults: defaults)
        XCTAssertEqual(store.bundleIDs, [FinderTaskbarPolicy.bundleID])
        XCTAssertEqual(defaults.stringArray(forKey: KeptAppStore.defaultsKey),
                       [FinderTaskbarPolicy.bundleID])
        XCTAssertTrue(defaults.bool(forKey: KeptAppStore.finderSeedKey))
    }

    func testExistingUserGetsFinderAppendedAtTail() {
        // An old user's V3 was written long ago; seeding must use a separate marker key, and append to the tail without disturbing the existing order.
        let defaults = makeDefaults(finderSeeded: false)
        defaults.set(["com.example.first", "com.example.second"], forKey: KeptAppStore.defaultsKey)
        let store = KeptAppStore(defaults: defaults)
        XCTAssertEqual(store.bundleIDs,
                       ["com.example.first", "com.example.second", FinderTaskbarPolicy.bundleID])
    }

    func testUncheckedFinderIsNotReseededOnNextLaunch() {
        let defaults = makeDefaults(finderSeeded: false)
        let first = KeptAppStore(defaults: defaults)
        first.remove(FinderTaskbarPolicy.bundleID)     // the user right-clicks to untick
        let second = KeptAppStore(defaults: defaults)  // next launch
        XCTAssertFalse(second.contains(FinderTaskbarPolicy.bundleID))
    }

    // MARK: - System all-apps entry (owner 2026-10-07: fresh installs only)

    func testFreshInstallKeepsAppsRightAfterFinder() {
        let store = KeptAppStore(defaults: makeDefaults(finderSeeded: false))
        store.seedSystemAppLauncherForFreshInstall(lineage: .pristine) { _ in true }
        XCTAssertEqual(store.bundleIDs, [FinderTaskbarPolicy.bundleID, "com.apple.apps.launcher"])
    }

    func testLaunchpadIsNeverSeededBeforeMacOS26() {
        let store = KeptAppStore(defaults: makeDefaults())
        store.seedSystemAppLauncherForFreshInstall(lineage: .pristine) { $0 == "com.apple.launchpad.launcher" }
        XCTAssertTrue(store.bundleIDs.isEmpty)
    }

    func testUpgraderNeverGetsSystemAppLauncher() {
        let defaults = makeDefaults()
        defaults.set(["com.example.app"], forKey: KeptAppStore.defaultsKey)
        let store = KeptAppStore(defaults: defaults)
        store.seedSystemAppLauncherForFreshInstall(lineage: .priorUse) { _ in true }
        XCTAssertEqual(store.bundleIDs, ["com.example.app"])
    }

    func testNoInstalledLauncherSeedsNothing() {
        let store = KeptAppStore(defaults: makeDefaults())
        store.seedSystemAppLauncherForFreshInstall(lineage: .pristine) { _ in false }
        XCTAssertTrue(store.bundleIDs.isEmpty)
    }

    func testLoadsFromV3Key() {
        let defaults = makeDefaults()
        defaults.set(["com.example.app"], forKey: KeptAppStore.defaultsKey)
        let store = KeptAppStore(defaults: defaults)
        XCTAssertEqual(store.bundleIDs, ["com.example.app"])
    }

    func testCanKeepAcceptsFinderAndRejectsBlank() {
        let store = KeptAppStore(defaults: makeDefaults())
        XCTAssertTrue(store.canKeep(FinderTaskbarPolicy.bundleID))
        XCTAssertFalse(store.canKeep("   "))
    }

    func testAddAcceptsFinder() {
        let defaults = makeDefaults()
        let store = KeptAppStore(defaults: defaults)
        store.add(FinderTaskbarPolicy.bundleID)
        XCTAssertEqual(store.bundleIDs, [FinderTaskbarPolicy.bundleID])
    }

    func testAddAndContains() {
        let defaults = makeDefaults()
        let store = KeptAppStore(defaults: defaults)
        store.add("com.example.app")
        XCTAssertTrue(store.contains("com.example.app"))
        XCTAssertEqual(defaults.stringArray(forKey: KeptAppStore.defaultsKey), ["com.example.app"])
    }

    func testRemove() {
        let defaults = makeDefaults()
        defaults.set(["com.example.first", "com.example.second"], forKey: KeptAppStore.defaultsKey)
        let store = KeptAppStore(defaults: defaults)
        store.remove("com.example.first")
        XCTAssertFalse(store.contains("com.example.first"))
        XCTAssertEqual(defaults.stringArray(forKey: KeptAppStore.defaultsKey), ["com.example.second"])
    }

    // MARK: - V3 migration

    func testMigratesFromV2PlusMessaging() {
        let defaults = makeDefaults()
        defaults.set(["com.example.kept"], forKey: KeptAppStore.previousDefaultsKey) // kept V2
        defaults.set(["com.chat.app"], forKey: "messagingBundleIDsV2")               // authoritative messaging list
        defaults.set(["com.ignored.pinned"], forKey: "pinnedAppBundleIDs")           // when V2 exists, pinned/drawer are ignored
        let store = KeptAppStore(defaults: defaults)
        XCTAssertEqual(store.bundleIDs, ["com.example.kept", "com.chat.app"])
        XCTAssertEqual(defaults.stringArray(forKey: KeptAppStore.defaultsKey),
                       ["com.example.kept", "com.chat.app"])
    }

    func testMessagingV2KeyIsAuthoritativeEvenWhenEmpty() {
        // messaging V2 exists but is empty → authoritative is empty; falling back to the old messaging key to take a union is forbidden.
        let defaults = makeDefaults()
        defaults.set(["com.example.kept"], forKey: KeptAppStore.previousDefaultsKey)
        defaults.set([String](), forKey: "messagingBundleIDsV2")
        defaults.set(["com.legacy.chat"], forKey: "messagingBundleIDs")
        let store = KeptAppStore(defaults: defaults)
        XCTAssertEqual(store.bundleIDs, ["com.example.kept"])
    }

    func testMigratesStraightPastV2FoldsV1PinnedDrawerMessaging() {
        // No kept V2 → fold V1 + pinned + drawer + messaging (messaging is now merged in).
        let defaults = makeDefaults()
        defaults.set(["com.v1.kept"], forKey: "keptAppBundleIDs")     // V1
        defaults.set(["com.pin.app"], forKey: "pinnedAppBundleIDs")
        defaults.set(["com.drawer.app", "com.chat.app"], forKey: "drawerBundleIDs")
        defaults.set(["com.chat.app"], forKey: "messagingBundleIDs")  // no V2, the old messaging key is authoritative
        let store = KeptAppStore(defaults: defaults)
        XCTAssertEqual(store.bundleIDs,
                       ["com.v1.kept", "com.pin.app", "com.drawer.app", "com.chat.app"])
    }

    func testMigrationKeepsFinderAndDeduplicates() {
        let defaults = makeDefaults()
        defaults.set(["com.dup", "com.dup", FinderTaskbarPolicy.bundleID], forKey: "keptAppBundleIDs")
        let store = KeptAppStore(defaults: defaults)
        XCTAssertEqual(store.bundleIDs, ["com.dup", FinderTaskbarPolicy.bundleID])
    }

    func testExistingEmptyV3KeyPreventsRemigration() {
        let defaults = makeDefaults()
        defaults.set([String](), forKey: KeptAppStore.defaultsKey)
        defaults.set(["com.example.kept"], forKey: KeptAppStore.previousDefaultsKey)
        defaults.set(["com.chat.app"], forKey: "messagingBundleIDsV2")
        let store = KeptAppStore(defaults: defaults)
        XCTAssertTrue(store.bundleIDs.isEmpty)
    }

    func testMigrationFreezesLegacyKeysReadOnly() {
        // The V3 migration must not delete/overwrite the frozen old keys (clean rollback).
        let defaults = makeDefaults()
        defaults.set(["com.v1.kept"], forKey: "keptAppBundleIDs")
        defaults.set(["com.pin.app"], forKey: "pinnedAppBundleIDs")
        _ = KeptAppStore(defaults: defaults)
        XCTAssertEqual(defaults.stringArray(forKey: "keptAppBundleIDs"), ["com.v1.kept"])
        XCTAssertEqual(defaults.stringArray(forKey: "pinnedAppBundleIDs"), ["com.pin.app"])
    }
}
