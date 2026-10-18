import AppKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Strip Entrance Modifier

struct StripEntranceModifier: ViewModifier {
    /// `nil` = skip the entrance animation this time. **The carrier snapshot takes this path**: the entrance `@State` starts from
    /// `opacity 0 / offset 8` and only flips to its final value in `onAppear`, while the snapshot is taken synchronously;
    /// if not disabled, the snapshot would come out as a semi-transparent image shifted up by 8pt.
    let id: String?
    let delay: Double
    @Binding var animatedEntryIDs: Set<String>

    @State private var isAppeared = false

    @ViewBuilder
    func body(content: Content) -> some View {
        if let id {
            animated(content, id: id)
        } else {
            content
        }
    }

    private func animated(_ content: Content, id: String) -> some View {
        content
            .offset(y: isAppeared ? 0 : 8)
            .opacity(isAppeared ? 1 : 0)
            .onAppear {
                if animatedEntryIDs.contains(id) {
                    isAppeared = true
                } else {
                    // Stagger the first-frame layout to avoid flying in from the coordinate origin
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8).delay(delay)) {
                            isAppeared = true
                        }
                        animatedEntryIDs.insert(id)
                    }
                }
            }
    }
}

// MARK: - Dropped App Landing Grow

/// An app dropped in from Finder grows up from its icon's bottom and fades in — the native Dock's
/// entrance, fitted to a 60fps recording (near-linear, easing out at the end, ~0.23s). No delay of
/// our own: the native ~0.1s beat after release is already spent by our landing path.
///
/// Applied **inside** the hover-frame / chip-frame readers, never as the `ForEach` transition: a
/// scale there shrinks the reported frames too, so the pointer misses the new card (late bubble)
/// and every frame of the growth re-resolves hover and re-renders the strip.
struct DroppedAppLandingGrow: ViewModifier {
    /// True only for a card a drop just added. Flipping it later changes nothing: the values below
    /// are both 1 once grown, and no branch switches (that would rebuild the card).
    let active: Bool
    @State private var grown = false

    func body(content: Content) -> some View {
        let shown = grown || !active
        content
            .scaleEffect(shown ? 1 : 0.01,
                         anchor: UnitPoint(x: 0.5, y: ChipPillMetrics.visibleIconBottomFraction))
            .opacity(shown ? 1 : 0)
            .onAppear {
                guard active else { return }
                withAnimation(.timingCurve(0.4, 0.4, 0.7, 1.0, duration: 0.23)) { grown = true }
            }
    }
}

extension View {
    func stripEntrance(id: String?, delay: Double, animatedEntryIDs: Binding<Set<String>>) -> some View {
        self.modifier(StripEntranceModifier(id: id, delay: delay, animatedEntryIDs: animatedEntryIDs))
    }
}
