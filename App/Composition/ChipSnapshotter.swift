import AppKit
import QuartzCore
import SwiftUI

/// Synchronously renders a chip into a bitmap, to be used by `DragController` as the floating copy.
///
/// **The snapshot must draw "the same view as the slot"**, otherwise the overlap on the drag-start frame and the handoff on the landing frame would both give it away.
/// The way to guarantee this is not to maintain a table of "which source draws which view" -- that would be a second source of truth needing manual sync,
/// and this repo has already been bitten twice by "a call site forgot to pass an argument yet it still compiled" (`ChipView.scale` silently rendering at the mid tier,
/// and the messaging area having no name bubbles at all). The approach: **the very view that renders the slot takes the snapshot itself, using the same function it
/// uses to render the slot** (`DockStripView.stripEntryContent` / `DrawerView.drawerChip`),
/// only passing "hover" as false. So "identical" holds by construction and cannot drift.
///
/// The implementation goes through `NSHostingView` + `cacheDisplay` and **does not use `ImageRenderer`**. Three measured conclusions:
/// (2026-08-18 spike, macOS 26.5):
///
/// 1. When `ImageRenderer` meets an `NSViewRepresentable`, it paints that whole rectangle opaque
///    placeholder yellow `(255, 204, 0)`. And `ChipView` has its own `.nativeContextMenu` (= `overlay(NativeMenuHost)`),
///    so the whole card turns into a yellow brick. In the four combinations, the two with a representable both have average alpha 255.
/// 2. `cacheDisplay` is completely immune to representables (the share of non-transparent pixels is identical with or without one),
///    keeps transparency, and **exists as far back as macOS 12** -- one path covers all deployment targets, with no version branching
///    and no need for a degraded drawing path for 12.
/// 3. Timing: median 0.59ms, P95 0.87ms (budget 8ms). First run 0.74ms, no cold-start penalty.
enum ChipSnapshotter {
    /// The extra margin left around the snapshot.
    ///
    /// The card's anti-aliased edge **overflows the layout frame**. On the strip that's fine (neighboring cards are right there and nobody clips it),
    /// but clipping the snapshot to the layout frame would cut it off, and the landing frame wouldn't match the card on the strip. 6pt is enough to hold the largest tier.
    static let bleed: CGFloat = 6

    /// The backing scale used for rendering: that of **the screen the slot is on**, no more and no less.
    ///
    /// "Take the largest among all screens" caused trouble (2026-08-19): an image captured at 2x was downscaled and resampled throughout the drag on a 1.6x external display,
    /// looking a bit blurrier than the card on the strip, and only became sharp when the last landing frame swapped in the real card. Bitmap pixels = this screen's pixels,
    /// and with the layer origin aligned to the pixel grid (`DragCarrierGeometry.pixelAligned`), CA moves pixels 1:1.
    ///
    /// What is really used is the backing scale **reported by the host window** (see `hostWindow(forScreenPoint:)`) -- that is the resolution at which the layer
    /// is actually rasterized, and the bitmap must match it; this function is only responsible for placing the window on the right screen.
    static func renderScale(forScreenPoint point: CGPoint) -> CGFloat {
        screen(forScreenPoint: point)?.backingScaleFactor.clampedToAtLeastOne ?? 2
    }

    private static func screen(forScreenPoint point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
    }

    /// Off-screen host window dedicated to snapshots. **Without a window it is guaranteed to be blurry.**
    ///
    /// The sublayers SwiftUI builds inside `NSHostingView` get their `contentsScale` from the **window**; when the view isn't in a window
    /// it is always `1.0`, so `cacheDisplay` goes through `CALayer.render(in:)`, rasterizing at 1x and then scaling up into the 2x rep --
    /// the copy throughout the drag is a bit blurrier than the card on the strip and only gets sharp when the real card swaps in at landing (owner 2026-08-19: "when dragging an icon
    /// the icon has a faint blur effect, which only disappears after landing").
    ///
    /// The 2026-08-19 spike measured each variant (same calendar icon, sharpness = Laplacian variance):
    /// - Directly `NSImage.draw` into a 2x context (theoretical upper bound): **5430**
    /// - The current approach, bare `NSHostingView` + `cacheDisplay`: **2274** (about as if blurred by sigma 0.5px)
    /// - Setting `contentsScale = 2` after capture: still 2274 -- **the content was already rasterized at 1x, changing the flag does nothing**
    /// - Setting `contentsScale` then `setNeedsDisplay` + `displayIfNeeded`: **0** (a completely empty image, worse)
    /// - Attaching to a window then capturing: **5430**, byte-for-byte identical to the upper bound
    ///
    /// The window is **never ordered on screen** (measurement shows that even off-screen it gives a backing scale of 2.0 and sharpness of 5430),
    /// so there is no risk of a flash; its only purpose is to give the layer a source for the backing scale. The same window is reused,
    /// to avoid building one for every snapshot.
    @MainActor
    private static func hostWindow(forScreenPoint point: CGPoint, fitting: CGSize) -> NSWindow {
        let window = sharedHostWindow ?? {
            let made = NSWindow(contentRect: CGRect(origin: .zero, size: defaultHostSize),
                                styleMask: [.borderless], backing: .buffered, defer: false)
            made.isOpaque = false
            made.backgroundColor = .clear
            made.hasShadow = false
            made.ignoresMouseEvents = true
            made.isExcludedFromWindowsMenu = true
            made.alphaValue = 0            // Double safeguard: even if it is wrongly ordered in someday, it is fully transparent
            made.contentView = NSView(frame: CGRect(origin: .zero, size: defaultHostSize))
            sharedHostWindow = made
            return made
        }()
        // **Only grow when it doesn't fit; don't resize every time.** Changing the window size requires a round trip to WindowServer:
        // measurement shows that calling `setContentSize` on every snapshot pushes the time from 0.6ms to 4.4ms (max 11.7ms, over the 8ms budget),
        // and this path runs on **mouse down** (`prepareCandidate`). Opening one big-enough canvas and reusing it avoids that cost.
        let current = window.contentView?.bounds.size ?? .zero
        if fitting.width > current.width || fitting.height > current.height {
            let grown = CGSize(width: max(fitting.width, current.width),
                               height: max(fitting.height, current.height))
            window.setContentSize(grown)
            window.contentView?.frame = CGRect(origin: .zero, size: grown)
        }
        // Move to the target screen: the backing scale follows the screen the window is on, and this step can't be skipped with mixed-resolution multi-screen setups.
        if let screen = screen(forScreenPoint: point), window.frame.origin != screen.frame.origin {
            window.setFrameOrigin(screen.frame.origin)
        }
        return window
    }
    @MainActor private static var sharedHostWindow: NSWindow?
    /// Initial canvas size: with room to spare for the largest-tier title card (about 200x70), so normally it never needs to grow.
    private static let defaultHostSize = CGSize(width: 400, height: 160)

    /// An app icon as a carrier bitmap, `side` points square at `scale` — the image an app dragged
    /// from outside shows, for the carrier that takes over from it on the capsule. No view renders
    /// it in the bar, so it is drawn directly rather than through a hosting view.
    static func iconSnapshot(of icon: NSImage, side: CGFloat, scale: CGFloat) -> CarrierSnapshot? {
        let pixels = Int((side * scale).rounded())
        guard pixels > 0,
              let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: pixels, height: pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        icon.draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage() else { return nil }
        let size = CGSize(width: side, height: side)
        return CarrierSnapshot(image: image, size: size, contentSize: size, scale: scale)
    }

    /// - Parameter screenPoint: The slot's position on screen (which screen's backing scale to use is decided by it).
    @MainActor
    static func snapshot<Content: View>(of content: Content, screenPoint: CGPoint) -> CarrierSnapshot? {
        let started = CACurrentMediaTime()
        let result = render(content, screenPoint: screenPoint)
        HoverTrace.carrierSnapshot(ms: (CACurrentMediaTime() - started) * 1000,
                                   width: result?.size.width ?? 0,
                                   height: result?.size.height ?? 0,
                                   ok: result != nil)
        return result
    }

    @MainActor
    private static func render<Content: View>(_ content: Content, screenPoint: CGPoint) -> CarrierSnapshot? {
        let host = NSHostingView(rootView: SnapshotRoot(content: AnyView(content)))
        // `fittingSize` **synchronously** forces SwiftUI layout (the launch first-frame transaction has long relied on this),
        // so what we get here is the size this card occupies on the strip, with no need to wait for the next run loop.
        let fitting = host.fittingSize
        guard fitting.width > 0, fitting.height > 0 else {
            dismantle(host)
            return nil
        }
        let logical = CGSize(width: fitting.width + 2 * bleed, height: fitting.height + 2 * bleed)
        // **Enter the window first, then lay out**: a sublayer's `contentsScale` is fixed at the moment it attaches to a window, so the reverse order is wasted effort
        // (for the rationale and measurements see `hostWindow(forScreenPoint:)`). The window size follows the card -- `contentView`
        // gets stretched by the window to the content size, so if the window size isn't set first, `host.frame` would be overwritten.
        let window = hostWindow(forScreenPoint: screenPoint, fitting: logical)
        // Attach as a **subview** rather than `contentView`: the latter gets stretched by the window to the content size, which would require resizing the window for every card.
        host.frame = CGRect(origin: .zero, size: fitting)
        window.contentView?.addSubview(host)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        defer { host.removeFromSuperview() }      // Release this tree, so it doesn't stay on the window across calls
        // **Take the bitmap resolution from what the window reports**, not from the screen: the layer is rasterized at this window scale, and the two must match,
        // otherwise we're back to resampling where "the bitmap and the layer are not 1:1".
        let scale = window.backingScaleFactor.clampedToAtLeastOne
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int((logical.width * scale).rounded()),
            pixelsHigh: Int((logical.height * scale).rounded()),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else {
            dismantle(host)
            return nil
        }
        // **Cannot use `bitmapImageRepForCachingDisplay(in:)`**: it decides the resolution from the screen the view is currently on (the main screen when not in a window),
        // which picks the wrong one in mixed-resolution multi-screen setups. Build the rep by hand and set `size` to the logical size so that the scale is up to us.
        rep.size = logical
        host.cacheDisplay(in: CGRect(x: -bleed, y: -bleed,
                                     width: logical.width, height: logical.height),
                          to: rep)
        dismantle(host)
        guard let drawn = rep.cgImage, let image = detached(drawn) else { return nil }
        // The layer's logical size takes "pixel count / scale" rather than `logical`: on a 1.6x screen 52pt is 83.2px and the bitmap can only be 83px,
        // so placing it at 52pt would require resampling; placing it at 83/1.6 = 51.875pt gives 1:1.
        let exact = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        return CarrierSnapshot(image: image, size: exact, contentSize: fitting, scale: scale)
    }

    /// **The bitmap must be copied into an image that owns its own backing store.**
    ///
    /// The `CGImage` returned by `NSBitmapImageRep.cgImage` **shares the pixel buffer** with that rep. The rep is a local variable here
    /// and is released as soon as it goes out of scope, so what `CALayer.contents` gets is an image pointing at freed memory --
    /// and the symptom is highly misleading: `contents != nil`, `bounds` / `position` / `opacity` / hierarchy are all correct,
    /// the self-check reports nothing, **yet nothing is on screen** (measured 2026-08-19: the carrier was invisible throughout the drag after it started,
    /// while the same code in the spike worked, because there the rep was still alive when the image was written to disk).
    ///
    /// `CGContext.makeImage()` returns a **snapshot** of the current bitmap that has its own backing store and no longer relates to the context.
    private static func detached(_ image: CGImage) -> CGImage? {
        guard let context = CGContext(data: nil, width: image.width, height: image.height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    /// **After capturing, this tree must be explicitly torn down.**
    ///
    /// Measured: an `NSHostingView` without a window still fires `onAppear`, but **never** fires `onDisappear`.
    /// `LauncherChip`'s launch bounce installs a `repeats: true` timer in `onAppear`
    /// and relies on `onDisappear` to clear it -- so every snapshot of a launching icon would leave behind a timer that never stops
    /// (in the spike, 5 snapshots ticked 40 times in 0.4 seconds). Set the root view's content to nil and force one more layout,
    /// and SwiftUI synchronously runs `onDisappear`; the bitmap already captured is unaffected.
    @MainActor
    private static func dismantle(_ host: NSHostingView<SnapshotRoot>) {
        host.rootView = SnapshotRoot(content: nil)
        host.layoutSubtreeIfNeeded()
    }
}

private extension CGFloat {
    /// Backing scale fallback: if 0 / negative comes back (shouldn't happen in theory), treat it as 1 so the bitmap size doesn't compute to 0.
    var clampedToAtLeastOne: CGFloat { self < 1 ? 1 : self }
}

/// A clearable host root view. Setting the content to nil means "this subtree is gone", so `onDisappear` gets a chance to run.
struct SnapshotRoot: View {
    var content: AnyView?

    var body: some View {
        ZStack { if let content { content } }
            // **The drag-copy switch is set in this one place only.** The four snapshot call sites go through
            // `stripEntryContent` / `drawerChipContent`, and those two helpers also render the real cards;
            // passing it as a parameter would mean adding parameters with default values to them -- "forgetting to pass still compiles" is exactly where this repo has fallen twice
            // (`ChipView.scale` silently using the mid tier, the messaging area having no name bubbles at all). Putting it here covers the existing four sites and any
            // snapshot added later automatically, so it can't be forgotten.
            //
            // The AGENTS note that "environment values can't refresh a long-lived hosting root" does not apply: the snapshot host is built and torn down fresh every time.
            .environment(\.isDragCarrierSnapshot, true)
    }
}
