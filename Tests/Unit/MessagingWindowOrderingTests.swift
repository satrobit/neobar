import XCTest
@testable import NeoBar

/// #4: a messaging app's popup window lands at the head of the window zone. The head-preferred branch of the pure `StripOrdering.reconcile`,
/// plus consistency of the two real `StripOrderStore` paths (reconciled rendering / sync side effects) (Codex second review #2).
@MainActor
final class MessagingWindowOrderingTests: XCTestCase {

    private final class TimeBox {
        var time: Date
        init(_ time: Date) { self.time = time }
    }

    private func makeStore(timeBox: TimeBox) -> StripOrderStore {
        let suite = "test-msg-order-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return StripOrderStore(defaults: defaults, now: { timeBox.time })
    }

    private let msg: Set<String> = ["com.msg"]

    // MARK: - reconcile pure layer

    func testMessagingWindowNoSiblingGoesHead() {
        let result = StripOrdering.reconcile(
            remembered: ["tabgrp-normal"],
            current: ["tabgrp-normal", "tabgrp-msg"],
            appKeyOf: ["tabgrp-normal": "com.normal", "tabgrp-msg": "com.msg"],
            headPreferredKeys: msg
        )
        XCTAssertEqual(result, ["tabgrp-msg", "tabgrp-normal"])
    }

    func testMultipleMessagingWindowsClusterAtHeadInOrder() {
        let result = StripOrdering.reconcile(
            remembered: ["n1"],
            current: ["n1", "m1", "m2"],
            appKeyOf: ["n1": "com.normal", "m1": "com.msg", "m2": "com.msg"],
            headPreferredKeys: msg
        )
        // m1 lands at the head; m2 has companion m1 -> follows right behind it; their relative order is kept.
        XCTAssertEqual(result, ["m1", "m2", "n1"])
    }

    func testNormalWindowStillGoesEnd() {
        let result = StripOrdering.reconcile(
            remembered: ["m1"],
            current: ["m1", "n1"],
            appKeyOf: ["m1": "com.msg", "n1": "com.normal"],
            headPreferredKeys: msg
        )
        XCTAssertEqual(result, ["m1", "n1"])
    }

    func testRememberedMessagingWindowKeepsPositionNotReHeaded() {
        // m1 was already remembered at the end (the user dragged it); reconciling again doesn't pull it back to the head.
        let result = StripOrdering.reconcile(
            remembered: ["n1", "m1"],
            current: ["n1", "m1"],
            appKeyOf: ["n1": "com.normal", "m1": "com.msg"],
            headPreferredKeys: msg
        )
        XCTAssertEqual(result, ["n1", "m1"])
    }

    // MARK: - StripOrderStore dual paths

    func testStoreNewMessagingWindowLandsHead() {
        let store = makeStore(timeBox: TimeBox(Date()))
        store.sync(current: ["n1"], appKeyOf: ["n1": "com.normal"], headPreferred: msg)
        store.sync(current: ["n1", "m1"],
                   appKeyOf: ["n1": "com.normal", "m1": "com.msg"], headPreferred: msg)
        XCTAssertEqual(store.liveOrder, ["m1", "n1"])
    }

    func testStoreMultipleMessagingWindowsClusterHead() {
        let store = makeStore(timeBox: TimeBox(Date()))
        store.sync(current: ["n1"], appKeyOf: ["n1": "com.normal"], headPreferred: msg)
        store.sync(current: ["n1", "m1", "m2"],
                   appKeyOf: ["n1": "com.normal", "m1": "com.msg", "m2": "com.msg"],
                   headPreferred: msg)
        XCTAssertEqual(store.liveOrder, ["m1", "m2", "n1"])
    }

    func testStoreNormalWindowsUnaffected() {
        let store = makeStore(timeBox: TimeBox(Date()))
        store.sync(current: ["n1"], appKeyOf: ["n1": "com.normal"], headPreferred: msg)
        store.sync(current: ["n1", "n2"],
                   appKeyOf: ["n1": "com.normal", "n2": "com.other"], headPreferred: msg)
        XCTAssertEqual(store.liveOrder, ["n1", "n2"])
    }

    func testStoreDraggedMessagingWindowKeepsPositionOnReappear() {
        let store = makeStore(timeBox: TimeBox(Date()))
        let keys = ["n1": "com.normal", "m1": "com.msg"]
        store.sync(current: ["n1"], appKeyOf: ["n1": "com.normal"], headPreferred: msg)
        store.sync(current: ["n1", "m1"], appKeyOf: keys, headPreferred: msg)
        XCTAssertEqual(store.liveOrder, ["m1", "n1"])
        // The user drags m1 to the right of n1.
        store.reorder(draggedID: "m1", relativeTo: "n1", after: true, current: ["m1", "n1"])
        XCTAssertEqual(store.liveOrder, ["n1", "m1"])
        // Sync again (windows all present) -> m1 is already remembered, stays in place, and isn't moved to the head again.
        store.sync(current: ["n1", "m1"], appKeyOf: keys, headPreferred: msg)
        XCTAssertEqual(store.liveOrder, ["n1", "m1"])
    }

    func testStoreMessagingWindowGraceAbsenceDoesNotReHead() {
        let timeBox = TimeBox(Date())
        let store = makeStore(timeBox: timeBox)
        let keys = ["n1": "com.normal", "m1": "com.msg"]
        store.sync(current: ["n1", "m1"], appKeyOf: keys, headPreferred: msg)
        store.reorder(draggedID: "m1", relativeTo: "n1", after: true, current: ["m1", "n1"])
        XCTAssertEqual(store.liveOrder, ["n1", "m1"])
        // m1 vanishes briefly (within grace) -> rank is kept.
        timeBox.time = timeBox.time.addingTimeInterval(1)
        store.sync(current: ["n1"], appKeyOf: ["n1": "com.normal"], headPreferred: msg)
        XCTAssertEqual(store.liveOrder, ["n1", "m1"])
        // Returns -> still in place, not moved to the head again.
        timeBox.time = timeBox.time.addingTimeInterval(1)
        store.sync(current: ["n1", "m1"], appKeyOf: keys, headPreferred: msg)
        XCTAssertEqual(store.liveOrder, ["n1", "m1"])
    }

    /// Core of Codex second review #2: the rendering path reconciled and the side-effect path sync must use the same headPreferred,
    /// otherwise the head is wrong on the first frame and jumps after sync. Both paths give the same result for the same new messaging window.
    func testReconciledMatchesSyncForNewMessagingWindow() {
        let store = makeStore(timeBox: TimeBox(Date()))
        store.sync(current: ["n1"], appKeyOf: ["n1": "com.normal"], headPreferred: msg)
        let keys = ["n1": "com.normal", "m1": "com.msg"]
        let rendered = store.reconciled(current: ["n1", "m1"], appKeyOf: keys, headPreferred: msg)
        store.sync(current: ["n1", "m1"], appKeyOf: keys, headPreferred: msg)
        XCTAssertEqual(rendered, ["m1", "n1"])
        XCTAssertEqual(store.liveOrder, rendered)
    }

    /// Boundary of the shadow-slide fix for the messaging zone: a messaging window with a remembered position (dragged) that closes within grace and is replaced by a **new** seat
    /// inherits the old rank on the first frame and isn't moved to the head again because of headPreferred (pre-sync and post-sync agree).
    /// A brand-new messaging window with no memory still goes to the head, covered by `testStoreNewMessagingWindowLandsHead` /
    /// `testReconciledMatchesSyncForNewMessagingWindow`.
    func testMessagingNewWindowWithinGraceInheritsRankNotReHead() {
        let timeBox = TimeBox(Date())
        let store = makeStore(timeBox: timeBox)
        let keys = ["n1": "com.normal", "m1": "com.msg"]
        store.sync(current: ["n1", "m1"], appKeyOf: keys, headPreferred: msg)
        XCTAssertEqual(store.liveOrder, ["m1", "n1"])
        // The user drags m1 to the right of n1 -> remembers [n1, m1]
        store.reorder(draggedID: "m1", relativeTo: "n1", after: true, current: ["m1", "n1"])
        XCTAssertEqual(store.liveOrder, ["n1", "m1"])
        // m1 closes (stamped within grace)
        timeBox.time = timeBox.time.addingTimeInterval(1)
        store.sync(current: ["n1"], appKeyOf: ["n1": "com.normal"], headPreferred: msg)
        XCTAssertEqual(store.liveOrder, ["n1", "m1"])
        // Within grace a new window m2 replaces it: first-frame render (sync hasn't run) -> inherits m1's old position (right of n1), no move to the head
        timeBox.time = timeBox.time.addingTimeInterval(1)
        let newKeys = ["n1": "com.normal", "m2": "com.msg"]
        let firstFrame = store.reconciled(current: ["n1", "m2"], appKeyOf: newKeys, headPreferred: msg)
        XCTAssertEqual(firstFrame, ["n1", "m2"])   // Not ["m2", "n1"]
        store.sync(current: ["n1", "m2"], appKeyOf: newKeys, headPreferred: msg)
        let postSync = store.reconciled(current: ["n1", "m2"], appKeyOf: newKeys, headPreferred: msg)
        XCTAssertEqual(firstFrame, postSync)
    }
}
