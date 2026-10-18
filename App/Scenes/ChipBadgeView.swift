import AppKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Chip Badge

/// Classic Dock-style unread badge: red capsule, white text, top-right of the chip.
/// Renders whatever string the app put on its Dock tile ("3", "99+", "•") as-is.
/// Not a hit target — taps fall through to the chip underneath.
///
/// **It is drawn by the chip itself (the overlay of `ChipView.bareIconChip` / `LauncherChip`), not layered on by the caller
/// wrapping it in a ZStack.** Before 2026-08-17 it was the latter, so it sat **outside** `chipQuietHoverScale`:
/// on a quiet-tier hover the icon scaled up 10% while the red dot didn't budge (the owner measured 16x15pt in both frames),
/// which looked like the icon bulging out from under the red dot. Now that it lives inside the chip, hover scale-up, press shrink, and tier scaling all carry it along.
///
/// Size constants are in `ChipPillMetrics.badge*`; the medium tier is verbatim identical to the historical literals.
struct ChipBadgeView: View {
    let text: String
    /// Tier factor. **Deliberately no default value** -- the same iron rule as `scale` / `hoverStyle`.
    let scale: CGFloat

    var body: some View {
        Text(text)
            .font(.system(size: ChipPillMetrics.badgeFontSize * scale, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, ChipPillMetrics.badgeHorizontalPadding * scale)
            .frame(minWidth: ChipPillMetrics.badgeMinimumSize * scale,
                   minHeight: ChipPillMetrics.badgeMinimumSize * scale)
            .background(
                Capsule().fill(Color(red: 1.0, green: 0.23, blue: 0.19))   // Apple badge red
            )
            .overlay(
                // 0.5pt is a hairline; like the divider line, it doesn't scale with the tier.
                Capsule().strokeBorder(.black.opacity(0.25), lineWidth: 0.5)
            )
            // A native badge mostly overlaps the icon and sticks out only slightly past the rounded corner: card 40x54, visible icon square 32.5,
            // and this downward offset lands the badge center just inside the icon's top-right corner.
            .offset(x: 0, y: ChipPillMetrics.badgeTopOffset * scale)
            .allowsHitTesting(false)
    }
}
