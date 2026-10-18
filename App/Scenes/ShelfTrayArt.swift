import SwiftUI

/// How the transit shelf's icon is drawn: a dark storage bag + a few white sheets of paper peeking above its top edge (the reference image designated by the owner on 2026-08-16).
///
/// **It is vector self-drawn, not a texture.** First, all four scale tiers must be sharp; second, the reference image is a render of unknown origin,
/// and someone else's icon assets must not be packaged into the app. So it is redrawn here following the reference's
/// structure: back plate + three sheets + front bag; proportions are all normalized to the side length, so changing size needs no retuning.
///
/// The size is given by the caller (`ChipPillMetrics.bareIconVisibleSlot`) and fills the whole canvas; the transparent margin outside
/// is the caller's slot's responsibility, aligned with Apple's icon assets.
struct ShelfTrayArt: View {
    let size: CGFloat
    /// Brighten as a whole when external files are dragged onto the cell.
    var lifted: Bool = false

    var body: some View {
        ZStack {
            backPlate
            papers
            frontPocket
        }
        .frame(width: size, height: size)
        .brightness(lifted ? 0.08 : 0)
    }

    // MARK: Back plate

    private var backPlate: some View {
        RoundedRectangle(cornerRadius: size * 0.215, style: .continuous)
            .fill(LinearGradient(
                colors: [Color(white: 0.30), Color(white: 0.19)],
                startPoint: .top,
                endPoint: .bottom
            ))
    }

    // MARK: Paper

    /// Three white sheets: the middle one is tallest, the two sides slightly shorter and tilted outward, the fan in the reference image.
    /// Drawn within the back plate's bounds and clipped as a whole, so that the tilted corners don't poke out past the rounded corners.
    private var papers: some View {
        ZStack {
            paper(offsetX: -0.085, offsetY: 0.010, rotation: -7, scale: 0.94)
            paper(offsetX: 0.085, offsetY: 0.020, rotation: 7, scale: 0.94)
            paper(offsetX: 0, offsetY: -0.005, rotation: 0, scale: 1)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.215, style: .continuous))
    }

    private func paper(offsetX: CGFloat, offsetY: CGFloat, rotation: Double, scale: CGFloat) -> some View {
        let width = size * 0.46 * scale
        let height = size * 0.56 * scale
        return RoundedRectangle(cornerRadius: size * 0.05, style: .continuous)
            .fill(LinearGradient(
                colors: [Color(white: 0.99), Color(white: 0.90)],
                startPoint: .top,
                endPoint: .bottom
            ))
            .frame(width: width, height: height)
            .rotationEffect(.degrees(rotation))
            // The lower half of the paper is covered by the front bag, so the whole thing is shifted up: only the top edge shows.
            .offset(x: size * offsetX, y: size * (offsetY - 0.10))
    }

    // MARK: Front bag

    /// The front bag is translucent dark gray, and its top edge is the "high on the left, low on the right, then curving back" curve in the reference image.
    /// Translucency is the key: the paper showing through a little from behind it is what gives the "inside a bag" layering.
    private var frontPocket: some View {
        PocketShape()
            .fill(LinearGradient(
                colors: [Color(white: 0.46).opacity(0.94), Color(white: 0.22).opacity(0.97)],
                startPoint: .topLeading,
                endPoint: .bottom
            ))
            .frame(width: size, height: size)
    }
}

/// Front bag outline. All control points are normalized coordinates (0…1 times the side length), laid out following the reference image's direction.
private struct PocketShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + w * x, y: rect.minY + h * y) }

        let radius = w * 0.19
        var path = Path()
        // Start at the top-left corner and go right along the top edge: first gently, then dip down, and finally curve back slightly to the right side.
        path.move(to: p(0.045, 0.345))
        path.addCurve(to: p(0.52, 0.395), control1: p(0.20, 0.300), control2: p(0.36, 0.345))
        path.addCurve(to: p(0.955, 0.455), control1: p(0.68, 0.445), control2: p(0.83, 0.505))
        // Down the right side → bottom rounded corner → left side back to the start.
        path.addLine(to: p(0.955, 0.80))
        path.addQuadCurve(to: p(0.955 - radius / w, 0.955), control: p(0.955, 0.955))
        path.addLine(to: p(0.045 + radius / w, 0.955))
        path.addQuadCurve(to: p(0.045, 0.80), control: p(0.045, 0.955))
        path.closeSubpath()
        return path
    }
}
