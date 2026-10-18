import XCTest
@testable import NeoBar

@MainActor
final class DrawerOrderStoreTests: XCTestCase {

    private func makeDefaults() -> UserDefaults {
        let suite = "test-drawer-order-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testReorderOperatesOnFullOrderAndKeepsHiddenMembersRelative() {
        let store = DrawerOrderStore(defaults: makeDefaults())
        store.sync(members: ["a", "hidden-1", "hidden-2", "b"])

        store.reorder(draggedID: "a", relativeTo: "b", after: true)

        XCTAssertEqual(store.order, ["hidden-1", "hidden-2", "b", "a"])
    }

    func testReorderPersistsAcrossReload() {
        let defaults = makeDefaults()
        let store = DrawerOrderStore(defaults: defaults)
        store.sync(members: ["a", "hidden", "b"])
        store.reorder(draggedID: "b", relativeTo: "a", after: false)

        let reloaded = DrawerOrderStore(defaults: defaults)
        XCTAssertEqual(reloaded.order, ["b", "a", "hidden"])
    }
}
