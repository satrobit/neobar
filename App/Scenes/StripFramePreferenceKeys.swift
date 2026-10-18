import AppKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers

/// Hover hit frames (`StripEntry.id` -> frame in the "strip" space). **Cards from all four zones go into this one dictionary** -- it answers
/// "who is the pointer over", which was never zone-specific to begin with. It is likewise independent of the other three: those three feed reordering / popup anchors /
/// release decisions respectively, with different semantics, and merging would contaminate each other (the old lesson of review P1).
struct StripHoverFramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// Folder chip frames (popup anchor + external-drag pin routing). Independent of ChipFramePreferenceKey -- the latter is the input for
/// drag reordering / drop-target hit testing in the live window zone, and mixing folder ids in would treat them as drop targets (review P1).
struct FolderChipFramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// Messaging-area chip frames (bundleID -> frame). Independent of ChipFramePreferenceKey -- same reason as the folder chip:
/// mixing into the live reorder / drop-target hit input would make a window drag hit the messaging area, with the drop being a no-op.
struct MessagingChipFramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// Staging cell frame (single value). Independent of FolderChipFramePreferenceKey (review: the folder frame dictionary does not mix in a sentinel).
struct ShelfFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

struct TrashFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

// MARK: - Where the reported geometry lives

/// Every frame the strip reports about itself — the four per-zone chip-frame tables, the shelf and
/// trash frames and the content area's screen rect — lives here, in one reference box held by
/// `DockStripView` as `@State var frames`, **never as `@State` values of its own**.
///
/// The reason is the write frequency: during a make-way spring, a slot collapse / reopen or the
/// panel re-centering, every one of these changes on **every animation frame**, and a `@State`
/// write re-evaluates the whole strip (`makeProjection`, order reconcile, twenty chips). Writing a
/// property of a class held in `@State` invalidates nothing, so the geometry can update at frame
/// rate while the body only re-runs for model changes. Everything that reads geometry does so at
/// event time (reorder hit-tests, landing anchors, hover resolution, drop routing, popup anchors)
/// and reads the box directly — always the latest value, never a copy captured by an earlier body.
/// The one rendering input derived from geometry, the hover bubble's anchor, is written separately
/// as `DockStripView.hoveredAnchor` only when the hovered card's screen frame actually moves.
@MainActor
final class StripFrameBox {
    /// Live chip frames by id in the `"strip"` space — the drag-reorder hit-test and landing input.
    var chipFrames: [String: CGRect] = [:]
    /// Hover hit frames for every zone's cards (`StripEntry.id` → frame): "who is under the pointer".
    var stripHoverFrames: [String: CGRect] = [:]
    /// Pinned-folder chip frames — popup anchors, external pin routing, in-zone reorder. Never merged
    /// into `chipFrames` (a folder id there becomes a landing target).
    var folderChipFrames: [String: CGRect] = [:]
    /// Messaging chip frames by bundle id — in-zone reorder and the drawer→messaging release range.
    var messagingChipFrames: [String: CGRect] = [:]
    var shelfFrame: CGRect = .zero
    var trashFrame: CGRect = .zero
    /// The content area's frame in screen coordinates (bottom-left); `.zero` until first reported.
    var stripRootScreenRect: CGRect = .zero
    /// The `stripSlotCollapsed` value the last committed body rendered. Written from
    /// `.onChange(of: stripSlotCollapsed)` — the same moment the old `@State` copy was written, so the
    /// body that first sees the flip still picks the collapse curve — but as a box field the write
    /// itself no longer re-evaluates the strip (that echo body rendered nothing new).
    var renderedCollapsed = false
    /// The app make-way gap (`.live` zone only) the last committed body rendered, written in
    /// `.onChange(of: externalDropGhost)` after it is compared — the old value that picks the
    /// panel-matched curve and tells the panel to re-measure. Folder gaps are never stored here.
    var renderedAppGhost: StripDropGhost?
}

// MARK: - Drag-reorder preference (taskbar drag-reorder, route A, custom-drawn drag)

/// Collects live chip frames by id in the `"strip"` space — feeds the floating drag copy's
/// position and the left/right-half landing decision (replaces the old width-only key + the
/// SwiftUI DropDelegates, now that the drag is a self-rendered in-app gesture).
struct ChipFramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
