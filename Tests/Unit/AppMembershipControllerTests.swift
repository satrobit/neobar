import XCTest
@testable import NeoBar

@MainActor
final class AppMembershipControllerTests: XCTestCase {

    private var kept: KeptAppStore!
    private var drawer: DrawerStore!
    private var messaging: MessagingAppStore!
    private var controller: AppMembershipController!

    private func makeDefaults() -> UserDefaults {
        let suite = "test-membership-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    override func setUp() {
        super.setUp()
        let defaults = makeDefaults()
        kept = KeptAppStore(defaults: defaults)
        drawer = DrawerStore(defaults: defaults)
        messaging = MessagingAppStore(defaults: defaults)
        controller = AppMembershipController(
            keptAppStore: kept,
            drawerStore: drawer,
            messagingStore: messaging
        )
    }

    // MARK: - applyDragLanding (a stash settles and checks kept; re-enabled on every drag-in)

    func testApplyDragLandingEnablesKeptOnlyWhenEndedInDrawerFromStripOrMessaging() {
        for source in [DragSource.strip, .drawer, .folder, .messaging] {
            for endedInDrawer in [true, false] {
                let defaults = makeDefaults()
                let kept = KeptAppStore(defaults: defaults)
                let drawer = DrawerStore(defaults: defaults)
                let messaging = MessagingAppStore(defaults: defaults)
                let controller = AppMembershipController(keptAppStore: kept, drawerStore: drawer, messagingStore: messaging)
                if endedInDrawer { drawer.add("com.example.app") }
                controller.applyDragLanding(bundleID: "com.example.app", originSource: source)
                let expected = endedInDrawer && (source == .strip || source == .messaging)
                XCTAssertEqual(kept.contains("com.example.app"), expected, "source=\(source) endedInDrawer=\(endedInDrawer)")
                XCTAssertEqual(drawer.contains("com.example.app"), endedInDrawer, "落定补勾不得改 drawer")
            }
        }
    }

    func testApplyDragLandingReEnablesKeptAfterManualUncheck() {
        drawer.add("com.example.app")
        controller.applyDragLanding(bundleID: "com.example.app", originSource: .strip)
        XCTAssertTrue(kept.contains("com.example.app"))
        controller.setKept("com.example.app", enabled: false)
        XCTAssertFalse(kept.contains("com.example.app"))
        controller.applyDragLanding(bundleID: "com.example.app", originSource: .messaging)
        XCTAssertTrue(kept.contains("com.example.app"), "不是一次性播种：再次拖入重新打开")
    }

    // MARK: - setKept (kept changes only kept, and may coexist with messaging)

    func testSetKeptAddsWithoutChangingDrawerPlacement() {
        drawer.add("com.example.app")
        controller.setKept("com.example.app", enabled: true)
        XCTAssertTrue(kept.contains("com.example.app"))
        XCTAssertTrue(drawer.contains("com.example.app"))
    }

    func testSetKeptCoexistsWithMessagingIdentity() {
        messaging.mark("com.example.app")
        controller.setKept("com.example.app", enabled: true)
        XCTAssertTrue(kept.contains("com.example.app"))
        XCTAssertTrue(messaging.contains("com.example.app"))
    }

    /// Reversed 2026-08-20: Finder also goes through the unified "Keep in Dock"; it is checked by default via seeding, and can be unchecked and checked again.
    func testSetKeptAcceptsFinderBothWays() {
        let finder = FinderTaskbarPolicy.bundleID
        XCTAssertTrue(kept.contains(finder), "新建 store 应已把访达播种为已保留")
        controller.setKept(finder, enabled: false)
        XCTAssertFalse(kept.contains(finder))
        controller.setKept(finder, enabled: true)
        XCTAssertTrue(kept.contains(finder))
    }

    func testMoveToDrawerAcceptsFinder() {
        let finder = FinderTaskbarPolicy.bundleID
        controller.moveToDrawer(finder)
        XCTAssertTrue(drawer.contains(finder))
    }

    func testUnsetKeptLeavesDrawerPlacementAndMessagingUntouched() {
        controller.setKept("com.example.app", enabled: true)
        drawer.add("com.example.app")
        messaging.mark("com.example.app")
        controller.setKept("com.example.app", enabled: false)
        XCTAssertFalse(kept.contains("com.example.app"))
        XCTAssertTrue(drawer.contains("com.example.app"))
        XCTAssertTrue(messaging.contains("com.example.app"))
    }

    func testMoveToDrawerPreservesKept() {
        controller.setKept("com.example.app", enabled: true)
        controller.moveToDrawer("com.example.app")
        XCTAssertTrue(kept.contains("com.example.app"))
        XCTAssertTrue(drawer.contains("com.example.app"))
    }

    // MARK: - markMessaging (adds kept on first join, never changes drawer)

    func testMarkMessagingFirstJoinSeedsKeptAndKeepsDrawer() {
        drawer.add("com.example.app")
        controller.markMessaging("com.example.app")
        XCTAssertTrue(messaging.contains("com.example.app"))
        XCTAssertTrue(kept.contains("com.example.app"))     // Add kept on first join
        XCTAssertTrue(drawer.contains("com.example.app"))   // placement unchanged
    }

    func testMarkMessagingAgainDoesNotReopenUserRemovedKept() {
        controller.markMessaging("com.example.app")            // First time -> add kept
        controller.setKept("com.example.app", enabled: false)  // The user unchecks keep
        controller.markMessaging("com.example.app")            // Already a member -> do not add again
        XCTAssertTrue(messaging.contains("com.example.app"))
        XCTAssertFalse(kept.contains("com.example.app"))
    }

    /// Finder can be kept and can enter the drawer, but still cannot enter the messaging area.
    func testMarkMessagingRejectsFinder() {
        let finder = FinderTaskbarPolicy.bundleID
        controller.markMessaging(finder)
        XCTAssertFalse(messaging.contains(finder))
    }

    // MARK: - autoRegisterMessaging (adds kept on first recognition, scanning does not reopen)

    func testAutoRegisterMessagingSeedsKeptForNewMembers() {
        let chat = "com.tencent.xinWeChat"   // builtin whitelist
        controller.autoRegisterMessaging(runningBundleIDs: [chat],
                                         mainWindowIdentifiableBundleIDs: [chat])
        XCTAssertTrue(messaging.contains(chat))
        XCTAssertTrue(kept.contains(chat))
    }

    func testAutoRegisterMessagingDoesNotReopenUserRemovedKept() {
        let chat = "com.tencent.xinWeChat"
        // First seen -> add kept
        controller.autoRegisterMessaging(runningBundleIDs: [chat],
                                         mainWindowIdentifiableBundleIDs: [chat])
        controller.setKept(chat, enabled: false)                   // The user unchecks keep
        // Scan again -> already a member
        controller.autoRegisterMessaging(runningBundleIDs: [chat],
                                         mainWindowIdentifiableBundleIDs: [chat])
        XCTAssertTrue(messaging.contains(chat))
        XCTAssertFalse(kept.contains(chat))
    }

    func testAutoRegisterMessagingSkipsAppWithoutIdentifiableMainWindow() {
        // Apps like Messages whose main window can never be recognized do not enter the messaging area, so kept is not added either.
        let messages = "com.apple.MobileSMS"  // builtin whitelist
        controller.autoRegisterMessaging(runningBundleIDs: [messages],
                                         mainWindowIdentifiableBundleIDs: [])
        XCTAssertFalse(messaging.contains(messages))
        XCTAssertFalse(kept.contains(messages))
    }

    // MARK: - unmarkMessaging (clears only the messaging identity, keeps kept + drawer)

    func testUnmarkMessagingKeepsKeptAndDrawer() {
        controller.markMessaging("com.example.app") // messaging + kept
        drawer.add("com.example.app")
        controller.unmarkMessaging("com.example.app")
        XCTAssertFalse(messaging.contains("com.example.app"))
        XCTAssertTrue(kept.contains("com.example.app"))
        XCTAssertTrue(drawer.contains("com.example.app"))
    }

    func testMessagingMenuDescriptorRoundTripPreservesAsymmetricSemantics() throws {
        let bundleID = "com.example.app"
        drawer.add(bundleID)

        let unchecked = try XCTUnwrap(LauncherMembershipItem.items(
            surface: .strip,
            bundleID: bundleID,
            isKept: false,
            isMessaging: false,
            controller: controller
        ).last)
        XCTAssertEqual(unchecked.label, String(localized: "Pin to Left Side of Taskbar"))
        XCTAssertEqual(unchecked.isChecked, false)
        unchecked.action()
        XCTAssertTrue(messaging.contains(bundleID))
        XCTAssertTrue(kept.contains(bundleID), "首次标记仍应补 kept")
        XCTAssertTrue(drawer.contains(bundleID), "标记不改变 drawer placement")

        let checked = try XCTUnwrap(LauncherMembershipItem.items(
            surface: .drawer,
            bundleID: bundleID,
            isKept: true,
            isMessaging: true,
            controller: controller
        ).last)
        XCTAssertEqual(checked.label, String(localized: "Pin to Left Side of Taskbar"))
        XCTAssertEqual(checked.isChecked, true)
        checked.action()
        XCTAssertFalse(messaging.contains(bundleID))
        XCTAssertTrue(kept.contains(bundleID), "取消标记不改变 kept")
        XCTAssertTrue(drawer.contains(bundleID), "取消标记不改变 drawer placement")
    }

    // MARK: - reconcileInvalidMemberships (clears only Finder's messaging identity)

    /// Runs on every launch: it may only clear the messaging identity. Clearing the drawer would wipe out the Finder the user dragged in themselves (2026-08-20).
    func testReconcileClearsOnlyFinderMessagingAndKeepsDrawerPlacement() {
        let finder = FinderTaskbarPolicy.bundleID
        drawer.add(finder)
        messaging.mark(finder)
        controller.reconcileInvalidMemberships()
        XCTAssertTrue(drawer.contains(finder))
        XCTAssertFalse(messaging.contains(finder))
    }

    func testReconcilePreservesKeptMessagingOverlap() {
        controller.setKept("com.example.app", enabled: true)
        messaging.mark("com.example.app")
        controller.reconcileInvalidMemberships()
        XCTAssertTrue(kept.contains("com.example.app"))
        XCTAssertTrue(messaging.contains("com.example.app"))
    }

    // MARK: - DrawerStore migration

    func testDrawerStoreMigratesLaunchFavoriteKey() {
        let defaults = makeDefaults()
        defaults.set(["com.example.fav1", "com.example.fav2"], forKey: "launchFavoriteBundleIDs")
        defaults.set(["com.example.existing"], forKey: "drawerBundleIDs")
        let migrated = DrawerStore(defaults: defaults)
        XCTAssertTrue(migrated.contains("com.example.fav1"))
        XCTAssertTrue(migrated.contains("com.example.fav2"))
        XCTAssertTrue(migrated.contains("com.example.existing"))
        XCTAssertNil(defaults.stringArray(forKey: "launchFavoriteBundleIDs"))
    }
}
