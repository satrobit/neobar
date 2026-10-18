import CoreGraphics
import Foundation

/// Which stored rendition of an icon feeds the exact-pixel bitmap a chip shows, and which
/// already-rendered bitmap stands in while new sizes may not be rendered (a height drag).
///
/// SwiftUI alone picks a rendition by pixel count and lets the layer scale it with a bilinear
/// filter: at 1x that is a 2x rendition of small-size artwork (soft), and a single-rep image is
/// minified from its full size (aliased). Rendering at the exact pixel size ourselves sidesteps both.
enum IconRenditionChoice {
    struct Rendition: Equatable {
        /// Nominal point size of the rendition (the artwork size it was drawn for).
        let points: CGFloat
        /// Pixel edge of the stored bitmap.
        let pixels: Int

        /// Display scale the rendition was drawn for (`pixels / points`).
        var scale: CGFloat { points > 0 ? CGFloat(pixels) / points : 0 }
    }

    /// Pixel edge of a square of `points` at `displayScale`.
    static func pixels(points: CGFloat, displayScale: CGFloat) -> Int {
        max(1, Int((points * displayScale).rounded()))
    }

    /// Index of the rendition to downsample from, mirroring IconServices: the **smallest point
    /// size** that covers the target (its artwork is the one drawn for sizes near the target),
    /// among those the one drawn for the same display scale, else the most pixels. A rendition
    /// must also cover the target in pixels so the result is never an upscale. Nothing covers →
    /// the largest rendition. `nil` only for an empty list.
    static func sourceIndex(in renditions: [Rendition], points: CGFloat, displayScale: CGFloat) -> Int? {
        guard !renditions.isEmpty else { return nil }
        let targetPixels = pixels(points: points, displayScale: displayScale)
        let covering = renditions.indices.filter {
            renditions[$0].points >= points && renditions[$0].pixels >= targetPixels
        }
        guard let smallestPoints = covering.map({ renditions[$0].points }).min() else {
            return renditions.indices.max { renditions[$0].pixels < renditions[$1].pixels }
        }
        let atThatSize = covering.filter { renditions[$0].points == smallestPoints }
        let sameScale = atThatSize.filter { abs(renditions[$0].scale - displayScale) < 0.01 }
        let pool = sameScale.isEmpty ? atThatSize : sameScale
        return pool.max { renditions[$0].pixels < renditions[$1].pixels }
    }

    /// Stand-in while rendering is paused: the smallest rendered size that still covers the
    /// target (the layer downscales it a little), else the largest one rendered so far.
    static func standInPixels(rendered: [Int], target: Int) -> Int? {
        if let covering = rendered.filter({ $0 >= target }).min() { return covering }
        return rendered.max()
    }
}
