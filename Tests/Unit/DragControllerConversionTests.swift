import AppKit
import Combine
import XCTest

/// Full matrix of the cross-panel conversion state machine: convert/rollback/settle/cancel (Codex review 2026-07-11 P2-6).
/// Drives DragController itself with a real store (temporary UserDefaults) + a fixed drop-zone stub (compiled locally into the test
/// target, consistent with the store); geometric triggers (when the pointer enters/leaves a zone) belong to the view layer, so here we only verify membership and payload before and after each conversion action.
@MainActor
final class DragControllerConversionTests: XCTestCase {

    private var drawer: DrawerStore!
    private var kept: KeptAppStore!
    private var messaging: MessagingAppStore!
    private var membership: AppMembershipController!
    private var controller: DragController!
    /// Fixed drop zone: hit-testing only looks at the beginDrag start coordinate.
    private let dropZone = CGRect(x: 0, y: 0, width: 100, height: 100)
    private let insideZone = CGPoint(x: 50, y: 50)
    private let outsideZone = CGPoint(x: 500, y: 500)

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared   // Start AppKit before creating an NSPanel in a test bundle that has no host app
        let suite = "test-dragconv-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        drawer = DrawerStore(defaults: defaults)
        kept = KeptAppStore(defaults: defaults)
        messaging = MessagingAppStore(defaults: defaults)
        membership = AppMembershipController(keptAppStore: kept, drawerStore: drawer, messagingStore: messaging)
        controller = DragController(
            drawerStore: drawer,
            messagingStore: messaging,
            membershipController: membership,
            dropZonesProvider: { [dropZone] _ in [dropZone] },
            screensProvider: { NSScreen.screens }
        )
    }

    override func tearDown() {
        controller.cancelDrag()   // Idempotent cleanup, so panels/monitors don't leak into the next case
        super.tearDown()
    }

    private func payload(_ source: DragSource, _ bid: String) -> DragPayload {
        DragPayload(source: source, id: bid, bundleID: bid, item: nil,
                    visualKind: .drawerIcon, canExternalDrop: true)
    }

    /// A drag must carry a carrier bitmap (no bitmap, no drag; see `DragController.beginDrag`).
    /// These cases verify membership and payload, so what the bitmap shows doesn't matter; a 1×1 one is enough.
    private func stubSnapshot(side: Int = 1) -> CarrierSnapshot {
        let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 4 * side,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return CarrierSnapshot(image: context.makeImage()!,
                               size: CGSize(width: side, height: side),
                               contentSize: CGSize(width: side, height: side),
                               scale: 1)
    }

    private func begin(_ source: DragSource, _ bid: String, at point: CGPoint, surface: String? = nil) {
        controller.beginDrag(payload: payload(source, bid), stripSurfaceID: surface, startScreenLocation: point,
                             grabOffset: .zero, sourceScreenRect: .zero, pose: .resting,
                             snapshot: stubSnapshot())
    }

    /// Wait a short real-time interval (spinning the run loop), for time-based deferrals like `DragLandingPlan.pickUpSettle`.
    private func settle(_ seconds: TimeInterval) {
        let until = Date(timeIntervalSinceNow: seconds)
        while Date() < until {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005))
        }
    }

    /// Spin the run loop until the condition holds (at most `timeout`). Use it for the time-deferred steps instead of betting on a fixed wait.
    private func waitUntil(_ timeout: TimeInterval = 1, _ condition: () -> Bool) {
        let until = Date(timeIntervalSinceNow: timeout)
        while !condition() && Date() < until {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005))
        }
    }

    // MARK: - Active strip surface (multi-display 3/4: of several strips with identical content, only one can write back)

    func testStripSurfaceClaimClearsOnCancelAndOnRevert() {
        begin(.strip, "com.example.a", at: outsideZone, surface: "strip-A")
        XCTAssertEqual(controller.activeStripSurfaceID, "strip-A")
        controller.cancelDrag()
        XCTAssertNil(controller.activeStripSurfaceID, "取消 = 拖动结束，认领必须清空，否则下一次抽屉起拖没人能转正")

        drawer.add("com.example.b")
        begin(.drawer, "com.example.b", at: outsideZone)
        XCTAssertNil(controller.activeStripSurfaceID, "抽屉起拖尚未转正：没人认领，哪条 strip 含着指针都可以转正")
        controller.claimStripSurface("strip-B")
        controller.convertDrawerToStrip()
        XCTAssertEqual(controller.activeStripSurfaceID, "strip-B")
        controller.revertDrawerToStrip()
        XCTAssertNil(controller.activeStripSurfaceID, "撤销转正即放手认领")
        controller.cancelDrag()
    }

    /// A drawer messaging app released into the messaging zone takes a different path (`convertDrawerToMessaging`); claim / release must match:
    /// if release is missed, after an undo the pointer entering another strip's messaging zone leaves nobody able to release; if claim is missed, the two strips undo each other every tick.
    func testDrawerToMessagingClaimClearsOnRevert() {
        messaging.mark("chat"); drawer.add("chat")
        begin(.drawer, "chat", at: outsideZone)
        controller.claimStripSurface("strip-B")
        controller.convertDrawerToMessaging()
        XCTAssertEqual(controller.activeStripSurfaceID, "strip-B")
        controller.revertDrawerToMessaging()
        XCTAssertNil(controller.activeStripSurfaceID, "撤销释放即放手认领")
        controller.cancelDrag()
    }

    // MARK: - Collapse on drag-out (owner 2026-09-03: card leaves the strip -> the gap closes and the strip shortens; it makes room again on return)

    func testLeavingTheStripCollapsesTheSlotAndEnteringRestoresIt() {
        begin(.strip, "com.example.a", at: outsideZone, surface: "strip-A")
        XCTAssertFalse(controller.stripSlotCollapsed, "起拖那一刻还在条上")
        controller.noteStripLeft(surfaceID: "strip-A")
        XCTAssertTrue(controller.stripSlotCollapsed)
        controller.noteStripEntered(surfaceID: "strip-A", displayUUID: nil)
        XCTAssertFalse(controller.stripSlotCollapsed)
        controller.cancelDrag()
    }

    /// Only the claimed strip's hit frame counts; the claim is decided by the display the pointer is on (`claimStripSurface`), and entering/leaving a frame doesn't hand it over
    /// (owner 2026-09-03: dragging to display B lands on strip B, without requiring the pointer to press into B's frame).
    func testOnlyTheClaimedStripDecidesAndClaimFollowsTheScreenNotTheBox() {
        begin(.strip, "com.example.a", at: outsideZone, surface: "strip-A")
        controller.noteStripLeft(surfaceID: "strip-B")
        XCTAssertFalse(controller.stripSlotCollapsed, "B 没认领，它的框不算")
        controller.noteStripLeft(surfaceID: "strip-A")
        XCTAssertTrue(controller.stripSlotCollapsed)
        controller.noteStripEntered(surfaceID: "strip-B", displayUUID: "display-B")
        XCTAssertEqual(controller.activeStripSurfaceID, "strip-A", "进框不换手")
        XCTAssertTrue(controller.stripSlotCollapsed, "B 没认领，进它的框不重开")
        controller.claimStripSurface("strip-B", displayUUID: "display-B")   // The pointer reached display B
        controller.noteStripEntered(surfaceID: "strip-B", displayUUID: "display-B")
        XCTAssertFalse(controller.stripSlotCollapsed, "认领的 B 条让位")
        controller.noteStripLeft(surfaceID: "strip-B")
        XCTAssertEqual(controller.activeStripSurfaceID, "strip-B", "出框也不交还：指针还在 B 屏")
        XCTAssertTrue(controller.stripSlotCollapsed)
        controller.cancelDrag()
    }

    /// A messaging chip doesn't cross strips: entering another strip doesn't count as coming back.
    func testMessagingChipOnlyRestoresOnItsOwnStrip() {
        messaging.mark("chat")
        begin(.messaging, "chat", at: outsideZone, surface: "strip-A")
        controller.noteStripLeft(surfaceID: "strip-A")
        XCTAssertTrue(controller.stripSlotCollapsed)
        controller.noteStripEntered(surfaceID: "strip-B", displayUUID: nil)
        XCTAssertTrue(controller.stripSlotCollapsed, "别的条不算")
        XCTAssertEqual(controller.activeStripSurfaceID, "strip-A", "消息 chip 不换手")
        controller.noteStripEntered(surfaceID: "strip-A", displayUUID: nil)
        XCTAssertFalse(controller.stripSlotCollapsed)
        controller.cancelDrag()
    }

    /// Entering the drawer body counts as converting = leaving the strip; after undoing the conversion it stays collapsed until the strip's hit frame says it's back.
    func testConvertingIntoTheDrawerCollapsesAndRevertKeepsItCollapsed() {
        begin(.strip, "com.example.a", at: outsideZone, surface: "strip-A")
        controller.convertStripToDrawer()
        XCTAssertTrue(controller.stripSlotCollapsed)
        controller.noteStripEntered(surfaceID: "strip-A", displayUUID: nil)
        XCTAssertTrue(controller.stripSlotCollapsed, "转换期间条的判定框不作数")
        controller.revertStripFromDrawer()
        XCTAssertTrue(controller.stripSlotCollapsed)
        controller.noteStripEntered(surfaceID: "strip-A", displayUUID: nil)
        XCTAssertFalse(controller.stripSlotCollapsed)
        controller.cancelDrag()
    }

    /// Release outside the strip and outside a drop zone: the slot reopens first, and the card flies toward the last known slot position (the slot frame can't be reported at this moment).
    func testDesktopReleaseReopensTheSlotAndFliesToTheLastKnownSlot() {
        begin(.strip, "com.example.a", at: outsideZone, surface: "strip-A")
        controller.setLandingAnchor(CGRect(x: 400, y: 400, width: 40, height: 54), owner: .strip)
        controller.noteStripLeft(surfaceID: "strip-A")
        controller.setLandingAnchor(nil, owner: .strip)   // After collapsing, the strip can't report a slot position
        controller.endDrag()
        XCTAssertFalse(controller.stripSlotCollapsed, "松手即重开槽")
        XCTAssertNotNil(controller.landing, "有最后已知槽位就飞，不瞬移")
        XCTAssertEqual(controller.landing?.kind, .returnToSlot)
        controller.cancelDrag()
    }

    /// Release on the drop zone (capsule) = stash: the slot doesn't reopen and the strip stays narrow until the landing cleanup resets it to zero.
    func testStashReleaseKeepsTheSlotCollapsedUntilLanding() {
        let stashing = makeStashingController()
        defer { stashing.cancelDrag() }
        stashing.beginDrag(payload: payload(.strip, "app"), stripSurfaceID: "strip-A",
                           startScreenLocation: insideZone, grabOffset: .zero, sourceScreenRect: .zero,
                           pose: .resting, snapshot: stubSnapshot())
        waitUntil { stashing.hiddenSlotPayload != nil }
        stashing.noteStripLeft(surfaceID: "strip-A")
        XCTAssertTrue(stashing.stripSlotCollapsed)
        stashing.endDrag()
        XCTAssertTrue(drawer.contains("app"))
        XCTAssertEqual(stashing.landing?.kind, .stash)
        XCTAssertTrue(stashing.stripSlotCollapsed, "吸进胶囊途中槽不重开")
        stashing.abortLanding()
        XCTAssertFalse(stashing.stripSlotCollapsed, "落地收尾归零")
    }

    func testCancelReopensTheSlot() {
        begin(.strip, "com.example.a", at: outsideZone, surface: "strip-A")
        controller.noteStripLeft(surfaceID: "strip-A")
        controller.cancelDrag()
        XCTAssertFalse(controller.stripSlotCollapsed)
    }

    // MARK: - Handoff order at drag start / landing (both ends must be "new first, old second")

    /// **On the drag-start frame, the card on the strip must not hide first (when there is no prepared candidate).**
    ///
    /// The carrier is a freshly captured bitmap whose first frame has to wait for a texture upload; measured, it is always one display frame later than SwiftUI hiding the card
    /// (2026-08-19 frame-by-frame recording: in three consecutive drags, every one showed a frame at the same phase with "slot already empty, carrier not yet on screen").
    /// So when not warmed up, `beginDrag` only places the carrier at the slot's original position on that turn, and **after two display frames** (by time, not by run-loop turns
    /// -- on real hardware mouse events arrive every 1ms, and the next turn is often still in the same frame) it hides the card + lifts the carrier at the same time.
    func testSlotStaysFilledUntilTheCarrierHasHadAFrame() {
        begin(.strip, "app", at: outsideZone)
        XCTAssertNotNil(controller.draggingPayload, "拖动本身立刻开始")
        XCTAssertNil(controller.hiddenSlotPayload, "但这一轮条上那格还不能空")
        XCTAssertTrue(controller.hoverFrozen, "这几帧悬停原地冻结，卡不能变形")

        // One more run-loop turn is not enough -- that is exactly why the first version showed a one-frame gap.
        let nextTurn = expectation(description: "下一轮 run loop")
        DispatchQueue.main.async { nextTurn.fulfill() }
        wait(for: [nextTurn], timeout: 1)
        XCTAssertNil(controller.hiddenSlotPayload, "下一轮 run loop 仍不放行")

        waitUntil { controller.hiddenSlotPayload != nil }
        XCTAssertEqual(controller.hiddenSlotPayload?.bundleID, "app", "两个显示帧后才空出来")
        XCTAssertFalse(controller.hoverFrozen)
        XCTAssertTrue(controller.hoverSuppressed, "藏卡之后悬停改为压制")
    }

    /// **A candidate was prepared on mouse-down -> release on the drag-start turn itself**: the texture is already uploaded, so lighting up the carrier and hiding the card happen in the same commit.
    func testPreparedCandidateArmsImmediately() {
        let slot = CGRect(x: 100, y: 10, width: 40, height: 54)
        controller.prepareCandidate(payloadID: "app", sourceScreenRect: slot, snapshot: stubSnapshot())
        controller.beginDrag(payload: payload(.strip, "app"), startScreenLocation: outsideZone,
                             grabOffset: .zero, sourceScreenRect: slot, pose: .resting,
                             snapshot: nil)   // If there is a candidate, no further capture should happen: passing nil here must still start the drag
        XCTAssertNotNil(controller.draggingPayload)
        XCTAssertEqual(controller.hiddenSlotPayload?.bundleID, "app", "当轮就藏卡")
        XCTAssertFalse(controller.hoverFrozen)
        XCTAssertTrue(controller.hoverSuppressed)
    }

    /// Candidate doesn't match (a different card was pressed) -> it can't be passed off as the candidate; take the no-candidate path.
    func testMismatchedCandidateIsIgnored() {
        let slot = CGRect(x: 100, y: 10, width: 40, height: 54)
        controller.prepareCandidate(payloadID: "other", sourceScreenRect: slot, snapshot: stubSnapshot())
        begin(.strip, "app", at: outsideZone)
        XCTAssertNotNil(controller.draggingPayload)
        XCTAssertNil(controller.hiddenSlotPayload, "没有匹配的候选 → 仍要先压着卡")
    }

    /// Released without starting a drag -> the candidate is withdrawn, so a later drag doesn't misuse it.
    func testClearedCandidateDoesNotArmImmediately() {
        let slot = CGRect(x: 100, y: 10, width: 40, height: 54)
        controller.prepareCandidate(payloadID: "app", sourceScreenRect: slot, snapshot: stubSnapshot())
        controller.clearCandidate(payloadID: "app")
        begin(.strip, "app", at: outsideZone)
        XCTAssertNil(controller.hiddenSlotPayload)
    }

    /// The landing end is **the reverse**: as soon as `landing` clears, the card should show, and the carrier retires one turn later.
    /// The two ends are asymmetric, so `hiddenSlotPayload` can't simply equal `carriedPayload`.
    func testLandingSideIsNotGatedTheSameWay() {
        begin(.strip, "app", at: outsideZone)
        waitUntil { controller.hiddenSlotPayload != nil }
        XCTAssertNotNil(controller.hiddenSlotPayload)

        controller.endDrag()
        // No landing anchor -> hold in place and wait for the anchor (`DragLandingPlan.holdingFlight`); if the anchor still hasn't arrived when the hold period expires
        // -> settle directly: `landing` clears, the card shows on that turn, and the carrier retires one turn later.
        XCTAssertEqual(controller.landing?.flight.isStationary, true, "没锚点先原地按住，不瞬时收尾")
        waitUntil(1) { controller.landing == nil }
        XCTAssertNil(controller.landing, "锚点始终没来 → 按住期一到就落定")
        XCTAssertNil(controller.hiddenSlotPayload, "不飞的收尾也要立刻让卡显形")
        XCTAssertTrue(controller.isCarrying, "但载体还没撤，悬停仍要压着")
    }

    /// Cross-display window drag (3/4): after the claim changes hands, **the old strip's slot memory is void** -- releasing in an empty spot on display B must not fly toward A strip's old slot
    /// (the carrier panel would switch to display A and the icon vanish from display B, owner 2026-09-03). On release it first holds in place; once strip B reports a real anchor,
    /// the whole flight is replaced with one toward it.
    func testClaimHandoverForgetsTheOldSlotAndWaitsForTheNewStripsAnchor() {
        begin(.strip, "com.example.a", at: outsideZone, surface: "strip-A")
        controller.setLandingAnchor(CGRect(x: 400, y: 400, width: 40, height: 54), owner: .strip)
        controller.noteStripLeft(surfaceID: "strip-A")
        controller.setLandingAnchor(nil, owner: .strip)   // After A collapses, it can't report a slot position
        controller.claimStripSurface("strip-B", displayUUID: "display-B")   // The pointer reached display B
        controller.endDrag()
        XCTAssertFalse(controller.stripSlotCollapsed, "松手即重开槽（在 B 条上）")
        guard let held = controller.landing else { return XCTFail("要有一段原地按住的飞行") }
        XCTAssertEqual(held.kind, .returnToSlot)
        XCTAssertTrue(held.flight.isStationary, "不认 A 条的旧槽位")
        // Strip B reports a real anchor on its next commit -> replace the whole flight during the hold period
        controller.setLandingAnchor(CGRect(x: outsideZone.x + 200, y: outsideZone.y, width: 40, height: 54),
                                    owner: .strip)
        guard let flying = controller.landing else { return XCTFail("锚点来了还得在飞") }
        XCTAssertFalse(flying.flight.isStationary, "换成朝 B 条那格的飞行")
        XCTAssertEqual(flying.token, held.token, "同一次落地，不是新的一次")
        controller.cancelDrag()
    }

    /// **After landing, that card's hover must be held** until the pointer actually moves: the card has just come to rest at 1.0 and re-evaluating hover immediately,
    /// the quiet tier would grow it to 1.10 on the spot (owner 2026-08-19 "landing jitter"). Here the pointer doesn't move, so the hold stays throughout.
    ///
    /// What is held is **that single card**, not the whole task strip -- see the next case.
    func testHoverStaysHeldAfterLandingUntilThePointerMoves() {
        begin(.strip, "app", at: outsideZone)
        waitUntil { controller.hiddenSlotPayload != nil }
        controller.endDrag()
        // No anchor -> hold in place first and wait for the anchor (34ms); landing only happens after the hold period, and the hold starts from the moment of landing.
        waitUntil { controller.landing == nil }
        XCTAssertEqual(controller.hoverHoldPayload?.bundleID, "app")
        XCTAssertEqual(controller.hoverExemptPayload?.bundleID, "app")
        // It is still held after the turn in which the carrier retires (`carrierRetiring` is already false; it relies on the hold).
        waitUntil { !controller.isCarrying }
        XCTAssertFalse(controller.isCarrying, "载体已经撤了")
        XCTAssertEqual(controller.hoverExemptPayload?.bundleID, "app", "但指针没动，它自己仍按住")
        // Release once the fallback cap is reached (the test can't actually move the pointer).
        waitUntil(DragLandingPlan.hoverHoldMaximum + 1) { controller.hoverHoldPayload == nil }
        XCTAssertNil(controller.hoverHoldPayload)
        XCTAssertNil(controller.hoverExemptPayload)
    }

    /// **Whole-strip suppression only applies while "something is really being held in hand"**; during the return flight after release, other cards hover as usual
    /// (owner 2026-08-19: "while an icon is flying, moving the mouse over other icons shows no hover effect; it only does after full landing").
    func testOnlyTheFlyingCardIsExemptDuringTheReturnFlight() throws {
        // Arming the carrier waits on display frames, like the re-anchor test below; skipped on CI the same way.
        try XCTSkipIf(ProcessInfo.processInfo.environment["CI"] != nil, "needs a refreshing display; skipped on CI")
        begin(.strip, "app", at: outsideZone)
        waitUntil { controller.hiddenSlotPayload != nil }
        XCTAssertTrue(controller.hoverSuppressed, "拎着的时候整条不判悬停")

        controller.setLandingAnchor(CGRect(x: outsideZone.x + 200, y: outsideZone.y, width: 40, height: 54),
                                    owner: .strip)
        controller.endDrag()
        XCTAssertNotNil(controller.landing, "起飞了")
        XCTAssertFalse(controller.hoverSuppressed, "飞行期不再整条压制——别的卡要能悬停")
        XCTAssertEqual(controller.hoverExemptPayload?.bundleID, "app", "只豁免正在飞的那一张")
    }

    // MARK: - The return flight is interruptible (owner 2026-08-19: "native and bestdock can both interrupt")

    private func flyBack(from point: CGPoint) {
        begin(.strip, "app", at: point)
        waitUntil { controller.hiddenSlotPayload != nil }
        // Anchor far enough from the pointer -> release takes off.
        controller.setLandingAnchor(CGRect(x: point.x + 200, y: point.y, width: 40, height: 54), owner: .strip)
        controller.endDrag()
    }

    /// Re-grab mid-flight: the flight ends, it becomes a new drag, **the slot stays continuously empty** (`hiddenSlotPayload` doesn't flicker to nil).
    func testRegrabDuringLandingContinuesTheDragWithoutAGap() {
        flyBack(from: outsideZone)
        XCTAssertNotNil(controller.landing, "有锚点、位移够 → 起飞")
        XCTAssertNil(controller.draggingPayload)
        XCTAssertEqual(controller.hiddenSlotPayload?.bundleID, "app", "飞行中卡槽空着")

        // Click outside the icon -> can't grab it; the flight continues.
        XCTAssertFalse(controller.regrabLanding(at: CGPoint(x: outsideZone.x - 900, y: outsideZone.y - 900)))
        XCTAssertNotNil(controller.landing)

        // Pressing the same card's slot (no need to hit the icon) -> keep dragging from where the icon is right now.
        XCTAssertTrue(controller.regrabLanding(at: outsideZone, requireHit: false))
        XCTAssertNil(controller.landing, "飞行结束")
        XCTAssertEqual(controller.draggingPayload?.bundleID, "app", "变成新拖动")
        XCTAssertEqual(controller.hiddenSlotPayload?.bundleID, "app", "卡槽连续空着")
        XCTAssertTrue(controller.isCarrying)
        XCTAssertFalse(controller.hoverFrozen, "重抓的载体早就抬起了，不需要起拖那几帧的冻结")
        XCTAssertTrue(controller.hoverSuppressed)
        XCTAssertNil(controller.hoverHoldPayload)

        // Releasing again settles as usual.
        controller.endDrag()
        XCTAssertNil(controller.draggingPayload)
    }

    /// Pressing on the empty slot (SwiftUI's gesture started a drag of the same payload) also goes through re-grab: no more "instant settle + re-lift from the slot".
    func testBeginDragOfTheSameCardDuringLandingRegrabs() {
        flyBack(from: outsideZone)
        XCTAssertNotNil(controller.landing)
        begin(.strip, "app", at: CGPoint(x: outsideZone.x + 30, y: outsideZone.y))
        XCTAssertNil(controller.landing)
        XCTAssertEqual(controller.draggingPayload?.bundleID, "app")
        XCTAssertEqual(controller.hiddenSlotPayload?.bundleID, "app", "当轮就空着，没有起拖那两帧的门控")
        XCTAssertTrue(controller.carrierArmed)
    }

    /// A different card is picked up mid-flight -> the flight is dismissed as before (that is another card, not a re-grab).
    func testBeginDragOfAnotherCardDuringLandingAbortsTheFlight() {
        flyBack(from: outsideZone)
        XCTAssertNotNil(controller.landing)
        begin(.strip, "other", at: outsideZone)
        XCTAssertNil(controller.landing)
        XCTAssertEqual(controller.draggingPayload?.bundleID, "other")
    }

    /// Release after a re-grab without moving = **a click on this card**: a click is emitted, the icon keeps flying back to the slot, and no membership changes at all.
    func testRegrabThenReleaseWithoutMovingIsAClick() {
        var clicks: [DragPayload] = []
        let sub = controller.carrierClicks.sink { clicks.append($0) }
        defer { sub.cancel() }
        flyBack(from: outsideZone)
        XCTAssertTrue(controller.regrabLanding(at: outsideZone, requireHit: false))
        // On real hardware, as soon as the re-grab's `pointerMoves` fires, the task strip re-reports the slot frame; here we report it for it.
        controller.setLandingAnchor(CGRect(x: outsideZone.x + 200, y: outsideZone.y, width: 40, height: 54), owner: .strip)
        controller.endDrag()
        XCTAssertEqual(clicks.map(\.bundleID), ["app"])
        XCTAssertNotNil(controller.landing, "点完图标接着飞回卡槽")
        XCTAssertEqual(controller.landing?.kind, .returnToSlot)
        XCTAssertNil(controller.draggingPayload)
        XCTAssertFalse(drawer.contains("app"), "点一下不收纳")
    }

    /// A plain release without a re-grab is not a click.
    func testOrdinaryReleaseIsNotAClick() {
        var clicks: [DragPayload] = []
        let sub = controller.carrierClicks.sink { clicks.append($0) }
        defer { sub.cancel() }
        flyBack(from: outsideZone)
        XCTAssertTrue(clicks.isEmpty)
    }

    /// After the flight finishes there is nothing left to grab.
    func testRegrabAfterTheFlightIsRefused() {
        flyBack(from: outsideZone)
        waitUntil(DragLandingPlan.maximumDuration + 1) { controller.landing == nil }
        XCTAssertNil(controller.landing)
        XCTAssertFalse(controller.regrabLanding(at: outsideZone, requireHit: false))
        XCTAssertNil(controller.draggingPayload)
    }

    // MARK: - Release on the capsule to stash = sucked into the capsule (owner 2026-08-19: after stashing, the icon drifts toward the strip's end for a while, then disappears)

    private func makeStashingController() -> DragController {
        DragController(drawerStore: drawer, messagingStore: messaging, membershipController: membership,
                       dropZonesProvider: { [dropZone] _ in [dropZone] },
                       screensProvider: { NSScreen.screens },
                       stashTargetProvider: { CGRect(x: 40, y: 40, width: 20, height: 20) })
    }

    func testStripDropOnCapsuleFliesIntoTheCapsuleAndNeverRetargets() {
        let stashing = makeStashingController()
        defer { stashing.cancelDrag() }
        stashing.beginDrag(payload: payload(.strip, "app"), startScreenLocation: insideZone,
                           grabOffset: .zero, sourceScreenRect: .zero, pose: .resting, snapshot: stubSnapshot())
        waitUntil { stashing.hiddenSlotPayload != nil }
        XCTAssertTrue(stashing.isOverDropZone)
        stashing.endDrag()
        XCTAssertTrue(drawer.contains("app"), "照常收纳")
        guard let landing = stashing.landing else { return XCTFail("要有吸进胶囊的飞行") }
        XCTAssertEqual(landing.kind, .stash)
        XCTAssertEqual(landing.flight.toOpacity, 0)
        XCTAssertEqual(landing.flight.toScale, DragLandingPlan.stashScale)
        let destination = landing.flight.to
        // For a frame or two after stashing, the task strip still reports that slot's old frame -- the suck-in flight must not be pulled back.
        stashing.setLandingAnchor(CGRect(x: 500, y: 8, width: 40, height: 54), owner: .strip)
        XCTAssertEqual(stashing.landing?.flight.to, destination)
        // Can't be grabbed or clicked either: that card is no longer on the strip.
        XCTAssertFalse(stashing.regrabLanding(at: insideZone, requireHit: false))
    }

    /// Don't know where the capsule is (default provider) -> no flight, settle instantly, and **must not** fall back to flying toward a slot that no longer exists.
    func testStashWithoutACapsuleFrameDoesNotFlyBackToTheSlot() {
        begin(.strip, "app", at: insideZone)
        waitUntil { controller.hiddenSlotPayload != nil }
        controller.setLandingAnchor(CGRect(x: 500, y: 8, width: 40, height: 54), owner: .strip)
        controller.endDrag()
        XCTAssertTrue(drawer.contains("app"))
        XCTAssertNil(controller.landing)
    }

    // MARK: - Swap bitmap + re-anchor on entering the drawer body (owner 2026-08-19: after entering the drawer the big card pressed against the drawer edge)

    /// `reanchor: true`: the grab offset scales by the ratio of the old and new bitmap sizes, so the pointer stays at the same relative position on the icon.
    func testReanchoredSnapshotScalesTheGrabOffset() throws {
        // Re-anchoring waits for the carrier to be "lifted", and lifting is timed in display frames -- GitHub's headless runner has no display that refreshes,
        // so `carrierLifted` never becomes true. It runs as usual locally; on CI it is skipped, with the assertions unchanged.
        try XCTSkipIf(ProcessInfo.processInfo.environment["CI"] != nil, "needs a refreshing display; skipped on CI")
        controller.beginDrag(payload: payload(.strip, "app"), startScreenLocation: outsideZone,
                             grabOffset: CGSize(width: 10, height: -6), sourceScreenRect: .zero,
                             pose: .resting, snapshot: stubSnapshot(side: 4))
        waitUntil { controller.hiddenSlotPayload != nil }
        waitUntil { controller.carrierLifted }       // Re-anchoring is only allowed after lifting
        XCTAssertTrue(controller.carrierLifted)
        controller.setCarrierSnapshot(stubSnapshot(side: 2), reanchor: true)
        XCTAssertEqual(controller.grabOffset.width, 5, accuracy: 0.0001)
        XCTAssertEqual(controller.grabOffset.height, -3, accuracy: 0.0001)
        // Swapping back to the drag-start one (nil) also restores proportionally.
        controller.setCarrierSnapshot(nil, reanchor: true)
        XCTAssertEqual(controller.grabOffset.width, 10, accuracy: 0.0001)
        XCTAssertEqual(controller.grabOffset.height, -6, accuracy: 0.0001)
        // A bitmap swap without re-anchoring leaves the offset alone (the direction where a drawer icon is promoted into the task strip).
        controller.setCarrierSnapshot(stubSnapshot(side: 8))
        XCTAssertEqual(controller.grabOffset.width, 10, accuracy: 0.0001)
    }

    // MARK: - Messaging-zone chip -> drawer (stash preview)

    func testMessagingToDrawerConvertFlipsPayloadAndAddsMember() {
        messaging.mark("chat")
        begin(.messaging, "chat", at: outsideZone)
        controller.convertMessagingToDrawer()
        XCTAssertTrue(drawer.contains("chat"))
        XCTAssertEqual(controller.draggingPayload?.source, .drawer)
        XCTAssertTrue(controller.isConvertedFromMessaging)
        XCTAssertTrue(messaging.contains("chat"), "收纳不清消息 flag")
    }

    func testMessagingToDrawerRevertRestoresOriginal() {
        messaging.mark("chat")
        begin(.messaging, "chat", at: outsideZone)
        controller.convertMessagingToDrawer()
        controller.revertMessagingFromDrawer()
        XCTAssertFalse(drawer.contains("chat"))
        XCTAssertEqual(controller.draggingPayload?.source, .messaging)
        XCTAssertFalse(controller.isConvertedFromMessaging)
    }

    func testMessagingToDrawerDropInsideDrawerCommits() {
        messaging.mark("chat")
        begin(.messaging, "chat", at: outsideZone)
        controller.convertMessagingToDrawer()
        controller.endDrag()   // Release inside the drawer body
        XCTAssertTrue(drawer.contains("chat"), "落定后仍是抽屉成员")
        XCTAssertNil(controller.draggingPayload)
        XCTAssertFalse(controller.isConvertedFromMessaging, "commit 清转换态")
    }

    func testMessagingToDrawerCancelRollsBack() {
        messaging.mark("chat")
        begin(.messaging, "chat", at: outsideZone)
        controller.convertMessagingToDrawer()
        controller.cancelDrag()
        XCTAssertFalse(drawer.contains("chat"), "取消恢复原成员关系")
        XCTAssertNil(controller.draggingPayload)
    }

    /// Not in the drawer body, release on the capsule drop zone -> stash (equivalent to a task strip card landing on the capsule).
    func testMessagingChipDropOnCapsuleStashes() {
        messaging.mark("chat")
        begin(.messaging, "chat", at: insideZone)
        controller.endDrag()
        XCTAssertTrue(drawer.contains("chat"))
    }

    /// Release on the desktop / folder zone / live zone (not a drop zone) -> stays where it is.
    func testMessagingChipDropOutsideDoesNothing() {
        messaging.mark("chat")
        begin(.messaging, "chat", at: outsideZone)
        controller.endDrag()
        XCTAssertFalse(drawer.contains("chat"))
        XCTAssertTrue(messaging.contains("chat"))
    }

    // MARK: - Messaging app in the drawer -> messaging zone (temporary release)

    func testDrawerToMessagingReleaseRemovesMemberAndFlipsPayload() {
        messaging.mark("chat"); drawer.add("chat")
        begin(.drawer, "chat", at: outsideZone)
        controller.convertDrawerToMessaging()
        XCTAssertFalse(drawer.contains("chat"))
        XCTAssertEqual(controller.draggingPayload?.source, .messaging)
        XCTAssertTrue(controller.isReleasedToMessaging)
    }

    func testDrawerToMessagingRevertRestoresDrawer() {
        messaging.mark("chat"); drawer.add("chat")
        begin(.drawer, "chat", at: outsideZone)
        controller.convertDrawerToMessaging()
        controller.revertDrawerToMessaging()
        XCTAssertTrue(drawer.contains("chat"))
        XCTAssertEqual(controller.draggingPayload?.source, .drawer)
        XCTAssertFalse(controller.isReleasedToMessaging)
    }

    func testDrawerToMessagingDropCommits() {
        messaging.mark("chat"); drawer.add("chat")
        begin(.drawer, "chat", at: outsideZone)
        controller.convertDrawerToMessaging()
        controller.endDrag()   // Release inside the messaging zone (not a drop zone)
        XCTAssertFalse(drawer.contains("chat"), "落定：已离开抽屉")
        XCTAssertTrue(messaging.contains("chat"), "消息 flag 原样")
        XCTAssertNil(controller.draggingPayload)
    }

    func testDrawerToMessagingCancelRollsBack() {
        messaging.mark("chat"); drawer.add("chat")
        begin(.drawer, "chat", at: outsideZone)
        controller.convertDrawerToMessaging()
        controller.cancelDrag()
        XCTAssertTrue(drawer.contains("chat"), "取消回到抽屉")
    }

    /// A messaging member's drawer icon released on the task strip (outside the messaging zone's range) -> doesn't take the downgrade unstash path, stays in the drawer (review P1-3).
    func testMessagingMemberDrawerDragNeverFallbackUnstashes() {
        messaging.mark("chat"); drawer.add("chat")
        begin(.drawer, "chat", at: insideZone)   // Inside the drop zone (task strip panel)
        controller.endDrag()
        XCTAssertTrue(drawer.contains("chat"))
    }

    /// Non-messaging members keep the existing downgrade path: release on the task strip -> removed from the drawer.
    func testNonMessagingDrawerDragFallbackUnstashes() {
        drawer.add("plain")
        begin(.drawer, "plain", at: insideZone)
        controller.endDrag()
        XCTAssertFalse(drawer.contains("plain"))
    }

    // MARK: - Regression for the two existing directions (behavior unchanged after the conversion state converged into CrossPanelConversion)

    func testStripToDrawerConvertRevertPreservesKept() {
        kept.add("app")
        begin(.strip, "app", at: outsideZone)
        controller.convertStripToDrawer()
        XCTAssertTrue(drawer.contains("app"))
        XCTAssertTrue(kept.contains("app"))
        XCTAssertTrue(controller.isConvertedFromStrip)
        controller.revertStripFromDrawer()
        XCTAssertFalse(drawer.contains("app"))
        XCTAssertTrue(kept.contains("app"), "转换和撤销都不修改 kept")
        XCTAssertEqual(controller.draggingPayload?.source, .strip)
    }

    func testDrawerToStripConvertAndRevertPreservesKept() {
        drawer.add("app"); kept.add("app")
        begin(.drawer, "app", at: outsideZone)
        controller.convertDrawerToStrip()
        XCTAssertFalse(drawer.contains("app"))
        XCTAssertEqual(controller.convertedDrawerBundleID, "app")
        XCTAssertTrue(kept.contains("app"))
        controller.revertDrawerToStrip()
        XCTAssertTrue(drawer.contains("app"))
        XCTAssertTrue(kept.contains("app"), "placement 回滚不修改 kept")
        XCTAssertNil(controller.convertedDrawerBundleID)
    }

    /// The drawer's grid is shaped from the members with the conversion undone: every drag-out
    /// (unstash and keepPlacement alike) removes placement on convert, so the count must hold
    /// through convert → revert and only move on the commit.
    func testDrawerGridSettledCountHoldsThroughDragOutConversion() {
        ["a", "b", "app"].forEach(drawer.add)
        func settled() -> Int {
            let delta = controller.drawerConversionDelta
            return DrawerGridShape.settledCount(visibleIDs: drawer.bundleIDs,
                                                convertedInID: delta.convertedInID,
                                                convertedOutID: delta.convertedOutID)
        }
        begin(.drawer, "app", at: outsideZone)
        XCTAssertEqual(settled(), 3)
        controller.convertDrawerToStrip()
        XCTAssertFalse(drawer.contains("app"))
        XCTAssertEqual(settled(), 3, "converted out: still shaped as three")
        controller.revertDrawerToStrip()
        XCTAssertEqual(settled(), 3)
        controller.convertDrawerToStrip()
        controller.endDrag()
        controller.cancelDrag()
        XCTAssertEqual(settled(), 2, "committed: the grid may take its new shape")
    }

    func testDrawerGridSettledCountHoldsThroughDragInConversion() {
        ["a", "b"].forEach(drawer.add)
        func settled() -> Int {
            let delta = controller.drawerConversionDelta
            return DrawerGridShape.settledCount(visibleIDs: drawer.bundleIDs,
                                                convertedInID: delta.convertedInID,
                                                convertedOutID: delta.convertedOutID)
        }
        begin(.strip, "app", at: outsideZone)
        controller.convertStripToDrawer()
        XCTAssertTrue(drawer.contains("app"))
        XCTAssertEqual(settled(), 2, "converted in: not counted yet")
        controller.revertStripFromDrawer()
        XCTAssertEqual(settled(), 2)
    }

    func testUncheckedPlacementConversionsRemainUnchecked() {
        drawer.add("app")
        begin(.drawer, "app", at: outsideZone)
        controller.convertDrawerToStrip()
        XCTAssertFalse(kept.contains("app"))
        controller.revertDrawerToStrip()
        XCTAssertFalse(kept.contains("app"))
    }

    func testCancelFromDrawerToStripFiresCancelCallback() {
        drawer.add("app")
        var cancelled = false
        controller.onDrawerToStripCancelled = { cancelled = true }
        begin(.drawer, "app", at: outsideZone)
        controller.convertDrawerToStrip()
        controller.cancelDrag()
        XCTAssertTrue(cancelled)
        XCTAssertTrue(drawer.contains("app"))
    }

    // MARK: - Drag into the drawer and settle -> auto-open kept (owner 2026-08-06)

    /// Entry 1/4: a task strip card is dragged into the drawer body and released in the drawer.
    func testStripCardDroppedInsideDrawerEnablesKept() {
        begin(.strip, "app", at: outsideZone)
        controller.convertStripToDrawer()
        controller.endDrag()
        XCTAssertTrue(drawer.contains("app"))
        XCTAssertTrue(kept.contains("app"))
    }

    /// Entry 2/4: a task strip card never enters the drawer body and lands directly on the capsule.
    func testStripCardDroppedOnCapsuleEnablesKept() {
        begin(.strip, "app", at: insideZone)
        controller.endDrag()
        XCTAssertTrue(drawer.contains("app"))
        XCTAssertTrue(kept.contains("app"))
    }

    /// Entry 3/4: a messaging-zone chip is dragged into the drawer body. Messaging identity is unaffected.
    func testMessagingChipDroppedInsideDrawerEnablesKept() {
        messaging.mark("chat")
        begin(.messaging, "chat", at: outsideZone)
        controller.convertMessagingToDrawer()
        controller.endDrag()
        XCTAssertTrue(drawer.contains("chat"))
        XCTAssertTrue(kept.contains("chat"))
        XCTAssertTrue(messaging.contains("chat"))
    }

    /// Entry 4/4: a messaging-zone chip lands on the capsule.
    func testMessagingChipDroppedOnCapsuleEnablesKept() {
        messaging.mark("chat")
        begin(.messaging, "chat", at: insideZone)
        controller.endDrag()
        XCTAssertTrue(drawer.contains("chat"))
        XCTAssertTrue(kept.contains("chat"))
    }

    /// Negative case: reordering within the drawer settles -- no new member joins, so kept must not open.
    func testDrawerInternalReorderDoesNotEnableKept() {
        drawer.add("app")
        begin(.drawer, "app", at: outsideZone)
        controller.endDrag()
        XCTAssertTrue(drawer.contains("app"))
        XCTAssertFalse(kept.contains("app"), "抽屉内重排不是「拖入」")
    }

    /// Negative case: dragged into the drawer body then dragged back out (undo) -> no longer in the drawer at settle time, so kept must not open.
    func testStripCardRevertedOutOfDrawerDoesNotEnableKept() {
        begin(.strip, "app", at: outsideZone)
        controller.convertStripToDrawer()
        controller.revertStripFromDrawer()
        controller.endDrag()
        XCTAssertFalse(drawer.contains("app"))
        XCTAssertFalse(kept.contains("app"))
    }

    /// Negative case: a drawer icon is promoted into the task strip and then withdrawn -- the drag source is `.drawer`, it was already in the drawer,
    /// not brought in by this drag, so kept must not open.
    func testDrawerToStripRevertedDoesNotEnableKept() {
        drawer.add("app")
        begin(.drawer, "app", at: outsideZone)
        controller.convertDrawerToStrip()
        controller.revertDrawerToStrip()
        controller.endDrag()
        XCTAssertTrue(drawer.contains("app"))
        XCTAssertFalse(kept.contains("app"))
    }

    /// Negative case: promoted into the task strip and settled -- not in the drawer after settling.
    func testCommittedDrawerToStripDoesNotEnableKept() {
        drawer.add("app")
        begin(.drawer, "app", at: outsideZone)
        controller.convertDrawerToStrip()
        controller.endDrag()
        XCTAssertFalse(drawer.contains("app"))
        XCTAssertFalse(kept.contains("app"))
    }

    /// **Semantic lock** (owner 2026-08-06): after manually unchecking, dragging it in again **re-checks** it.
    /// This is not a bug -- every drag-in counts as re-expressing "I want this kept here long-term". Ask the owner before changing this.
    func testDraggingInAgainReEnablesKeptAfterManualUncheck() {
        begin(.strip, "app", at: insideZone)
        controller.endDrag()
        XCTAssertTrue(kept.contains("app"))

        // Drag back to the task strip (kept unchanged), then manually uncheck.
        begin(.drawer, "app", at: outsideZone)
        controller.convertDrawerToStrip()
        controller.endDrag()
        XCTAssertTrue(kept.contains("app"), "拖出抽屉不关 kept")
        kept.remove("app")

        begin(.strip, "app", at: insideZone)
        controller.endDrag()
        XCTAssertTrue(kept.contains("app"), "再次拖入重新打开 kept")
    }

    /// 2026-08-20: Finder can also be dragged into the drawer, and settling likewise checks keep for convenience (treated the same as ordinary apps).
    func testFinderEntersKeptThroughDrop() {
        kept.remove(FinderTaskbarPolicy.bundleID)   // Cancels the one-time seeding done at store initialization
        begin(.strip, FinderTaskbarPolicy.bundleID, at: insideZone)
        controller.endDrag()
        XCTAssertTrue(kept.contains(FinderTaskbarPolicy.bundleID))
    }
}

// MARK: - An app dropped from outside: the carrier takes over from the system's drag image

extension DragControllerConversionTests {
    func testExternalDropHoldsUntilTheSlotIsReportedThenFliesThere() {
        let from = CGRect(x: 300, y: 300, width: 40, height: 40)
        controller.beginExternalLanding(payload: payload(.drawer, "app"), snapshot: stubSnapshot(side: 4),
                                        fromScreenRect: from, kind: .returnToSlot)
        guard let held = controller.landing else { return XCTFail("要有落位飞行") }
        XCTAssertEqual(held.kind, .returnToSlot)
        XCTAssertTrue(held.flight.isStationary, "格子还没报上来：原地按住")
        XCTAssertEqual(controller.hiddenSlotPayload?.id, "app", "飞行期间那一格空着")
        controller.setLandingAnchor(CGRect(x: 420, y: 360, width: 40, height: 40), owner: .drawer)
        XCTAssertEqual(controller.landing?.token, held.token)
        XCTAssertEqual(controller.landing?.flight.isStationary, false, "报了格子就换成朝它飞")
    }

    func testExternalDropOnTheCapsuleFliesIntoTheCapsule() {
        let stashing = makeStashingController()
        defer { stashing.cancelDrag() }
        stashing.beginExternalLanding(payload: payload(.drawer, "app"), snapshot: stubSnapshot(side: 4),
                                      fromScreenRect: CGRect(x: 300, y: 300, width: 64, height: 64), kind: .stash)
        guard let landing = stashing.landing else { return XCTFail("要有吸进胶囊的飞行") }
        XCTAssertEqual(landing.kind, .stash)
        XCTAssertEqual(landing.flight.toOpacity, 0)
        XCTAssertEqual(landing.flight.toScale, DragLandingPlan.stashScale)
    }

    func testExternalDropNeverInterruptsADragOfOurOwn() {
        begin(.strip, "card", at: outsideZone)
        controller.beginExternalLanding(payload: payload(.drawer, "app"), snapshot: stubSnapshot(side: 4),
                                        fromScreenRect: CGRect(x: 300, y: 300, width: 40, height: 40), kind: .returnToSlot)
        XCTAssertNil(controller.landing)
        XCTAssertEqual(controller.draggingPayload?.id, "card")
    }

    func testExternalDropWithoutABitmapDoesNotFly() {
        controller.beginExternalLanding(payload: payload(.drawer, "app"), snapshot: nil,
                                        fromScreenRect: CGRect(x: 300, y: 300, width: 40, height: 40), kind: .returnToSlot)
        XCTAssertNil(controller.landing)
    }
}
