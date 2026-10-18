import AppKit
import os
import SwiftUI

/// The drawer is **app-centric**: one icon per bundleID, in the single order [[DrawerOrderStore]]
/// keeps. Running state never decides a position — it only picks how a cell looks and acts
/// (`showsAsRunning`): running = dot, click raises / hides the app (`LauncherChip.handleTap`);
/// otherwise the click launches it. Starting or quitting a visible app leaves every icon where it
/// is; an unkept app that quits hides and the cells after it close up, without touching the stored order.
///
/// DrawerStore only records placement; KeptAppStore decides whether an app keeps showing after it
/// quits. Ordering is always recorded against the full placement set, so hidden members return to
/// their original position on the next launch.
///
/// The two are **no longer fully orthogonal** (owner, 2026-08-06): once a **drag-in** settles, kept is
/// switched on as a side effect. Otherwise an ordinary app dragged into the drawer would vanish from
/// it as soon as it quit, which doesn't match the mental model of "putting it in the drawer = I want
/// it always there". A **drag back to the strip** still never touches kept. The conversion preview
/// and rollback phases never touch kept either; it is written only at the moment `endDrag()` settles.
/// For the criterion and full semantics, see `DragConversionPlan.enablesKeptOnDrop`.
struct DrawerView: View {
    /// Rows and columns the grid may take above the capsule on this screen; past them it scrolls
    /// inside the plate. The coordinator swaps the root view when they change.
    let limits: StackGridLayout.Limits
    /// The plate's arrow, kept on the capsule by the coordinator.
    let arrow: StackPopupArrowModel
    /// This showing's held column basis. No default — without it the columns follow every release.
    @ObservedObject var showing: DrawerShowingModel
    /// The plate's size changed: the coordinator re-lays out the drawer window. No default —
    /// without it the window stops following its content.
    let onPanelSizeChange: (CGSize) -> Void
    /// Whether the backplate uses native Liquid Glass. **Passed in explicitly, no default** (same as
    /// `scale` / `hoverStyle`): every panel is an independent hosting root view, and forgetting to pass
    /// it produces an obvious inconsistency like "this panel is glass while the one next to it is still
    /// frosted glass".
    let usesLiquidGlass: Bool
    /// Whether this drawer panel is currently open. **Passed in explicitly, no default**: with ③④ each
    /// screen has its own drawer view, and the closed one still holds a stale `drawerRootScreenRect`.
    /// Without asking this, the old position would make a conversion in another screen's drawer be judged
    /// "dragged out" and reverted. The two views would flip the conversion state back and forth, and
    /// changing `@Published` during layout crashed on a real device on 2026-09-02.
    /// **Every callback in this view driven by the drag controller must ask it first** (convert / revert,
    /// reorder, landing anchor, click while in flight): a closed drawer view lives until the next time it
    /// opens, and without asking it would write stale positions into the shared controller. An icon
    /// dragged out of a secondary-screen drawer once flew to the main-screen drawer's slot because of
    /// this (the second incident that same day).
    let isDrawerOpen: () -> Bool
    /// Callback after clicking an app icon performs "bring forward" or "launch". Injected by
    /// PanelCoordinator, used to close the drawer. "Minimize (foreground → collapse)" does not trigger
    /// it: the drawer stays open. Right-click menu and drag operations don't trigger it either.
    var onPrimaryAction: () -> Void = {}
    /// An app dragged from outside entered / left the open plate: the coordinator's spring-load
    /// (`ExternalDragSpringLoad`). No default — an omission would compile into a drawer that
    /// closes under the pointer while the app is being carried in.
    let onExternalDragHover: (Bool) -> Void
    /// App bundles released over the open plate, with where they go in the order (the cell under
    /// the pointer). No default — an omission would compile into a drawer that refuses them.
    let onDropApplications: ([URL], DrawerAppDrop.Placement) -> Void
    /// The same drop when the make-way slot was open: the ids it showed, landed where it was, in
    /// the turn that closes it. No default — an omission would compile into a slot that closes and
    /// an app that appears a beat later somewhere else.
    let onDropApplicationIDs: ([String], DrawerAppDrop.Placement) -> Void

    @EnvironmentObject var runtime: AppRuntime
    @EnvironmentObject var drawerStore: DrawerStore
    @EnvironmentObject var messagingStore: MessagingAppStore
    @EnvironmentObject var drawerOrderStore: DrawerOrderStore
    @EnvironmentObject var dragController: DragController
    @EnvironmentObject var keptAppStore: KeptAppStore
    @EnvironmentObject var runningApplicationStore: RunningApplicationStore
    @EnvironmentObject var appMembershipController: AppMembershipController

    /// Cell frames in the `"drawer"` space: the grab offset at pick-up and the reorder hit test.
    @State private var drawerFrames: [String: CGRect] = [:]

    /// Screen frame of the drawer root view (bottom-left origin), used to decide "is the cursor in the drawer body" + converting screen coordinates → the `"drawer"` space.
    @State private var drawerRootScreenRect: CGRect = .zero

    /// Apps dragged from outside over the open plate: their hidden cells make way where the drop
    /// would land (`ExternalDrawerGhost`). View state only — the stores change at the drop.
    @State private var externalGhost: ExternalDrawerGhost?
    @State private var externalGhostExpiry = ExternalGhostExpiry()
    /// The cell bitmaps of the apps in the slot, made once per hover: the drag image turns into
    /// them and the first one is the carrier that lands it.
    @State private var externalCellImages = ExternalCellImages()

    // MARK: - Members and partitions (all at bundleID level)

    /// The full Placement set is fed to the ordering layer; never trim by what is currently visible.
    private var allMembers: [String] {
        AppMembershipProjection.drawerMembers(drawerIDs: drawerStore.bundleIDs)
    }

    private var displayOrder: [String] { drawerOrderStore.reconciled(members: allMembers) }

    /// The grid's cells: the visible members, with the make-way slot of an outside drag in place.
    private var gridIDs: [String] {
        externalGhost?.displayOrder(visibleMembers: visibleMembers) ?? visibleMembers
    }

    /// The only visibility funnel: running, or has a permanent kept / messaging identity. The input uses
    /// display order, so a hidden placement that reappears returns to its original relative position.
    private var visibleMembers: [String] {
        AppMembershipProjection.visibleDrawerIDs(
            drawerIDs: displayOrder,
            keptIDs: keptAppStore.bundleIDs,
            runningIDs: runningApplicationStore.runningBundleIDs
        )
    }

    /// Apps with a real window (used for the launch-gating decision).
    private var windowBackedIDs: Set<String> {
        Set(StripItem.items(from: runtime.snapshot).filter { !$0.isAppLevelFallback }.compactMap(\.bundleIdentifier))
    }

    /// Window gate: launched from here, process up but no real window yet → still launching, so the
    /// cell keeps its not-running look and bounces.
    private func isLaunchingWithoutWindow(_ id: String) -> Bool {
        runtime.launchingBundleIDs.contains(id) && !windowBackedIDs.contains(id)
    }

    /// Only the Finder cell reads the real value: `windowBackedIDs` rescans the snapshot every time,
    /// and this value is only used by the Finder branch of `performDefaultTap`, so there is no need to pay
    /// for it on every cell. Being constantly `false` for non-Finder apps is intentional.
    private func finderHasRealWindow(_ id: String) -> Bool {
        guard FinderTaskbarPolicy.isFinder(id) else { return false }
        return windowBackedIDs.contains(id)
    }

    /// The running decision goes through RunningApplicationStore (NSWorkspace process projection), on the same basis as the strip's pinned dot.
    private func isRunning(_ id: String) -> Bool { runningApplicationStore.isRunning(id) }

    /// The hidden decision uses the same basis: it counts as hidden only if all processes of the same bundle are hidden.
    private func isHiddenInSnapshot(_ id: String) -> Bool { runningApplicationStore.isHidden(id) }

    /// A cell shows and acts as running (dot, raise / hide on click, window list in its menu) once
    /// the process runs and, after a launch from here, its first real window is up. Look and
    /// behaviour only — never the cell's position.
    private func showsAsRunning(_ id: String) -> Bool {
        isRunning(id) && !isLaunchingWithoutWindow(id)
    }

    // MARK: - Body

    /// The grid's shape (`DrawerGridShape`): columns from the count this showing opened with
    /// (`DrawerShowingModel`), else from the members with a conversion in flight undone. The
    /// columns count `visibleMembers` alone, so an outside drag's slot never changes them; its
    /// cells may add a row.
    private func gridShape(cellIDs: [String]) -> DrawerGridShape.Result {
        let delta = dragController.drawerConversionDelta
        let settled = DrawerGridShape.settledCount(visibleIDs: visibleMembers,
                                                   convertedInID: delta.convertedInID,
                                                   convertedOutID: delta.convertedOutID)
        let basis = DrawerGridShape.columnBasis(heldCount: showing.heldCount(capturing: settled),
                                                settledCount: settled, actualCount: cellIDs.count)
        return DrawerGridShape.resolve(settledCount: basis, actualCount: cellIDs.count, limits: limits)
    }

    var body: some View {
        // One grid in the drawer's own order: the folder popup's chrome with apps in its cells.
        let ids = gridIDs
        let shape = gridShape(cellIDs: ids)
        return StackPopupChrome(title: String(localized: "Drawer"),
                                note: shape.showsHint ? String(localized: "Drag apps here") : nil,
                                layout: shape.layout,
                                plate: .drawer,
                                usesLiquidGlass: usesLiquidGlass,
                                appearance: .alwaysDark,
                                arrow: arrow,
                                onPanelSizeChange: onPanelSizeChange,
                                gridAnimation: .easeInOut(duration: DrawerAnimation.duration),
                                gridAnimationKey: ids) {
            ForEach(ids, id: \.self) { drawerChip($0, running: showsAsRunning($0)) }
        }
        // Screen frame of the drawer root view (AppKit conversion, avoiding the pitfalls of .global / y-flip /
        // shadowPadding, Codex second review P1-3).
        // Attached to the same view as the `"drawer"` namespace → it can both decide "is the cursor in the drawer" and map screen coordinates back into drawer space to hit-test cells.
        // **When the drawer panel itself moves, the landing anchor must be re-reported too.** At the moment
        // of release, `teardown` clears `conversion`, the strip width is then unfrozen and the whole strip
        // re-centers and narrows; the capsule is right-aligned to the strip and the drawer is anchored on
        // the capsule, so **the entire drawer panel slides left a bit over 0.22s**, while the cell's frame
        // in the `"drawer"` space doesn't move at all, and only this screen rect changes. Without this hook,
        // the settle-back flight would keep flying toward the position the panel occupied **before** it
        // moved away (on the right), and only on landing would the cell be found already on the left. That is
        // exactly what the owner reported as "first drifts to the right of the target position, then goes
        // to the target position". The correction mechanism was already built for exactly this; the only
        // thing missing was feeding it from here.
        .background(ScreenRectReader { rect in
            guard rect != drawerRootScreenRect else { return }
            drawerRootScreenRect = rect
            updateLandingAnchor()
        })
        // An app dragged from outside (Finder) lands in the open plate. Over the whole window so
        // the zone is one rect in screen space (the plate, not the 40pt transparent border);
        // `hitTest` nil, so cells, menus and scrolling beneath are untouched. The closed drawer
        // view of another screen is ordered out and never receives a drag.
        .overlay(DrawerAppDropReceiver(
            screenZone: { PanelGeometry.folderPopupPlateFrame(panelFrame: drawerRootScreenRect) },
            onHoverChange: onExternalDragHover,
            onHoverLocation: { updateExternalGhost(at: $0) },
            dragImage: { externalCellImage(for: $0) },
            onDropApplications: { urls, screenPoint, landing in
                externalGhostExpiry.cancel()
                if let ghost = externalGhost, let first = ghost.ids.first {
                    let carrier = externalCellImages.cells[first]?.snapshot
                    externalCellImages.cells.removeAll()
                    // The carrier goes up first and the stores change on the next turn: committing
                    // them re-renders both bars and the drawer (tens of ms, more with a bar per
                    // screen), and the carrier reaches the screen only when the turn that presents
                    // it ends — sharing a turn, nothing shows where the drag image was let go. The
                    // ghost keeps the grid as it is until then; the first app's slot passes from
                    // the ghost to the landing without a frame shown.
                    if let landing, landing.bundleID == first {
                        dragController.beginExternalLanding(
                            payload: DragPayload(source: .drawer, id: first, bundleID: first, item: nil,
                                                 visualKind: .drawerIcon, canExternalDrop: true),
                            snapshot: carrier, fromScreenRect: landing.screenFrame, kind: .returnToSlot)
                        // The slot's frame is known now; an unchanged layout would never report it.
                        updateLandingAnchor()
                    } else {
                        dragController.clearCandidate(payloadID: first)
                    }
                    DispatchQueue.main.async {
                        // The hidden cells become the members, where they already are.
                        HoverTrace.action("extghost", phase: "land")
                        if externalGhost == ghost { externalGhost = nil }
                        onDropApplicationIDs(ghost.ids, ghost.placement)
                    }
                    return
                }
                clearExternalGhost()
                let point = CGPoint(x: screenPoint.x - drawerRootScreenRect.minX,
                                    y: drawerRootScreenRect.maxY - screenPoint.y)   // screen (bottom-left) → drawer (top-left)
                onDropApplications(urls, DrawerAppDrop.placement(at: point, frames: drawerFrames, order: visibleMembers))
            }))
        .coordinateSpace(name: "drawer")
        // **Opening the drawer has no entrance animation** (owner, 2026-09-04: protect the strip's animation
        // first; the drawer area may be redone). The earlier "panel fade-in + content 0.96→1 scale-up + cards
        // appearing in stages" had to recompute the whole drawer tree from its pre-entrance state on every
        // open, the main-thread stall landed at the start of the fade-in (still 22-40ms after the view tree
        // was reused), and the animation itself became the source of dropped frames. See `Docs/27` for the rationale.
        // Re-report the landing anchor when a cell's frame changes (same reason as on the strip side: after release the pointer produces no events while the grid is still re-flowing).
        .onPreferenceChange(DrawerChipFramePreferenceKey.self) { frames in
            drawerFrames = frames
            updateLandingAnchor()
        }
        // When the dragged icon's app disappears from the members during a drag (external removal, etc.) → cancel the drag, so the empty slot doesn't get stuck.
        // Exception: conversion into the strip (drawer-to-strip drag, precise landing) **actively** moves it out of the drawer; that is not an abnormal disappearance and doesn't cancel.
        .onChange(of: visibleMembers) { members in
            if let p = dragController.draggingPayload, p.source == .drawer,
               !dragController.isConvertedToStrip, !members.contains(p.id) {
                dragController.cancelDrag()
            }
        }
        // A strip card dragged into the drawer converts here; a drawer drag reorders here. Both follow the
        // global pointer and never publish from body (onChange + dedupe).
        // `onReceive` rather than `onChange(of: globalLocation)`, for the same reason as `DockStripView`:
        // once that value is `@Published`, every mouse movement would knock the whole panel over and recompute it.
        .onReceive(dragController.pointerMoves) { _ in
            updateStripDropPreview(); updateDrawerReorder(); updateLandingAnchor()
        }
        .onChange(of: dragController.draggingPayload?.id) { id in
            if id == nil { convertedCarrierID = nil }   // drag ended: the next time the same app comes in, the image needs to be swapped again
            // `onChange` runs during SwiftUI's layout / commit pass. Changing `DragController`'s `@Published`
            // inside it (convert / revert) makes AppKit throw in `_postWindowNeedsUpdateConstraints` (crash on 2026-09-02).
            // Push it to the next run loop turn and decide then.
            DispatchQueue.main.async { updateStripDropPreview() }
        }
        // A click on a drawer icon during the settle-back flight = a click on this cell: run the cell's own default left-click behavior (same static logic).
        .onReceive(dragController.carrierClicks) { payload in
            // Only the open drawer view dispatches (each screen has its own view; if all dispatched, a running app would show / hide twice = net zero).
            guard isDrawerOpen(), payload.source == .drawer, !runtime.launchingBundleIDs.contains(payload.id) else { return }
            LauncherChip.performDefaultTap(
                bundleID: payload.id,
                isRunning: isRunning(payload.id),
                finderHasRealWindow: finderHasRealWindow(payload.id),
                launch: { if runtime.beginLaunch(payload.id) { onPrimaryAction() } },
                onOpen: onPrimaryAction)
        }
    }

    // MARK: - A single icon (including drag)

    /// The cell bitmap an app's drag image turns into over the plate (`drawerChipContent`, the
    /// code that draws the cell, as for a bar card dragged in). The slot's first app is also
    /// prepared as the carrier (`prepareCandidate`): a new bitmap reaches the screen a frame late,
    /// and the release has no frame to spare.
    private func externalCellImage(for id: String) -> DrawerDragImage? {
        if let cached = externalCellImages.cells[id] { return cached.image }
        guard drawerRootScreenRect != .zero else { return nil }
        let center = CGPoint(x: drawerRootScreenRect.midX, y: drawerRootScreenRect.midY)
        guard let snapshot = ChipSnapshotter.snapshot(of: drawerChipContent(id, running: showsAsRunning(id)),
                                                      screenPoint: center) else { return nil }
        let metrics = StackCellMetrics.drawer
        guard let image = DrawerDragImage(
            snapshot: snapshot,
            iconRect: DrawerDragImageGeometry.iconRect(bitmapSize: snapshot.size, cellSize: snapshot.contentSize,
                                                       iconSize: metrics.iconSize, iconTop: metrics.iconTop)) else { return nil }
        externalCellImages.cells[id] = (snapshot, image)
        if id == externalGhost?.ids.first {
            dragController.prepareCandidate(
                payloadID: id,
                sourceScreenRect: CGRect(x: center.x - snapshot.size.width / 2, y: center.y - snapshot.size.height / 2,
                                         width: snapshot.size.width, height: snapshot.size.height),
                snapshot: snapshot)
        }
        return image
    }

    /// `carriedPayload` rather than `draggingPayload`: after release there is still a settle-back flight,
    /// and during that time the cell must stay empty, otherwise the icon shows up in the cell first while the carrier is still flying here.
    /// An outside drag's make-way cells are empty slots too.
    private func isSlotHidden(_ id: String) -> Bool {
        if externalGhost?.ids.contains(id) == true { return true }
        guard let p = dragController.hiddenSlotPayload else { return false }
        return p.source == .drawer && p.id == id
    }

    /// Opens, moves or closes the make-way slot of apps dragged from outside, from the drop
    /// receiver's pointer (`nil` = it no longer takes the drag). The receiver calls this every
    /// ~50ms, so the slot is written only when the grid order it shows would change.
    private func updateExternalGhost(at screenPoint: CGPoint?) {
        let ids = StripFileDropDelegate.DragPasteboardInspector.applicationBundleIDs().filter(KeptAppStore.canKeep)
        guard let screenPoint, !ids.isEmpty, isDrawerOpen(),
              dragController.draggingPayload == nil,
              drawerRootScreenRect != .zero else {
            externalGhostExpiry.cancel()
            clearExternalGhost()
            return
        }
        externalGhostExpiry.arm { clearExternalGhost() }
        let point = CGPoint(x: screenPoint.x - drawerRootScreenRect.minX,
                            y: drawerRootScreenRect.maxY - screenPoint.y)   // screen (bottom-left) → drawer (top-left)
        let shown = gridIDs
        let placement = DrawerAppDrop.hoverPlacement(current: externalGhost?.placement, point: point,
                                                     frames: drawerFrames, displayOrder: shown, ghostIDs: ids)
        let next = ExternalDrawerGhost(ids: ids, placement: placement)
        // `.after(A)` and `.before(B)` can be the same slot: compare what the grid would show.
        guard externalGhost?.ids != ids || next.displayOrder(visibleMembers: visibleMembers) != shown else { return }
        HoverTrace.action("extghost", phase: "\(placement)")
        externalGhost = next
    }

    /// Closes the make-way slot and drops what it prepared. The prepared carrier is released by the
    /// cached ids, not the slot's: an expired slot is already gone, and a candidate left behind
    /// would be claimed by a later capsule drop of the same app.
    private func clearExternalGhost() {
        for id in externalCellImages.cells.keys { dragController.clearCandidate(payloadID: id) }
        externalCellImages.cells.removeAll()
        if externalGhost != nil { HoverTrace.action("extghost", phase: "clear"); externalGhost = nil }
    }

    /// Which drawer cell the floating copy should fly back to on release (screen coordinates). The strip
    /// side writes its own copy too, separated by an owner tag.
    /// A strip card put into the drawer (source already flipped to `.drawer`) also goes through here: the icon flies straight into the cell it settles in.
    private func updateLandingAnchor() {
        guard isDrawerOpen() else { return }   // a closed drawer neither reports an anchor nor clears the one the open drawer reported
        let anchor: CGRect? = {
            // `carriedPayload`: keep reporting during the flight too; the offset can only be corrected after the grid re-flow settles.
            guard let p = dragController.carriedPayload, p.source == .drawer,
                  !dragController.isConvertedToStrip,
                  drawerRootScreenRect != .zero,
                  let frame = drawerFrames[p.id] else { return nil }
            return drawerFrameToScreen(frame)
        }()
        dragController.setLandingAnchor(anchor, owner: .drawer)
    }

    private func membershipItems(for id: String) -> [LauncherMembershipItem] {
        LauncherMembershipItem.items(
            surface: .drawer,
            bundleID: id,
            isKept: keptAppStore.contains(id),
            isMessaging: messagingStore.contains(id),
            controller: appMembershipController
        )
    }

    /// `running` is `showsAsRunning`, so look, click and menu agree: a process launched from here
    /// stays "not running" until its first real window; the runtime's launch session drives the bounce.
    /// **What to draw** in a drawer cell. The only reason for splitting it out: the carrier bitmap has to
    /// come from here (`ChipSnapshotter`), and rendering the cell and rendering the carrier must be the
    /// same code with the same parameters. The outer entrance animation / opacity set to 0 while dragging
    /// / gestures must not enter the snapshot, so they stay in `drawerChip`.
    private func drawerChipContent(_ id: String, running: Bool) -> some View {
        // The drawer's plate is always dark (`StackPopupAppearance.alwaysDark`); the cell takes it
        // here, not from the chrome, so the drag carrier's snapshots of it are dark too.
        LauncherChip(bundleID: id,
                     isRunning: running,
                     isHidden: running ? isHiddenInSnapshot(id) : false,
                     finderHasRealWindow: finderHasRealWindow(id),
                     isLaunching: runtime.launchingBundleIDs.contains(id),
                     // 76pt icon = 1.9 × the bar's 40pt slot (`StackCellMetrics.drawer.iconSize`).
                     scale: 1.9,
                     layout: .stackCell,
                     // The drawer is intentionally unaffected by the "hover effect" setting (owner, 2026-08-02), but is
                     // **pinned to the quiet tier** (owner, 2026-08-17 wanted "drawer icons scale up slightly on hover").
                     //
                     // `.standard` was written back then for "hover shows the name", and that reason went away on
                     // 2026-08-16: the name moved into the bubble above the icon, and this drawer call site **never wired
                     // up the bubble callback at all**, so `.standard` here amounts to "do nothing" and the drawer had
                     // zero hover feedback. `.quiet` is precisely the tier of "no name, so give a slight scale-up", so
                     // the semantics match. In a 112.5pt-wide cell the icon's visible part is about 62pt, and a 1.10
                     // scale still stays within its own cell's transparent margin.
                     hoverStyle: .quiet,
                     // The drawer panel has no whole-strip tracking area like the strip does; each icon attaches its own `.onHover`.
                     // The cell is 112.5pt wide and the pointer stays in it much longer than a sweep across the strip, so a missed cell isn't a problem.
                     hoverInput: .selfTracked,
                     // The drawer app's window blocks are hidden entirely outside the strip, and this list is the only way to get them back.
                     // Clicking a window row doesn't trigger onPrimaryAction: the drawer stays open (same rule as right-click "Open").
                     windowEntriesProvider: {
                         WindowListMenuPlan.entries(
                             snapshot: runtime.snapshot,
                             bundleID: id,
                             fallbackTitle: AppDisplayNameResolver.displayName(for: id)
                         )
                     },
                     onActivateWindow: { runtime.activate(windowID: $0) },
                     membershipItems: membershipItems(for: id),
                     slotHidden: isSlotHidden(id),
                     hoverSuppressed: isHoverSuppressed(id),
                     onLaunch: { runtime.beginLaunch(id) },
                     onPrimaryAction: onPrimaryAction)
            .environment(\.colorScheme, .dark)
    }

    /// Whether this cell's hover feedback should be held: it is being picked up (`.onHover` is still true
    /// while it's transparent), or it has just settled and the pointer hasn't moved (`DragController.hoverHoldPayload`).
    /// On the strip side the whole-strip tracking area suppresses it at the source; the drawer's `LauncherChip`s each attach their own `.onHover`, so it can only be suppressed per cell here.
    ///
    /// While a drag is live every cell holds still, as the strip does while the button is down:
    /// a cell lifting under the passing carrier makes the drawer's glass plate re-render, and the
    /// carried icon stutters.
    private func isHoverSuppressed(_ id: String) -> Bool {
        if dragController.draggingPayload != nil || externalGhost != nil { return true }
        if let p = dragController.hoverHoldPayload, p.source == .drawer, p.id == id { return true }
        return isSlotHidden(id)
    }

    /// The pose of a drawer cell at the moment a drag begins: the drawer is always in the quiet tier and
    /// the pointer must be on the cell (the mouse-down happened on it), so it is a 1.10 bottom-anchored
    /// scale × 0.93 press, unless hover is being held. The multiplier is computed with the same function that renders the cell.
    private func pickUpPose(for id: String, slot: CGRect?) -> DragCarrierGeometry.PickUpPose {
        let height = slot?.height ?? StackCellMetrics.drawer.cellSize.height
        let width = slot?.width ?? StackCellMetrics.drawer.cellSize.width
        let hoverScale: CGFloat? = isHoverSuppressed(id)
            ? nil
            : ChipPillMetrics.quietHoverScale(forCardWidth: width, scale: 1.9)
        return DragCarrierGeometry.pickUpPose(
            chipHeight: height,
            pressedScale: ChipPressSwitches.pressDownEnabled ? ChipPressDecision.pressedScale : nil,
            hoverScale: hoverScale)
    }

    /// The cell's frame in screen coordinates; nil if the drawer root frame hasn't been measured yet (a drag start then falls back to "place under the pointer").
    private func slotScreenRect(_ id: String) -> CGRect? {
        guard drawerRootScreenRect != .zero, let slot = drawerFrames[id] else { return nil }
        return drawerFrameToScreen(slot)
    }

    /// Which drawer cell the floating copy should fly back to on release / which cell the carrier takes over from at drag start: `"drawer"`-space frame → screen coordinates.
    private func drawerFrameToScreen(_ frame: CGRect) -> CGRect {
        CGRect(x: drawerRootScreenRect.minX + frame.minX,
               y: drawerRootScreenRect.maxY - frame.maxY,
               width: frame.width, height: frame.height)
    }

    @ViewBuilder
    private func drawerChip(_ id: String, running: Bool) -> some View {
        drawerChipContent(id, running: running)
            .opacity(isSlotHidden(id) ? 0 : 1)
            // The frame in the `"drawer"` space via a background GeometryReader (takes no clicks):
            // grab offset and reorder hit test.
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: DrawerChipFramePreferenceKey.self,
                                           value: [id: geo.frame(in: .named("drawer"))])
                }
            )
            // This gesture **only starts the drag, once**: after getting "which card + grab offset" it hands off to DragController.
            // Reordering is **not done here**: the first reorder moves the dragged icon within the grid, SwiftUI then cancels this gesture and
            // onChanged stops firing → "jams after one nudge" (owner, 2026-06-22). Reordering is instead driven by updateDrawerReorder()
            // from DragController's global mouse position (see onChange(globalLocation)), so the icon can swap places freely without affecting it.
            // **Prepare on press** (`DragController.prepareCandidate`): at the moment of mouse-down, this cell's bitmap
            // is attached to the carrier layer to warm up the texture, so that "light up + hide the cell" can happen in the same frame as the drag start. If the release comes without a drag starting, it is withdrawn.
            .simultaneousGesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("drawer"))
                    .onChanged { _ in
                        guard let rect = slotScreenRect(id) else { return }
                        dragController.prepareCandidate(
                            payloadID: id,
                            sourceScreenRect: rect,
                            snapshot: ChipSnapshotter.snapshot(of: drawerChipContent(id, running: running),
                                                             screenPoint: CGPoint(x: drawerRootScreenRect.midX, y: drawerRootScreenRect.midY)))
                    }
                    .onEnded { _ in dragController.clearCandidate(payloadID: id) }
            )
            .simultaneousGesture(
                DragGesture(minimumDistance: 8, coordinateSpace: .named("drawer"))
                    .onChanged { value in
                        guard dragController.draggingPayload == nil else { return }
                        let slot = drawerFrames[id]
                        let grab: CGSize = slot.map {
                            CGSize(width: $0.midX - value.startLocation.x,
                                   height: $0.midY - value.startLocation.y)
                        } ?? .zero
                        let payload = DragPayload(source: .drawer, id: id, bundleID: id, item: nil,
                                                  visualKind: .drawerIcon, canExternalDrop: true)
                        dragController.beginDrag(
                            payload: payload,
                            startScreenLocation: NSEvent.mouseLocation,
                            grabOffset: grab,
                            sourceScreenRect: slotScreenRect(id) ?? .zero,
                            pose: pickUpPose(for: id, slot: slot),
                            snapshot: ChipSnapshotter.snapshot(of: drawerChipContent(id, running: running),
                                                             screenPoint: CGPoint(x: drawerRootScreenRect.midX, y: drawerRootScreenRect.midY)))
                    }
                    // Release fallback, aligned with the in-strip side: normally the wrap-up relies on DragController's global monitor + polling;
                    // this is the second path for when the monitor happens not to get the mouseUp (in-strip dragging always had it; the drawer side originally didn't).
                    .onEnded { _ in dragController.endDrag() }
            )
    }

    /// Reorder inside the drawer, driven by DragController's global pointer (the per-icon gesture is
    /// cancelled after the first move). The screen point maps back into the `"drawer"` space; the
    /// member count does not change, so the live `drawerRootScreenRect` is the right mapping.
    private func updateDrawerReorder() {
        guard isDrawerOpen(), let p = dragController.draggingPayload, p.source == .drawer,
              !dragController.isOverDropZone,            // cursor is already on the strip = moving back, don't reorder
              drawerRootScreenRect != .zero else { return }
        let pt = CGPoint(x: dragController.globalLocation.x - drawerRootScreenRect.minX,
                         y: drawerRootScreenRect.maxY - dragController.globalLocation.y)   // screen (bottom-left) → drawer (top-left)
        reorderTarget(at: pt, dragging: p.id, among: visibleMembers)
    }

    /// Any visible cell is a target: the grid is drawn in `DrawerOrderStore` order alone, so a move
    /// shows at once, whatever the two apps' running states.
    private func reorderTarget(at point: CGPoint, dragging id: String, among candidates: [String]) {
        // Cells tile the grid edge to edge, so the plain frame is the whole hit area.
        for tid in candidates where tid != id {
            guard let f = drawerFrames[tid], f.contains(point) else { continue }
            drawerOrderStore.reorder(draggedID: id, relativeTo: tid, after: point.x > f.midX)
            return
        }
    }

    // MARK: - Strip card into the drawer body → converted into an in-drawer drag / reverted when dragged out

    /// A strip card dragged into the **open drawer body** → instantly converted into an in-drawer drag
    /// (DragController.convertStripToDrawer: joins the drawer members, source changed to `.drawer`).
    /// From then on this card is an ordinary drawer member, reordered by the global-mouse-driven
    /// `updateDrawerReorder`, **exactly the same system** as dragging within the drawer (owner,
    /// 2026-06-22: unified feel). It completely bypasses the old "placeholder gap + repeated panel resizing" mechanism (the source of flicker / jank).
    /// Tolerance is left on the bottom / side edges: the carrier has a grab offset relative to the mouse, and the mouse often lands near the drawer's bottom edge; the tolerance lets an edge-hugging position still reliably count as "entered the drawer body".
    private func updateStripDropPreview() {
        let dc = dragController
        // Only an **open** drawer is eligible to convert / revert (reason in `isDrawerOpen`).
        guard dc.draggingPayload != nil, drawerRootScreenRect != .zero, isDrawerOpen() else { return }
        let g = dc.globalLocation
        // The plate, not the window (40pt of transparent border). The floor is the capsule's top
        // = the bar's top edge: anything lower would convert a chip still being dragged along
        // the bar.
        let r = PanelGeometry.folderPopupPlateFrame(panelFrame: drawerRootScreenRect)
        let floor = PanelGeometry.drawerBodyFloorY(plate: r)
        // Enter threshold is loose (large tolerance, easy to enter); the revert threshold is further out (a hysteresis band, to prevent repeatedly converting/reverting at the edge → the drawer swelling and shrinking and jittering).
        let enterBody = g.x >= r.minX - 8  && g.x <= r.maxX + 8  && g.y >= floor
        let clearlyOut = g.x < r.minX - 20 || g.x > r.maxX + 20 || g.y < floor - 20
        if let p = dc.draggingPayload, p.canExternalDrop, enterBody {
            switch p.source {
            case .strip:     dc.convertStripToDrawer()      // into the drawer body → temporarily converted (pushes others aside = preview)
            case .messaging: dc.convertMessagingToDrawer()  // messaging chip gets the same stow-preview feel
            case .drawer, .folder: break
            }
            syncConvertedCarrier()
        } else if clearlyOut {
            if dc.isConvertedFromStrip {
                dc.revertStripFromDrawer()          // dragged out of the drawer body → revert (drawer shrinks back to its original look)
            } else if dc.isConvertedFromMessaging {
                dc.revertMessagingFromDrawer()      // messaging chip dragged out → restored to its original spot in the messaging area
            }
            syncConvertedCarrier()
        }
    }

    /// As soon as a strip card / messaging chip enters the drawer body, the carrier is swapped to the
    /// **drawer cell's bitmap** (the same whole cell as `drawerChipContent`, no badge), and the grab
    /// point is re-anchored to the pointer in proportion to the size; dragging out of the drawer body restores the one from drag start.
    /// The opposite direction (drawer icon converted into the strip) already swapped the image early
    /// (`DockStripView.syncConvertedCarrier`), and this direction had been missed: the carrier stayed a
    /// 40pt icon or even a 168pt titled card, overlapping the drawer edge (owner's screenshot, 2026-08-19).
    /// Only then can the frame of landing in the cell be pixel-identical: the bitmap must come from the same code that renders the cell.
    @State private var convertedCarrierID: String?
    private func syncConvertedCarrier() {
        let dc = dragController
        let converted = dc.isConvertedFromStrip || dc.isConvertedFromMessaging
        if converted, let p = dc.draggingPayload, p.source == .drawer {
            guard convertedCarrierID != p.id else { return }
            convertedCarrierID = p.id
            dc.setCarrierSnapshot(
                ChipSnapshotter.snapshot(of: drawerChipContent(p.id, running: showsAsRunning(p.id)),
                                         screenPoint: CGPoint(x: drawerRootScreenRect.midX, y: drawerRootScreenRect.midY)),
                reanchor: true)
        } else if !converted, convertedCarrierID != nil {
            convertedCarrierID = nil
            dc.setCarrierSnapshot(nil, reanchor: true)   // switch back to the one from drag start; if the drag has already ended it does nothing inside
        }
    }
}

// MARK: - Drawer drag-reorder preference

/// The second guard on an outside drag's make-way slot: closes it if neither a new pointer report
/// nor the drop arrives for a second (the receiver's own watchdog reports the end first). A
/// reference, so re-arming every ~50ms never re-renders the drawer.
private final class ExternalGhostExpiry {
    private var timer: Timer?

    func arm(_ expire: @escaping () -> Void) {
        timer?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: false) { [weak self] fired in
            DispatchQueue.main.async {
                // A newer report may have re-armed it between the fire and this turn.
                guard let self, self.timer === fired else { return }
                self.timer = nil
                expire()
            }
        }
        // `.common`: a drag session keeps the main run loop in event tracking.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
    }
}

/// A reference, so filling it while hovering never re-renders the drawer.
private final class ExternalCellImages {
    var cells: [String: (snapshot: CarrierSnapshot, image: DrawerDragImage)] = [:]
}

private struct DrawerChipFramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// The drawer's showings (`DrawerColumnHold`), owned by the coordinator so a rootView swap on a
/// limits change keeps the held count. `begin` must run before the opening's first measurement:
/// the published bump makes that render capture the count, so the first frame is the natural shape.
@MainActor
final class DrawerShowingModel: ObservableObject {
    @Published private(set) var showing = 0
    private var hold = DrawerColumnHold()

    func begin(plateOnScreen: Bool) {
        guard hold.begin(plateOnScreen: plateOnScreen) else { return }
        showing = hold.showing
    }

    /// At `orderOut`, not at the fade's start: a change during the fade must not reshape a plate
    /// still on screen, and reopening mid-fade keeps the columns.
    func end() { hold.end() }

    /// Written from `body`: a cache, not view state — nothing observes it.
    func heldCount(capturing settled: Int) -> Int? { hold.heldCount(capturing: settled) }
}

/// Root view of the drawer host: `DrawerView` + its eight environment objects.
///
/// Its only reason to exist is to give `PanelCoordinator` a **nameable** host type
/// `NSHostingView<DrawerRootView>`: the host is built only once and later only `rootView` is
/// swapped on each open (2026-09-04, the fix for dropped frames when the drawer pops open), while
/// the `DrawerView(...).environmentObject(...)` chain yields an unnameable `ModifiedContent<…>`.
struct DrawerRootView: View {
    let limits: StackGridLayout.Limits
    let arrow: StackPopupArrowModel
    let showing: DrawerShowingModel
    let onPanelSizeChange: (CGSize) -> Void
    let usesLiquidGlass: Bool
    let isDrawerOpen: () -> Bool
    let onPrimaryAction: () -> Void
    let onExternalDragHover: (Bool) -> Void
    let onDropApplications: ([URL], DrawerAppDrop.Placement) -> Void
    let onDropApplicationIDs: ([String], DrawerAppDrop.Placement) -> Void
    let runtime: AppRuntime
    let drawerStore: DrawerStore
    let messagingStore: MessagingAppStore
    let drawerOrderStore: DrawerOrderStore
    let dragController: DragController
    let keptAppStore: KeptAppStore
    let runningApplicationStore: RunningApplicationStore
    let appMembershipController: AppMembershipController

    var body: some View {
        DrawerView(limits: limits,
                   arrow: arrow,
                   showing: showing,
                   onPanelSizeChange: onPanelSizeChange,
                   usesLiquidGlass: usesLiquidGlass,
                   isDrawerOpen: isDrawerOpen,
                   onPrimaryAction: onPrimaryAction,
                   onExternalDragHover: onExternalDragHover,
                   onDropApplications: onDropApplications,
                   onDropApplicationIDs: onDropApplicationIDs)
            .environmentObject(runtime).environmentObject(drawerStore).environmentObject(messagingStore)
            .environmentObject(drawerOrderStore).environmentObject(dragController)
            .environmentObject(keptAppStore).environmentObject(runningApplicationStore)
            .environmentObject(appMembershipController)
    }
}
