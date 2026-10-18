import AppKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers

// DockStripView · hover ownership and name-bubble requests (one tracking area for the whole strip).
// Split out of DockStripView.swift as an extension on 2026-09-05; moved only, not changed.
extension DockStripView {
    // MARK: - Hover ownership (one tracking area for the whole strip)

    /// Re-decide "what is the pointer over", **writing `@State` only when the conclusion changed**.
    /// The decision is the pure function `StripHoverResolution`: in a gap, the nearer card edge by distance wins, independent of approach direction.
    ///
    /// The frame and origin are passed in explicitly rather than read from `self`: both are themselves `@State`, and inside the `onChange` /
    /// `onPreferenceChange` closures you read stale values.
    func refreshHoveredEntry(frames: [String: CGRect], origin: CGRect) {
        // For the first frame or two of a drag start, **freeze in place**: the carrier is pressed onto the card in the slot's current "hover x press" pose,
        // and if hover were cleared right then and the card started to fall back, the two would no longer match (owner 2026-08-19, "top/bottom ghosting").
        guard !dragController.hoverFrozen else { return }
        let resolved: String? = {
            guard !isPanelHeightResizing else { return nil }
            // Don't decide hover while holding something, and after landing **hold first, deciding only once the pointer actually moves**. Three reasons:
            // (1) lighting up whatever the pointer sweeps over during a drag, plus popping its name bubble, is wrong to begin with;
            // (2) the release position necessarily lands on the card that just settled -- the carrier draws the **non-hover** state,
            //    but the moment the card appears it is already in the hover state (the quiet tier also scales to 1.10), and the two differ in size,
            //    so the handoff frame "pops";
            // (3) re-deciding hover right after the card settles at 1.0 makes the quiet tier grow to 1.10 on the spot -- the icon has just stopped and moves again,
            //    which is the "landing jitter" the owner reported on 2026-08-19. AppKit itself, after a drag-and-drop ends, also
            //    sends mouseEntered only once the mouse moves. The hold period is managed by `DragController.hoverHoldPayload`.
            guard !dragController.hoverSuppressed else { return nil }
            // Experiment B: external drags (dragged in from Finder) likewise don't decide hover during the hover phase. Reason (1) above applies verbatim
            // -- lighting up whatever you sweep over while holding something, plus popping the name bubble, is wrong to begin with; and the bubble is a
            // floating panel, so whether repeatedly ordering it front / out during a drag disturbs the system's drag target is exactly what we want to test.
            guard !externalDropHoverActive else { return nil }
            // An app drop's hand-over (session over, gap still waiting for the real card): the gap
            // reports no hover frame, so the pointer in it would hand the bubble to a neighbour for
            // a few frames. `appDropGhostDidChange` re-resolves once the gap clears.
            guard appDropGhost == nil else { return nil }
            guard let pointer = pointerBox.value, origin != .zero else { return nil }
            let point = CGPoint(x: pointer.x - origin.minX, y: origin.maxY - pointer.y)
            let hit = StripHoverResolution.chip(
                at: point,
                frames: frames,
                gapBridge: StripHoverResolution.defaultGapBridge * dockScale
            )
            // The **one** card that is flying back / has just settled and is waiting for the pointer to move gets no hover; other cards behave as usual
            //(owner 2026-08-19: "while an icon is in flight, moving the mouse over other icons shows no hover effect"). See
            // `DragController.hoverExemptPayload` for the reason.
            if let exempt = dragController.hoverExemptPayload,
               carriedStripEntryID(for: exempt) == hit { return nil }
            return hit
        }()
        HoverTrace.stripInput("hoveredEntry", surface: stripSurfaceID, changed: resolved != hoveredEntryID)
        if resolved != hoveredEntryID { hoveredEntryID = resolved }
        // The bubble anchor is the one piece of geometry the body renders from; derive it here, at
        // the write, so geometry churn under no hover never touches `@State` (`StripFrameBox`).
        let anchor: CGRect? = {
            guard let resolved, origin != .zero, let frame = frames[resolved] else { return nil }
            return CGRect(x: origin.minX + frame.minX, y: origin.maxY - frame.maxY,
                          width: frame.width, height: frame.height)
        }()
        if anchor != hoveredAnchor { hoveredAnchor = anchor }
    }

    /// Bubble text for this entry. `nil` = this kind of chip pops no bubble.
    ///
    /// **It shows the app name, not the window title** (owner 2026-08-17; the native Dock's label only ever shows the app name).
    /// A pinned folder shows the folder's full name -- the card doesn't show a name; separators are not chips.
    private func bubbleTitle(for entry: StripEntry) -> String? {
        switch entry {
        case let .window(item):
            return appBubbleName(bundleID: item.bundleIdentifier, fallback: item.appID)
        case let .messagingApp(bid, _):
            return appBubbleName(bundleID: bid, fallback: bid)
        case let .keptApp(bid):
            return appBubbleName(bundleID: bid, fallback: bid)
        case .trash:
            return String(localized: "Trash")
        case .shelf:
            let count = shelfStore.itemPaths.count
            return count > 0
                ? String(format: String(localized: "Shelf · %d"), count)
                : String(localized: "Shelf")
        case let .pinnedFolder(path):
            return FileManager.default.displayName(atPath: path)
        case .divider, .externalDropGhost:
            // A gap never reports a hover frame, so this can't be reached; hard-coding nil is the second gate.
            return nil
        }
    }

    private func appBubbleName(bundleID: String?, fallback: String) -> String {
        let name = bundleID.map(AppDisplayNameResolver.displayName(for:)) ?? fallback
        return WindowDisplayTitle.resolve(rawTitle: nil, fallbackName: name)
    }

    /// What to give the bubble panel this frame. `nil` = dismiss the bubble.
    ///
    /// Derived wholesale from "pointer position + card geometry + tier", so anchor drift, app name changes and tier switches
    /// are all followed automatically, with no need for each card to re-send `.refresh` itself -- that "content-driven resend" and its
    /// ownership guard are gone, because now **only one party** can occupy this panel.
    ///
    /// The quiet tier pops no bubble (`hoverStyle.isExpressive`), consistent with the pre-refactor `showsHover` threshold.
    func bubbleRequest(projection: StripProjection) -> WindowTitleTooltipRequest? {
        guard !isPanelHeightResizing, hoverStyle.isExpressive,
              let id = hoveredEntryID,
              let anchor = hoveredAnchor,
              let entry = projection.entries.first(where: { $0.id == id }),
              let title = bubbleTitle(for: entry) else { return nil }
        return WindowTitleTooltipRequest(chipID: id, title: title, anchorVisibleRect: anchor)
    }

    /// Whether right-clicking the taskbar base should pop the NeoBar menu. The decision itself lives in the pure `StripContextMenuZone`;
    /// this only converts coordinates and gathers the frames of the four zones (the messaging zone / pinned folders / shelf frames each have their own
    /// PreferenceKey and are never merged into `chipFrames`).
    func taskbarMenuZoneClaims(atScreen global: CGPoint) -> Bool {
        guard let point = stripPoint(from: global) else { return false }
        return StripContextMenuZone.claims(
            point: point,
            chipFrames: allStripChipFrames(),
            bounds: CGRect(origin: .zero, size: stripRootScreenRect.size),
            minimumGapWidth: StripContextMenuZone.defaultMinimumGapWidth * dockScale
        )
    }

    /// Drag-to-resize grip (and its ▲▼ glyph): the right-click zones kept clear of the chips.
    func resizeGripZoneClaims(atScreen global: CGPoint) -> Bool {
        // A make-way gap reports no card frame, so it reads as an empty gap here — and right after a
        // drop the pointer rests in it until the landed card arrives, flashing the ▲▼ cursor.
        guard externalDropGhost == nil else { return false }
        guard let point = stripPoint(from: global) else { return false }
        return StripContextMenuZone.gripClaims(
            point: point,
            chipFrames: allStripChipFrames(),
            bounds: CGRect(origin: .zero, size: stripRootScreenRect.size),
            minimumGapWidth: StripContextMenuZone.defaultMinimumGapWidth * dockScale,
            chipClearance: StripContextMenuZone.defaultGripChipClearance * dockScale
        )
    }

    /// ▲▼ hover only: the grip predicate, but never while the left button is already held. A press
    /// that began anywhere else — a card or drawer-icon drag, a file dragged in, a press still under
    /// the 8pt drag threshold — cannot turn into a resize, so the glyph would promise a drag that
    /// isn't there. A grip press is unaffected: the coordinator ignores hover during its drag, and
    /// `finishDrag` re-reports hover directly, not through here.
    func resizeGripHoverClaims(atScreen global: CGPoint) -> Bool {
        guard NSEvent.pressedMouseButtons & 1 == 0, dragController.draggingPayload == nil else { return false }
        return resizeGripZoneClaims(atScreen: global)
    }

    private func allStripChipFrames() -> [CGRect] {
        var frames = Array(chipFrames.values)
        frames.append(contentsOf: folderChipFrames.values)
        frames.append(contentsOf: messagingChipFrames.values)
        if shelfFrame != .zero { frames.append(shelfFrame) }
        if settingsStore.showTrash, trashFrame != .zero { frames.append(trashFrame) }
        return frames
    }
}
