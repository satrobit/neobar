import XCTest
@testable import NeoBar

@MainActor
final class PinnedFolderStoreTests: XCTestCase {

    private func makeDefaults() -> UserDefaults {
        let suite = "test-pinned-folders-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private let downloads = URL(fileURLWithPath: "/Users/example/Downloads")

    // MARK: - Downloads on a fresh install (owner 2026-10-11: back in, like the native Dock)

    func testFreshInstallPinsDownloadsAsUnopenedSeed() {
        let defaults = makeDefaults()
        let store = PinnedFolderStore(defaults: defaults)
        store.seedDownloadsForFreshInstall(lineage: .pristine, downloadsURL: downloads)
        XCTAssertEqual(store.folderPaths, [downloads.path])
        XCTAssertTrue(store.isUnopenedSeed(downloads.path),
                      "the seed must stay unread until the user opens it, or launch raises the Downloads access prompt")
        // Both survive a relaunch.
        let relaunched = PinnedFolderStore(defaults: defaults)
        XCTAssertEqual(relaunched.folderPaths, [downloads.path])
        XCTAssertTrue(relaunched.isUnopenedSeed(downloads.path))
    }

    func testUpgraderIsNeverSeeded() {
        let store = PinnedFolderStore(defaults: makeDefaults())
        store.seedDownloadsForFreshInstall(lineage: .priorUse, downloadsURL: downloads)
        XCTAssertTrue(store.folderPaths.isEmpty)
        XCTAssertFalse(store.isUnopenedSeed(downloads.path))
    }

    func testExistingPinnedListIsLeftAlone() {
        let defaults = makeDefaults()
        defaults.set(["/Users/example/Projects"], forKey: "pinnedFolderPaths")
        let store = PinnedFolderStore(defaults: defaults)
        store.seedDownloadsForFreshInstall(lineage: .pristine, downloadsURL: downloads)
        XCTAssertEqual(store.folderPaths, ["/Users/example/Projects"])
    }

    func testOpeningTheSeedClearsItOnce() {
        let store = PinnedFolderStore(defaults: makeDefaults())
        store.seedDownloadsForFreshInstall(lineage: .pristine, downloadsURL: downloads)
        XCTAssertTrue(store.noteOpened(downloads.path))
        XCTAssertFalse(store.isUnopenedSeed(downloads.path))
        XCTAssertFalse(store.noteOpened(downloads.path))
    }

    func testUnpinningTheSeedForgetsIt() {
        let defaults = makeDefaults()
        let store = PinnedFolderStore(defaults: defaults)
        store.seedDownloadsForFreshInstall(lineage: .pristine, downloadsURL: downloads)
        store.remove(downloads.path)
        XCTAssertTrue(store.folderPaths.isEmpty)
        XCTAssertFalse(store.isUnopenedSeed(downloads.path))
        XCTAssertEqual(defaults.stringArray(forKey: "pinnedFolderUnopenedSeeds"), [])
    }

    // MARK: - View content as

    func testViewModeDefaultsToAutomaticAndPersistsPerFolder() {
        let defaults = makeDefaults()
        let store = PinnedFolderStore(defaults: defaults)
        store.add("/Users/example/Projects")
        XCTAssertEqual(store.viewMode(for: "/Users/example/Projects"), .automatic)
        store.setViewMode(.list, for: "/Users/example/Projects/")
        XCTAssertEqual(PinnedFolderStore(defaults: defaults).viewMode(for: "/Users/example/Projects"), .list)
    }

    func testUnpinningForgetsTheViewMode() {
        let defaults = makeDefaults()
        let store = PinnedFolderStore(defaults: defaults)
        store.add("/Users/example/Projects")
        store.setViewMode(.fan, for: "/Users/example/Projects")
        store.remove("/Users/example/Projects")
        XCTAssertTrue(store.viewModes.isEmpty)
        XCTAssertEqual(defaults.dictionary(forKey: "pinnedFolderViewModes") as? [String: String], [:])
    }
}
