import AppKit
import QuartzCore

/// One cell of a fan: a file or subfolder of the stack, or the top cell that opens the folder in
/// Finder ("Open in Finder" / "N More in Finder").
struct StackFanItem {
    enum Kind {
        case entry(FolderContentsLoader.Entry)
        case openInFinder
    }

    let kind: Kind
    let title: String
}

/// The native Dock's fan, built in AppKit + Core Animation as the Dock builds it: every item flies
/// along the R = 3000 arc out of the stack's pile, its name capsule grows out of its left edge,
/// its shadow fades in; closing runs it back. Drawn in **screen coordinates**: the view's bounds
/// origin is kept at its window's origin, so the window can be resized under the items (the
/// flight needs it to reach down over the chip, the rest does not) without moving them.
@MainActor
final class StackPopupFanView: NSView, NSDraggingSource {
    struct Actions {
        /// An item was clicked (index into `items`).
        let activate: (Int) -> Void
        /// A click off the icons — a capsule or a gap — is a click outside.
        let dismiss: () -> Void
        /// The context menu of an entry item; nil = none.
        let menu: (Int) -> NSMenu?
    }

    private let items: [StackFanItem]
    let layout: StackFanLayout
    /// Where each item flies from and back to: its layer of the chip's cover pile.
    private let pileRects: [CGRect]
    private let actions: Actions
    private var itemViews: [FanItemView] = []
    /// Clicks count only once the fan has landed; the window ignores the mouse before that.
    var isInteractive = false
    private var pressedIndex: Int?
    private var pressLocation: CGPoint = .zero

    init(items: [StackFanItem], layout: StackFanLayout, pileRects: [CGRect], windowFrame: CGRect,
         actions: Actions) {
        self.items = items
        self.layout = layout
        self.pileRects = pileRects
        self.actions = actions
        super.init(frame: CGRect(origin: .zero, size: windowFrame.size))
        wantsLayer = true
        layerUsesCoreImageFilters = true
        bounds.origin = windowFrame.origin
        for (index, item) in items.enumerated() {
            let view = FanItemView(item: item, layoutItem: layout.items[index])
            // The first item on top, as in the chip's pile: landing back on it in the reverse
            // order shows the back layers' bottoms over the front one.
            addSubview(view, positioned: .below, relativeTo: itemViews.last)
            itemViews.append(view)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { false }

    /// Keeps the items where they are on screen while the window takes `frame`.
    func windowWillTake(_ frame: CGRect) {
        setFrameSize(frame.size)
        bounds.origin = frame.origin
    }

    // MARK: Animation

    /// The fan flies open. `completion` runs when the flight ends (at once with reduced motion).
    func playOpen(reducedMotion: Bool, completion: @escaping () -> Void) {
        layoutSubtreeIfNeeded()
        // The landed pose is the model, animated or not (reduced motion only skips the flight).
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        itemViews.forEach { $0.settle() }
        CATransaction.commit()
        guard !reducedMotion else {
            completion()
            return
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        for (index, view) in itemViews.enumerated() {
            view.addOpenAnimation(from: pileRects[index], to: layout.items[index])
        }
        CATransaction.commit()
    }

    /// The fan flies back into the pile. `stackShown` = the chip shows its pile ("Display as:
    /// Stack"): the first three items stay opaque and land on it, the rest fade in the last 0.1s;
    /// otherwise every item fades from a third of the way on.
    func playClose(stackShown: Bool, completion: @escaping () -> Void) {
        isInteractive = false
        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        for (index, view) in itemViews.enumerated() {
            let fade: FanItemView.CloseFade
            if case .openInFinder = items[index].kind {
                fade = .inFlight
            } else if stackShown {
                fade = index < FolderCoverPile.depths.count ? .none : .late
            } else {
                fade = .early
            }
            view.addCloseAnimation(to: pileRects[index], from: layout.items[index], fade: fade)
        }
        CATransaction.commit()
    }

    // MARK: Mouse

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Every click is the fan's to sort out: an icon, or "outside".
        frame.contains(point) ? self : nil
    }

    private func screenPoint(_ event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    override func mouseDown(with event: NSEvent) {
        guard isInteractive else { return }
        let point = screenPoint(event)
        guard let index = layout.itemIndex(at: point) else {
            actions.dismiss()
            return
        }
        pressedIndex = index
        pressLocation = point
        itemViews[index].setPressed(true)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let index = pressedIndex else { return }
        let point = screenPoint(event)
        guard hypot(point.x - pressLocation.x, point.y - pressLocation.y) > 4 else { return }
        itemViews[index].setPressed(false)
        pressedIndex = nil
        guard case let .entry(entry) = items[index].kind else { return }
        let dragItem = NSDraggingItem(pasteboardWriter: entry.url as NSURL)
        let iconFrame = convert(itemViews[index].iconFrameInFan, from: itemViews[index].superview)
        dragItem.setDraggingFrame(iconFrame, contents: itemViews[index].dragImage)
        beginDraggingSession(with: [dragItem], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        guard let index = pressedIndex else { return }
        itemViews[index].setPressed(false)
        pressedIndex = nil
        if layout.itemIndex(at: screenPoint(event)) == index { actions.activate(index) }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard isInteractive else { return }
        guard let index = layout.itemIndex(at: screenPoint(event)) else {
            actions.dismiss()
            return
        }
        if let menu = actions.menu(index) {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .move, .link, .generic] : [.copy, .move, .generic]
    }

    // MARK: Icons arriving late

    /// Swaps in QuickLook thumbnails as they arrive (the type icons were warmed before showing).
    func loadThumbnails(scale: CGFloat) {
        for (index, item) in items.enumerated() {
            guard case let .entry(entry) = item.kind, !entry.isDirectory else { continue }
            let id = FolderIconResolver.ThumbnailID(path: entry.url.path, stamp: entry.dateModified,
                                                     scale: scale, side: StackFanLayout.itemSide)
            if let hit = FolderIconResolver.cachedThumbnail(id) {
                itemViews[index].setIcon(hit)
                continue
            }
            Task { @MainActor [weak self] in
                await FolderIconResolver.loadThumbnail(id)
                guard let self, let image = FolderIconResolver.cachedThumbnail(id) else { return }
                self.itemViews[index].setIcon(image)
            }
        }
    }
}

/// One fan item: shadow, icon (or the top cell's round plate and glyph) and name capsule, all
/// turned with the item. The view is the item's 64pt square; the capsule and shadow overhang it.
@MainActor
private final class FanItemView: NSView {
    /// `inFlight`: "Open in Finder" is gone before the items land (native, measured: out by
    /// about 70% of the flight), never on the pile.
    enum CloseFade { case none, late, early, inFlight }

    private let shadowView = NSImageView()
    private let iconView = NSImageView()
    private let glyphView = NSView()
    private let topCell = NSView()
    private let pressShade = NSView()
    private let label: NSView
    private let rotation: CGFloat
    /// The top cell's template glyph: blended onto its round plate like the grid's.
    private var isGlyph = false

    init(item: StackFanItem, layoutItem: StackFanLayout.Item) {
        rotation = layoutItem.rotation
        let side = StackFanLayout.itemSide
        label = Self.makeLabel(title: item.title, size: layoutItem.labelSize)
        super.init(frame: CGRect(x: layoutItem.center.x - side / 2, y: layoutItem.center.y - side / 2,
                                 width: side, height: side))
        wantsLayer = true
        if #available(macOS 14.0, *) { clipsToBounds = false }

        switch item.kind {
        case let .entry(entry):
            if let shadow = NativeStackArtwork.stackItemShadow {
                shadowView.image = shadow
                shadowView.imageScaling = .scaleAxesIndependently
                let rect = StackFanLayout.shadowRect().offsetBy(dx: side / 2, dy: side / 2)
                shadowView.frame = rect
                shadowView.wantsLayer = true
                addSubview(shadowView)
            }
            iconView.image = FolderIconResolver.resolve(entry.url.path)
            iconView.frame = bounds
        case .openInFinder:
            // The template glyph sits on a round plate (radius 28, inset 4) and casts no shadow.
            // Plate, glyph and press shade are one piece: the native presses and fades it whole.
            let plateFrame = bounds.insetBy(dx: 4, dy: 4)
            topCell.frame = bounds
            topCell.wantsLayer = true
            topCell.addSubview(Self.makeRoundPlate(frame: plateFrame))
            addSubview(topCell)
            if let glyph = NativeStackArtwork.openInFinder64?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                // Painted, not an image view: a tinted template image view neither takes the tint at
                // full strength nor blends.
                glyphView.frame = bounds
                glyphView.wantsLayer = true
                let mask = CALayer()
                mask.contents = glyph
                mask.contentsGravity = .resizeAspect
                mask.frame = bounds
                glyphView.layer?.mask = mask
                topCell.addSubview(glyphView)
                isGlyph = true
            } else {
                iconView.image = NativeStackArtwork.finderAppIcon
                iconView.frame = bounds
            }
        }
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.wantsLayer = true
        iconView.layerUsesCoreImageFilters = true
        if isGlyph {
            // Multiplying by grey 0.4 = black at 0.6 over it; a filter cannot reach the glass.
            pressShade.frame = bounds.insetBy(dx: 4, dy: 4)
            pressShade.wantsLayer = true
            pressShade.layer?.backgroundColor = NSColor(white: 0, alpha: 0.6).cgColor
            pressShade.layer?.cornerRadius = pressShade.frame.width / 2
            pressShade.isHidden = true
            topCell.addSubview(pressShade)
        } else {
            addSubview(iconView)
        }
        styleGlyph()

        let labelRect = StackFanLayout.labelRect(for: layoutItem).offsetBy(dx: side / 2, dy: side / 2)
        label.frame = labelRect
        label.wantsLayer = true
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        styleGlyph()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        styleGlyph()
    }

    /// Native: light mode darkens the plate under the arrow by black 0.5 (plus-darker), dark mode
    /// lightens it (plus-lighter) — the grid's `stackPopupGlyph`, same numbers.
    private func styleGlyph() {
        guard isGlyph else { return }
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let tint = (dark ? DockThemeTokens.dark : .light).stackPopupGlyph
        guard let layer = glyphView.layer else { return }
        layer.backgroundColor = (tint.base == .white ? NSColor(white: 1, alpha: tint.opacity)
                                                      : NSColor(white: 0, alpha: tint.opacity)).cgColor
        // Core Animation's own plus-lighter / plus-darker.
        layer.compositingFilter = dark ? "plusL" : "plusD"
    }

    /// The icon's square in the fan view's coordinates (unturned; for the drag image).
    var iconFrameInFan: CGRect { frame }

    var dragImage: NSImage? { iconView.image }

    func setIcon(_ image: NSImage) {
        iconView.image = image
    }

    /// What fades on close: the top cell whole (plate and glyph), else the icon.
    private var drawnView: NSView { isGlyph ? topCell : iconView }

    /// Pressed: the icon multiplied by grey 0.4, as the native item.
    func setPressed(_ pressed: Bool) {
        if isGlyph {
            pressShade.isHidden = !pressed
            return
        }
        guard pressed, let dim = CIFilter(name: "CIColorMatrix") else {
            drawnView.contentFilters = []
            return
        }
        dim.setDefaults()
        // Core Image multiplies in linear light: 0.133 there is ×0.4 on screen (0.4 itself read 170
        // on a white page instead of 102).
        let k: CGFloat = 0.1329
        dim.setValue(CIVector(x: k, y: 0, z: 0, w: 0), forKey: "inputRVector")
        dim.setValue(CIVector(x: 0, y: k, z: 0, w: 0), forKey: "inputGVector")
        dim.setValue(CIVector(x: 0, y: 0, z: k, w: 0), forKey: "inputBVector")
        drawnView.contentFilters = [dim]
    }

    // MARK: Building

    private static func makeLabel(title: String, size: CGSize) -> NSView {
        let text = NSTextField(labelWithString: title)
        text.font = .systemFont(ofSize: StackFanLayout.labelFontSize)
        text.textColor = .labelColor
        text.lineBreakMode = .byTruncatingMiddle
        text.maximumNumberOfLines = 1
        let textHeight = text.intrinsicContentSize.height
        // A label field's cell keeps 2pt on each side: the text itself starts at the padding.
        let cellInset: CGFloat = 2
        text.frame = CGRect(x: StackFanLayout.labelPadding - cellInset, y: (size.height - textHeight) / 2,
                            width: size.width - 2 * StackFanLayout.labelPadding + 2 * cellInset, height: textHeight)
        let plateFrame = CGRect(origin: .zero, size: size)
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: plateFrame)
            glass.cornerRadius = size.height / 2
            let content = NSView(frame: plateFrame)
            content.addSubview(text)
            glass.contentView = content
            return glass
        }
        let plate = NSVisualEffectView(frame: plateFrame)
        plate.material = .popover
        plate.state = .active
        plate.wantsLayer = true
        plate.layer?.cornerRadius = 4
        plate.layer?.masksToBounds = true
        plate.addSubview(text)
        return plate
    }

    private static func makeRoundPlate(frame: CGRect) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: frame)
            glass.cornerRadius = frame.width / 2
            return glass
        }
        let plate = NSVisualEffectView(frame: frame)
        plate.material = .popover
        plate.state = .active
        plate.wantsLayer = true
        plate.layer?.cornerRadius = frame.width / 2
        plate.layer?.masksToBounds = true
        return plate
    }

    // MARK: Animation

    /// A transform about `pivot` (in the layer's own coordinates): AppKit keeps a layer-backed
    /// view's anchor point at its origin, so pivots live in the transform.
    private static func transform(scale: CGFloat, rotation: CGFloat, about pivot: CGPoint) -> CATransform3D {
        var t = CATransform3DMakeTranslation(pivot.x, pivot.y, 0)
        t = CATransform3DRotate(t, rotation, 0, 0, 1)
        t = CATransform3DScale(t, scale, scale, 1)
        return CATransform3DTranslate(t, -pivot.x, -pivot.y, 0)
    }

    private var centerPivot: CGPoint {
        let side = StackFanLayout.itemSide
        let anchor = layer?.anchorPoint ?? .zero
        return CGPoint(x: side / 2 - anchor.x * side, y: side / 2 - anchor.y * side)
    }

    /// The label grows out of its right edge, the side that touches the item.
    private var labelPivot: CGPoint {
        let anchor = label.layer?.anchorPoint ?? .zero
        return CGPoint(x: label.bounds.width * (1 - anchor.x), y: label.bounds.height * (0.5 - anchor.y))
    }

    /// The layer's `position` for an item centred at `center` (same space as `frame`).
    private func position(forCenter center: CGPoint) -> CGPoint {
        let side = StackFanLayout.itemSide
        let anchor = layer?.anchorPoint ?? .zero
        return CGPoint(x: center.x - side / 2 + anchor.x * side, y: center.y - side / 2 + anchor.y * side)
    }

    /// Points along the native flight path: the circle of radius 3000 through `start` whose centre
    /// is 3000 to its right, from `start` up to `end`'s height, bent the last bit onto `end`.
    private static func arc(from start: CGPoint, to end: CGPoint, samples: Int = 12) -> [CGPoint] {
        let radius = StackFanLayout.radius
        let rise = end.y - start.y
        let endAngle = asin(max(-1, min(1, rise / radius)))
        let arcEndX = start.x + radius * (1 - cos(endAngle))
        return (0...samples).map { step in
            let p = CGFloat(step) / CGFloat(samples)
            let angle = endAngle * p
            let x = start.x + radius * (1 - cos(angle))
            let y = start.y + radius * sin(angle)
            return CGPoint(x: x + (end.x - arcEndX) * p, y: y)
        }
    }

    /// The item's turn, on `sublayerTransform`: AppKit resets a layer-backed view's own `transform`
    /// at its next geometry sync, which left every landed item upright.
    private var turnedTransform: CATransform3D {
        Self.transform(scale: 1, rotation: rotation, about: centerPivot)
    }

    /// The landed pose as the model value.
    func settle() {
        layer?.sublayerTransform = turnedTransform
    }

    func addOpenAnimation(from pile: CGRect, to item: StackFanLayout.Item) {
        guard let layer else { return }
        let start = CGPoint(x: pile.midX, y: pile.midY)
        let turned = turnedTransform

        let flight = CAKeyframeAnimation(keyPath: "position")
        flight.values = Self.arc(from: start, to: item.center).map { NSValue(point: position(forCenter: $0)) }
        flight.calculationMode = .paced
        flight.timingFunction = PopoverAnimation.fanCurve()

        let grow = CABasicAnimation(keyPath: "transform")
        grow.fromValue = NSValue(caTransform3D: Self.transform(scale: pile.width / StackFanLayout.itemSide,
                                                               rotation: 0, about: centerPivot))
        grow.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        grow.timingFunction = CAMediaTimingFunction(name: .default)

        let turn = CABasicAnimation(keyPath: "sublayerTransform")
        turn.fromValue = NSValue(caTransform3D: CATransform3DIdentity)
        turn.toValue = NSValue(caTransform3D: turned)
        turn.timingFunction = CAMediaTimingFunction(name: .default)

        let group = CAAnimationGroup()
        group.animations = [flight, grow, turn]
        group.duration = PopoverAnimation.stackDuration
        layer.add(group, forKey: "fanOpen")

        if let shadow = shadowView.layer {
            shadow.opacity = StackFanLayout.shadowOpacity
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = StackFanLayout.shadowOpacity
            fade.duration = PopoverAnimation.stackDuration
            fade.timingFunction = CAMediaTimingFunction(name: .default)
            shadow.add(fade, forKey: "fanOpen")
        }
        if let labelLayer = label.layer {
            let grow = CABasicAnimation(keyPath: "transform")
            grow.fromValue = NSValue(caTransform3D: Self.transform(scale: 1e-5, rotation: 0, about: labelPivot))
            grow.toValue = NSValue(caTransform3D: CATransform3DIdentity)
            grow.timingFunction = PopoverAnimation.fanCurve()
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.timingFunction = CAMediaTimingFunction(name: .linear)
            let labelGroup = CAAnimationGroup()
            labelGroup.animations = [grow, fade]
            labelGroup.duration = PopoverAnimation.stackDuration
            labelLayer.add(labelGroup, forKey: "fanOpen")
        }
    }

    func addCloseAnimation(to pile: CGRect, from item: StackFanLayout.Item, fade iconFade: CloseFade) {
        guard let layer else { return }
        let duration = PopoverAnimation.stackDuration
        let presentation = layer.presentation()
        let side = StackFanLayout.itemSide
        let anchor = layer.anchorPoint
        let livePosition = presentation?.position ?? layer.position
        let liveCenter = CGPoint(x: livePosition.x - anchor.x * side + side / 2,
                                 y: livePosition.y - anchor.y * side + side / 2)
        let liveTransform = presentation?.transform ?? layer.transform
        let liveTurn = presentation?.sublayerTransform ?? layer.sublayerTransform
        layer.removeAllAnimations()
        let end = CGPoint(x: pile.midX, y: pile.midY)
        let endTransform = Self.transform(scale: pile.width / side, rotation: 0, about: centerPivot)

        let flight = CAKeyframeAnimation(keyPath: "position")
        flight.values = Self.arc(from: end, to: liveCenter).reversed().map { NSValue(point: position(forCenter: $0)) }
        flight.calculationMode = .paced
        flight.timingFunction = PopoverAnimation.fanCurve()

        let shrink = CABasicAnimation(keyPath: "transform")
        shrink.fromValue = NSValue(caTransform3D: liveTransform)
        shrink.toValue = NSValue(caTransform3D: endTransform)
        shrink.timingFunction = CAMediaTimingFunction(name: .default)

        let turn = CABasicAnimation(keyPath: "sublayerTransform")
        turn.fromValue = NSValue(caTransform3D: liveTurn)
        turn.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        turn.timingFunction = CAMediaTimingFunction(name: .default)

        let group = CAAnimationGroup()
        group.animations = [flight, shrink, turn]
        group.duration = duration
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        layer.add(group, forKey: "fanClose")

        if let shadow = shadowView.layer {
            Self.fade(shadow, to: 0, beginAfter: 0, duration: duration, timing: .default)
        }
        if let labelLayer = label.layer {
            let liveLabel = labelLayer.presentation()
            labelLayer.removeAllAnimations()
            let shrink = CABasicAnimation(keyPath: "transform")
            shrink.fromValue = NSValue(caTransform3D: liveLabel?.transform ?? CATransform3DIdentity)
            shrink.toValue = NSValue(caTransform3D: Self.transform(scale: 1e-5, rotation: 0, about: labelPivot))
            shrink.timingFunction = PopoverAnimation.fanCurve()
            shrink.duration = duration
            shrink.fillMode = .forwards
            shrink.isRemovedOnCompletion = false
            labelLayer.add(shrink, forKey: "fanCloseScale")
            Self.fade(labelLayer, to: 0, beginAfter: 0, duration: duration, timing: .linear)
        }
        if let icon = drawnView.layer {
            switch iconFade {
            case .none:
                break
            case .late:
                Self.fade(icon, to: 0, beginAfter: duration - 0.05, duration: 0.1, timing: .linear)
            case .early:
                Self.fade(icon, to: 0, beginAfter: duration / 3, duration: duration * 2 / 3, timing: .linear)
            case .inFlight:
                Self.fade(icon, to: 0, beginAfter: 0, duration: duration * 0.7, timing: .linear)
            }
        }
    }

    private static func fade(_ layer: CALayer, to value: Float, beginAfter delay: CFTimeInterval,
                             duration: CFTimeInterval, timing: CAMediaTimingFunctionName) {
        let from = layer.presentation()?.opacity ?? layer.opacity
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from
        fade.toValue = value
        fade.beginTime = delay > 0 ? CACurrentMediaTime() + delay : 0
        fade.duration = duration
        fade.timingFunction = CAMediaTimingFunction(name: timing)
        fade.fillMode = .both
        fade.isRemovedOnCompletion = false
        layer.add(fade, forKey: "fanCloseFade")
    }
}

/// A transparent window's whole area taking clicks: above the bar while a fan flies open, a
/// click anywhere there is a click outside — never one for the app underneath.
final class StackPopupClickCatcher: NSView {
    private let onClick: () -> Void

    init(onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick() }
    override func rightMouseDown(with event: NSEvent) { onClick() }
}
