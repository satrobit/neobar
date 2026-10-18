import AppKit
import SwiftUI

/// Where the popup's arrow points. The coordinator owns it and rewrites it with every frame it
/// gives the popup window: once the plate is clamped at a screen edge it is no longer centred on
/// its chip, and the arrow has to stay on the chip.
@MainActor
final class StackPopupArrowModel: ObservableObject {
    /// Arrow centre minus plate centre, in points.
    @Published var offsetFromCenter: CGFloat = 0
    /// Bumped by a host that outlives one showing (the drawer) each time the plate goes away:
    /// a scrolled grid is rebuilt at its top while nobody is looking, never at the next open.
    @Published var scrollGeneration = 0
}

/// What the coordinator knows and a popup's content needs: how large the grid may get on this
/// screen, and the arrow.
struct StackPopupContext {
    let limits: StackGridLayout.Limits
    let arrow: StackPopupArrowModel
}

/// Whose appearance a stack plate takes. The folder, shelf and Trash popups follow the system's
/// (macOS 27's native stack is light glass with dark text in light mode); the drawer stays dark.
enum StackPopupAppearance {
    case followsAppearance
    case alwaysDark
}

/// The frame shared by the folder, shelf and Trash popups, laid out like the native Dock's stack
/// grid: title row, optional status line, grid, and the plate with its arrow. Width and height are
/// derived from `layout` — never measured.
struct StackPopupChrome<Grid: View>: View {
    let title: String
    /// A line between title and grid; the native grid has none (empty shelf, Trash state).
    let note: String?
    let layout: StackGridLayout.Result
    /// The plate's frame and cells (`StackPlateMetrics`). No default: the plate's size derives from it.
    let plate: StackPlateMetrics
    let usesLiquidGlass: Bool
    /// No default: an omission must not compile into the wrong appearance.
    let appearance: StackPopupAppearance
    @ObservedObject var arrow: StackPopupArrowModel
    /// The popup window's new size whenever the plate's changes. No default: without it the
    /// window stops following its content.
    let onPanelSizeChange: (CGSize) -> Void
    /// Non-nil shows the back button (drilled into a subfolder).
    var onBack: (() -> Void)?
    /// Animates cells arriving and leaving; nil while the first population lands.
    var gridAnimation: Animation?
    var gridAnimationKey: [String] = []
    /// The cells; they land in a `LazyVGrid` of `layout.columns` fixed columns.
    @ViewBuilder let grid: () -> Grid

    @Environment(\.colorScheme) private var environmentScheme
    /// The chrome's own title, note, separator and back button read this, not the environment:
    /// the `.dark` it puts on its content does not reach back up to itself.
    private var colorScheme: ColorScheme { appearance == .alwaysDark ? .dark : environmentScheme }
    private var theme: DockThemeTokens { .resolved(for: colorScheme) }
    private typealias Metrics = StackPopupMetrics

    private var plateSize: CGSize {
        plate.plateSize(columns: layout.columns, rows: layout.visibleRows, hasNote: note != nil, scrolls: layout.scrolls)
    }
    private var gridWidth: CGFloat { CGFloat(layout.columns) * plate.cell.cellSize.width }
    private var gridHeight: CGFloat { CGFloat(layout.visibleRows) * plate.cell.cellSize.height }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if plate.hasSeparator { separator }
            Color.clear.frame(height: plate.gridTop - plate.headerHeight - (plate.hasSeparator ? 1 : 0))
            if let note { noteLine(note) }
            gridArea
        }
        .frame(width: plateSize.width, height: plateSize.height, alignment: .top)
        // The plate is what the window leaves for it, not `plateSize`: while the coordinator
        // tweens the window to a new content size the plate changes with it and stays on the
        // chip. The content keeps its final layout, rides the plate's top edge and is clipped by
        // it. The ideal size is still the content's, which is what `fittingSize` reports.
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous))
        .background {
            GeometryReader { proxy in
                StackPopupBackdrop(plateSize: proxy.size,
                                   arrowCenterX: proxy.size.width / 2 + arrow.offsetFromCenter,
                                   usesLiquidGlass: usesLiquidGlass,
                                   forcesDark: appearance == .alwaysDark)
            }
        }
        .padding(.bottom, Metrics.arrowHeight)
        .padding(Metrics.panelMargin)
        .modifier(StackPopupSchemeModifier(appearance: appearance))
        // Derived, not measured: `fittingSize` read inside this update returns zero.
        .onChange(of: plateSize) { onPanelSizeChange(Metrics.panelSize(forPlate: $0)) }
    }

    private var header: some View {
        Text(title)
            .font(.system(size: Metrics.titleSize))
            .foregroundStyle(theme.stackPopupText.color)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 44)
            .frame(width: plateSize.width, height: plate.headerHeight)
            .offset(y: plate.titleCenterY - plate.headerHeight / 2)
            .overlay(alignment: .topLeading) { backButton }
    }

    private var separator: some View {
        theme.stackPopupSeparator.color
            .frame(height: 1)
            .padding(.horizontal, plate.sidePadding)
            .frame(width: plateSize.width)
    }

    @ViewBuilder
    private var backButton: some View {
        if let onBack {
            Group {
                if let art = NativeStackArtwork.backButton(dark: colorScheme == .dark) {
                    // Dark art is a grey plate added onto the glass, light art a white one
                    // darkened onto it: either way only the chevron shows.
                    Image(nsImage: art).blendMode(colorScheme == .dark ? .plusLighter : .plusDarker)
                } else {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.stackPopupText.color)
                        .frame(width: Metrics.backButtonSize.width, height: Metrics.backButtonSize.height)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(theme.stackPopupBackFill.color))
                }
            }
            .frame(width: Metrics.backButtonSize.width, height: Metrics.backButtonSize.height)
            // A 21pt target is the native size; the hit area reaches the plate's corner.
            .padding(.leading, Metrics.backButtonOrigin.x)
            .padding(.top, Metrics.backButtonOrigin.y)
            .padding([.trailing, .bottom], 6)
            .contentShape(Rectangle())
            .onTapGesture(perform: onBack)
            .help(Text("Back"))
        }
    }

    private func noteLine(_ text: String) -> some View {
        Text(text)
            .font(.system(size: Metrics.labelSize))
            .foregroundStyle(theme.stackPopupNote.color)
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, plate.sidePadding)
            .frame(width: plateSize.width, height: Metrics.noteHeight)
    }

    @ViewBuilder
    private var gridArea: some View {
        let columns = Array(repeating: GridItem(.fixed(plate.cell.cellSize.width), spacing: 0), count: layout.columns)
        let cells = LazyVGrid(columns: columns, alignment: .leading, spacing: 0, content: grid)
            .frame(width: gridWidth, alignment: .leading)
            .animation(gridAnimation, value: gridAnimationKey)
        if layout.scrolls {
            ScrollView(.vertical, showsIndicators: true) {
                // Flexible, not the scroll view's width: an always-shown scroller takes its width
                // out of the content area, and wider content would be centred, sliding the grid left.
                cells.frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: gridWidth + plate.scrollerGutter,
                   height: gridHeight + (plate.scrollsToBottomEdge ? plate.bottomPadding : 0))
            .padding(.leading, plate.sidePadding)
            .id(arrow.scrollGeneration)
        } else {
            cells
                .frame(height: gridHeight, alignment: .top)
                .padding(.leading, plate.sidePadding)
        }
    }
}

/// The drawer's plate is dark whatever the system's appearance: its cells, text tokens and the
/// system scroller's knob read `.dark` there. The other popups take the window's appearance.
private struct StackPopupSchemeModifier: ViewModifier {
    let appearance: StackPopupAppearance

    func body(content: Content) -> some View {
        switch appearance {
        case .alwaysDark: content.environment(\.colorScheme, .dark)
        case .followsAppearance: content
        }
    }
}
