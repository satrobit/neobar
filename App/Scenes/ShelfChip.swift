import AppKit
import SwiftUI

/// Transit shelf: a staging cell fixed at the head slot of the folder area.
/// Drop files onto the cell and release to stage them (references, no moving); click to pop up the staging grid. **Not draggable** (fixed head slot).
/// Visually it adopts the rounded-corner and shadow style of an ordinary app icon, no longer using the folder's stacked style.
/// The count has **no outward badge**; it becomes text in the hover name bubble, to avoid clashing with the "zero decoration" visual tone of the other chips in the fixed area.
struct ShelfChip: View {
    let itemCount: Int
    let isDropTargeted: Bool
    /// Scale factor for the strip size tier. Default tier = 1.0, at which all sizes are pixel-identical to the historical literals.
    /// **Deliberately no default value**: forgetting to pass it must be a compile error; see AGENTS "Taskbar Size Tiers".
    let scale: CGFloat
    /// Hover-effect tier. **Likewise deliberately no default value**: forgetting to pass it must be a compile error, same reason as `scale`.
    let hoverStyle: HoverStyle
    /// Whether the pointer is on this cell. Computed by the single tracking area covering the whole strip and passed in (see `StripHoverResolution`).
    let isHovered: Bool
    let onTap: () -> Void
    let onClear: () -> Void
    let onAddFolder: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    private var theme: DockThemeTokens { .resolved(for: colorScheme) }

    /// Master gate for hover visuals: always false in the "quiet" tier, so the icon doesn't shrink and the name bubble doesn't appear.
    /// Drop feedback (the brighten/stroke/glow of `isDropTargeted`) is not governed by it.
    private var showsHover: Bool { hoverStyle.showsExpressiveHover(isHovering: isHovered) }
    /// Hover feedback for the quiet tier (always false in the standard tier). See `HoverStyle.showsQuietHoverFeedback`.
    private var quietHoverFeedback: Bool {
        hoverStyle.showsQuietHoverFeedback(isHovering: isHovered)
    }

    /// The count used to be written only in the hover name, which doesn't appear in the quiet tier, so it is folded into the system tooltip fallback.
    /// It takes effect in both tiers and changes no pixels on the strip.
    private var helpText: String {
        itemCount > 0
            ? String(format: String(localized: "Shelf · %d — drag files here to park them"), itemCount)
            : String(localized: "Shelf — drag files here to park them")
    }

    var body: some View {
        VStack(spacing: 2 * scale) {
            Spacer(minLength: 0)
            shelfIcon
            Spacer(minLength: 0)
        }
        .frame(width: ChipPillMetrics.cardWidth * scale,
               height: ChipPillMetrics.chipHeight * scale)
        .chipQuietHoverScale(quietHoverFeedback,
                             cardWidth: ChipPillMetrics.cardWidth * scale,
                             scale: scale)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .nativeContextMenu { buildMenu() }
        .help(helpText)
        .animation(.easeInOut(duration: 0.18), value: showsHover)
        .animation(.easeInOut(duration: 0.12), value: isDropTargeted)
    }

    /// Fixed entry icon.
    ///
    /// **Must be an opaque solid block.** Before 2026-08-16 it was "a translucent tinted plate + a symbol",
    /// and the plate's fill in the light theme is **a darkened low-opacity** one: once the glass underneath gets dark, black on black disappears
    /// (the owner reported "the transit shelf is hard to see on a dark background"). Every other chip on the strip is an opaque full-color app icon,
    /// and this was the only one that wasn't, so it was the only one that vanished.
    ///
    /// The fix follows the native Dock's "Downloads": the same kind of material as its neighbors, opaque and full-color, rather than a translucent tinted plate.
    ///
    /// **The size must be drawn per `bareIconVisibleSlot` (32.5pt), not the slot's 40pt.** Apple's icon assets carry about 18%
    /// transparent margin, which is where the gap between icons on the strip comes from; our self-drawn graphic has no such margin,
    /// and drawing at 40 would look noticeably larger than its neighbors (half of the owner's "too abrupt" complaint was about size, not just color).
    ///
    /// The default tier is the vector self-drawn `ShelfTrayArt` (the owner supplied a reference image); the other three tiers are a "solid tile + SF symbol"
    /// fallback, swapped live with `DOCK_SHELF_TILE=graphite|blue|light` without recompiling.
    private var shelfIcon: some View {
        let art = ChipPillMetrics.bareIconVisibleSlot * scale
        let style = theme.effectiveShelfTile
        return Group {
            if style.isIllustration {
                ShelfTrayArt(size: art, lifted: isDropTargeted)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: art * 0.215, style: .continuous)
                        .fill(style.gradient(lifted: isDropTargeted))
                    Image(systemName: "tray.fill")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: art * 0.5, height: art * 0.5)
                        .foregroundStyle(style.glyphColor)
                }
                .frame(width: art, height: art)
            }
        }
        // The slot is still 40pt, consistent with all icon cards; only the drawn square shrinks to 32.5.
        .frame(width: ChipPillMetrics.bareIconSlot * scale,
               height: ChipPillMetrics.bareIconSlot * scale)
        // Like the icons, no outer drop shadow (owner, 2026-08-19). This block is more likely than an icon to make one want to "add a shadow to prop it up";
        // it already stands on opacity + a self-drawn plate (see `DockThemeTokens.shelfTile`), not on a shadow.
        .dockGlow(theme.shelfDropGlow, radius: 3, active: isDropTargeted)
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(String(localized: "Open Shelf")) { onTap() })
        if itemCount > 0 {
            menu.addItem(ClosureMenuItem(String(localized: "Clear Shelf")) { onClear() })
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(String(localized: "Add Folder…")) { onAddFolder() })
        return menu
    }
}
