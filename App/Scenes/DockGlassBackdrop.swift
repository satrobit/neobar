import AppKit
import SwiftUI

/// Floating panel backing: when `macOS 26 + switch on + backdrop window built`, uses native Liquid Glass, otherwise the
/// existing frosted-glass material.
///
/// **`usesLiquidGlass` is passed in explicitly, with no default value** — the same existing rule as `scale` / `hoverStyle`
/// ("Taskbar Size Tiers" in `AGENTS.md`): forgetting to pass it is a compile error, not silently rendering via one of the paths.
/// It used to be a mutable static, which SwiftUI could not observe, so after a panel was torn down views would still read the stale value.
struct DockGlassBackdrop: View {
    /// The material used by the fallback path (`DockThemeTokens.panelMaterial`). It is what is used when glass is unavailable.
    let material: DockPanelMaterial
    let usesLiquidGlass: Bool
    var cornerRadius: CGFloat = DockShape.panelCornerRadius
    var saturation: Double = 1.0
    var thicknessEnabled: Bool = false
    var matchesDockRefraction: Bool = false

    var body: some View {
        Group {
            if #available(macOS 26.0, *), usesLiquidGlass, let variant = DockGlassPresentation.activeSystemVariant {
                DockSystemGlassVariantPlate(
                    cornerRadius: cornerRadius,
                    variant: variant,
                    matchesDockRefraction: matchesDockRefraction && DockGlassPresentation.dockRefractionEnabled
                        && variant == DockLiquidGlassConfiguration.dockSystemVariant,
                    usesDiagonalHighlight: matchesDockRefraction && DockGlassPresentation.diagonalHighlightEnabled
                        && variant == DockLiquidGlassConfiguration.dockSystemVariant
                )
                    .allowsHitTesting(false)
            } else if #available(macOS 26.0, *), usesLiquidGlass {
                DockLiquidGlassPlate(
                    cornerRadius: cornerRadius,
                    configuration: DockGlassPresentation.configuration
                )
                // Glass is itself a view, so hit-testing must be explicitly opted out;
                // **it cannot be attached outside the Group** — the fallback path would change with it, and the fallback path must be pixel-for-pixel
                // and behavior-for-behavior identical to before the rework.
                .allowsHitTesting(false)
            } else {
                DockVisualEffectView(material: material)
                    .dockBackdropSaturation(saturation)
            }
        }
        .onAppear {
            DockGlassPresentation.logResolvedPath(compositeActive: usesLiquidGlass)
            DockEffectSwitches.logActiveOverrides(
                material: material,
                saturation: saturation,
                thickness: thicknessEnabled
            )
        }
    }
}

/// The backing shared by the five floating panels (taskbar / drawer capsule / drawer / folder popup / shelf popup).
///
/// Packs "backing + 2pt bleed + rounded-corner clip" into one place: the five call sites each used to carry their own copy,
/// and when glass was promoted, missing any one of them would make that panel's material differ from the others (this is how, in the owner's screenshot,
/// the drawer capsule ended up visibly brighter and more solid than the taskbar).
///
/// `.padding(-2)` is a legacy of the frosted-glass era (to avoid seams at the material edge). It is harmless for glass,
/// but it **clips the stroke drawn inside the backing** — so the edge highlight goes through `View.dockPanelRim`,
/// attached at the outermost layer of the panel body, and is not drawn here.
struct DockPanelBackdrop: View {
    let theme: DockThemeTokens
    let cornerRadius: CGFloat
    let usesLiquidGlass: Bool
    var matchesDockRefraction: Bool = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        DockGlassBackdrop(material: theme.effectivePanelMaterial,
                          usesLiquidGlass: usesLiquidGlass,
                          cornerRadius: cornerRadius,
                          saturation: theme.effectiveBackdropSaturation,
                          thicknessEnabled: theme.drawsEffectiveThickness,
                          matchesDockRefraction: matchesDockRefraction)
            // NeoBar: darken and solidify the glass (`DockGlassTint`).
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.black.opacity(colorScheme == .dark
                        ? DockGlassTint.darkModeOpacity
                        : DockGlassTint.lightModeOpacity))
                    .allowsHitTesting(false)
            }
            .padding(-DockLiquidGlassConfiguration.backdropOutset(
                usesLiquidGlass: usesLiquidGlass,
                usesSystemVariant: DockGlassPresentation.usesSystemVariant))
            .dockBackdropClip(cornerRadius: cornerRadius,
                              skip: usesLiquidGlass && DockGlassPresentation.usesSystemVariant)
            .ignoresSafeArea()
    }
}

extension View {
    /// Panel stroke. The two paths each draw their own: frosted glass uses the ring from `DockThemeTokens`, and glass uses the uniform white highlight measured to match
    /// the native Dock. The whole-frame drag-and-drop hit highlight (`highlighted`) is **layered on top of** both,
    /// replacing neither — see `DockPanelRimPlan` for the decision, where this rule's origin is written down.
    ///
    /// **The glass highlight must be drawn here, not inside `DockLiquidGlassPlate`.** The backing view is wrapped in
    /// a legacy `.padding(-2)` (frosted glass needs a 2pt bleed to avoid edge seams), so the glass view's frame is therefore
    /// 2pt larger than the bar, and the ring that `strokeBorder` draws inward lands exactly in the clipped 2pt — measured: stretching the width to
    /// 4pt shows only half (only 4px of 8px visible), and 0.5pt disappears entirely. The overlay here is attached to the whole body,
    /// so its position is the bar's true edge.
    func dockPanelRim<S: ShapeStyle>(
        cornerRadius: CGFloat,
        style: S,
        lineWidth: CGFloat,
        usesLiquidGlass: Bool,
        highlighted: Bool = false
    ) -> some View {
        let configuration = DockGlassPresentation.configuration
        let strokeWidth = DockPanelRimPlan.themeStrokeWidth(usesLiquidGlass: usesLiquidGlass,
                                                            highlighted: highlighted,
                                                            lineWidth: lineWidth)
        return overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(style, lineWidth: strokeWidth)
        }
        .overlay {
            if DockPanelRimPlan.glassRimVisible(usesLiquidGlass: usesLiquidGlass,
                                                usesSystemVariant: DockGlassPresentation.usesSystemVariant) {
                DockGlassRim(cornerRadius: cornerRadius, configuration: configuration)
            }
        }
    }
}

/// The edge highlight of the glass backing.
///
/// **Two pixels wide + modulated by corner**, both measured pixel by pixel against the native Dock:
///
/// | Position | Bright line − backing |
/// |---|---|
/// | Four long edges | +67 (profile 148 / 120 / backing: one full pixel + one half level) |
/// | Top-left / bottom-right corners | +76 / +81 (even brighter than the long edges) |
/// | Top-right / bottom-left corners | +7 / +5 (the bright line almost vanishes) |
///
/// Background interference ruled out: backing just inside the four corners is 79.8–82.5, and wallpaper just outside the corners is 30.6–36.6, basically the same at all four,
/// so the light/dark difference is a property of the **bright line itself**.
///
/// **A linear gradient cannot produce this shape** — the bright one is the ↖↘ diagonal and the dark one is the ↗↙ diagonal, while a linear gradient
/// is monotonic along its axis and cannot brighten both diagonals at once. Codex's original `topLeading → bottomTrailing` diagonal
/// gradient got the direction half right but the shape backwards (it darkens ↘), and for an 800pt-wide bar the gradient has decayed
/// by the horizontal midpoint: measured with parameters maxed out, the left edge blew out at 254 while the middle section was only 158. **Do not go back down that road.**
///
/// Everything used is SwiftUI available since macOS 12 (`RadialGradient` / `mask` / `blendMode`),
/// so no availability annotation is added — it is merely **in practice** attached only on the glass path.
private struct DockGlassRim: View {
    let cornerRadius: CGFloat
    let configuration: DockLiquidGlassConfiguration

    var body: some View {
        let width = CGFloat(configuration.borderLineWidth)
        ZStack {
            // Outer ring: the full pixel.
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(configuration.borderPeakOpacity),
                              lineWidth: width)
            // Inner ring: the half level right next to the outer ring. Drawing only the outer ring gives the same peak, but only half the visual weight,
            // to the naked eye it is "not as bright as native" (owner feedback 2026-08-16).
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .inset(by: width)
                .strokeBorder(Color.white.opacity(configuration.borderInnerOpacity),
                              lineWidth: width)
        }
        // The whole ring is drawn at the peak level, then a mask presses the long edges down to edgeLevel and cuts the ↗↙ corners to almost nothing.
        .mask { cornerModulation }
    }

    /// Corner modulation mask. SwiftUI's `.mask` takes **alpha**, not luminance — the only way to darken is to cut alpha,
    /// so the two ↗↙ corners use `.destinationOut`.
    private var cornerModulation: some View {
        let radius = cornerRadius * CGFloat(configuration.borderCornerSpread)
        return ZStack {
            Color.white.opacity(configuration.borderEdgeLevel)
            // ↖↘: brighten to full level.
            cornerGradient(.topLeading, radius: radius, color: .white)
            cornerGradient(.bottomTrailing, radius: radius, color: .white)
            // ↗↙: cut out, leaving just a trace.
            cornerGradient(.topTrailing, radius: radius,
                           color: .white.opacity(configuration.borderCornerCut))
                .blendMode(.destinationOut)
            cornerGradient(.bottomLeading, radius: radius,
                           color: .white.opacity(configuration.borderCornerCut))
                .blendMode(.destinationOut)
        }
        // Without it, destinationOut would punch through into the backing instead of acting only inside this mask.
        .compositingGroup()
    }

    private func cornerGradient(_ center: UnitPoint, radius: CGFloat, color: Color) -> some View {
        RadialGradient(colors: [color, color.opacity(0)],
                       center: center,
                       startRadius: 0,
                       endRadius: radius)
    }
}

private extension View {
    /// The variant plate clips itself (circular corners); our continuous-corner clip at the same
    /// radius would shave its rim at the corners.
    @ViewBuilder
    func dockBackdropClip(cornerRadius: CGFloat, skip: Bool) -> some View {
        if skip { self } else { clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)) }
    }
}

enum DockGlassPresentation {
    static let configuration = DockLiquidGlassConfiguration.resolve()
    static let dockRefractionEnabled = DebugSwitch.liquidGlassDockRefraction.isEnabled()
    static let diagonalHighlightEnabled = DebugSwitch.liquidGlassDiagonalHighlight.isEnabled()
    static let highlightBoostEnabled = DebugSwitch.liquidGlassHighlightBoost.isEnabled()

    /// The system variant in effect, or `nil` when it is switched off or the private selector is gone.
    /// The resolved material is deliberately not checked — see `appearance.md`.
    static let activeSystemVariant: Int? = {
        guard let variant = configuration.systemVariant, TEDockGlassSupportsSystemVariant() else { return nil }
        return variant
    }()

    static var usesSystemVariant: Bool { activeSystemVariant != nil }

    /// The system-variant plates hosted in `window`, for diagnostics: their material is the one a
    /// same-size reference can be built for. Empty on the SwiftUI-clear and frosted paths.
    static func systemVariantGlassViews(in window: NSWindow) -> [NSView] {
        guard #available(macOS 26.0, *), let root = window.contentView else { return [] }
        var found: [NSView] = []
        var pending: [NSView] = [root]
        while let view = pending.popLast() {
            if view is DockSystemGlassEffectView { found.append(view) }
            pending.append(contentsOf: view.subviews)
        }
        return found
    }

    /// Whether glass compositing can be built for the taskbar. Three gates: system ≥ 26, switch on, both SkyLight symbols found.
    static var shouldAttemptTaskbarComposite: Bool {
        let glassAvailable: Bool
        if #available(macOS 26.0, *) { glassAvailable = true } else { glassAvailable = false }
        // Short circuit: on older versions, do not dlopen SkyLight.
        let compositeAvailable = glassAvailable && TEDockGlassCanSetWindowBackgroundBlur()
        return configuration.renderPath(
            isGlassAPIAvailable: glassAvailable,
            isCompositeAvailable: compositeAvailable
        ) == .layeredTaskbar
    }

    /// At launch, print a line saying which path this run takes. Uses `print` rather than `Logger` — some environments cannot read back the
    /// unified log (same reason as `[edgehover]`).
    static func logResolvedPath(compositeActive: Bool) {
        guard configuration.isEnabled else { return }
        if compositeActive {
            let c = configuration
            let rim = "peak=\(c.borderPeakOpacity) edge=\(c.borderEdgeLevel) "
                + "cut=\(c.borderCornerCut) spread=\(c.borderCornerSpread) w=\(c.borderLineWidth)"
            print("[glass] taskbar composite active, clearTint=\(c.clearTintOpacity), rim(\(rim)), "
                + "background=\(c.backgroundMaterialOpacity), windowBlur=\(c.windowBlurRadius), "
                + "systemVariant=\(activeSystemVariant.map(String.init) ?? "off"), "
                + "dockRefraction=\(dockRefractionEnabled), diagonalHighlight=\(diagonalHighlightEnabled), "
                + "highlightBoost=\(highlightBoostEnabled)")
        } else if #available(macOS 26.0, *) {
            print("[glass] composite unavailable; using NSVisualEffectView")
        } else {
            print("[glass] enabled but macOS < 26; using NSVisualEffectView")
        }
    }
}

/// AppKit bakes the window's active state into the glass once, when the view lands in its window,
/// and re-samples only through `_windowChangedKeyState` (a key change, or the app activating or
/// deactivating). Our panels never produce either, so the first sample is the material for the
/// bar's whole life; the inactive material is the uniform milky plate (+89 over black against the
/// active +50). Re-sample once attached and on every occlusion change (the first order-in included),
/// when `DockLiquidGlassPanel`'s predicates answer.
@available(macOS 26.0, *)
private final class DockSystemGlassEffectView: NSGlassEffectView {
    private var occlusionObserver: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let observer = occlusionObserver {
            NotificationCenter.default.removeObserver(observer)
            occlusionObserver = nil
        }
        guard let window else { return }
        // Next turn: `presentInitialPanels` orders the panel in after this layout pass.
        DispatchQueue.main.async { [weak self] in self?.refreshWindowState() }
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in self?.refreshWindowState() }
    }

    private func refreshWindowState() {
        _ = TEDockGlassRefreshWindowState(self)
    }

    deinit {
        if let observer = occlusionObserver { NotificationCenter.default.removeObserver(observer) }
    }
}

/// The plate rendered by AppKit's `NSGlassEffectView` with a private system variant (the Dock's).
@available(macOS 26.0, *)
private struct DockSystemGlassVariantPlate: NSViewRepresentable {
    let cornerRadius: CGFloat
    let variant: Int
    let matchesDockRefraction: Bool
    let usesDiagonalHighlight: Bool

    func makeCoordinator() -> DockGlassRefractionObserver { DockGlassRefractionObserver() }

    func makeNSView(context: Context) -> DockSystemGlassEffectView {
        let view = DockSystemGlassEffectView()
        view.contentView = NSView()
        apply(to: view)
        configureObserver(context.coordinator, for: view)
        return view
    }

    // SwiftUI re-runs update, never re-creates the view — the radius follows drag-to-resize here.
    func updateNSView(_ view: DockSystemGlassEffectView, context: Context) {
        apply(to: view)
        configureObserver(context.coordinator, for: view)
    }

    private func configureObserver(_ observer: DockGlassRefractionObserver, for view: NSView) {
        if matchesDockRefraction || usesDiagonalHighlight {
            observer.attach(to: view,
                            refractionEnabled: matchesDockRefraction,
                            diagonalHighlightEnabled: usesDiagonalHighlight,
                            highlightAmount: DockGlassPresentation.highlightBoostEnabled
                                ? DockLiquidGlassConfiguration.boostedHighlightAmount : nil)
        } else {
            observer.stop()
        }
    }

    static func dismantleNSView(_ view: DockSystemGlassEffectView, coordinator: DockGlassRefractionObserver) {
        coordinator.stop()
    }

    private func apply(to view: NSGlassEffectView) {
        view.cornerRadius = cornerRadius
        _ = TEDockGlassSetSystemVariant(view, variant)
    }
}

/// AppKit replaces the glass filter when its material or geometry changes. Follow those changes
/// without polling, and never retain or mutate a filter owned by the system.
private final class DockGlassRefractionObserver {
    private weak var view: NSView?
    private var viewObservation: NSKeyValueObservation?
    private var layerObservations: [ObjectIdentifier: [NSKeyValueObservation]] = [:]
    private var effectObservations: [ObjectIdentifier: NSObject] = [:]
    private var refreshScheduled = false
    private var refractionEnabled = false
    private var diagonalHighlightEnabled = false
    private var highlightAmount: Double?

    func attach(to view: NSView, refractionEnabled: Bool, diagonalHighlightEnabled: Bool,
                highlightAmount: Double?) {
        if self.view !== view {
            stop()
            self.view = view
            viewObservation = view.observe(\.layer) { [weak self] _, _ in self?.scheduleRefresh() }
        }
        self.refractionEnabled = refractionEnabled
        self.diagonalHighlightEnabled = diagonalHighlightEnabled
        self.highlightAmount = highlightAmount
        scheduleRefresh()
    }

    func stop() {
        view = nil
        viewObservation = nil
        layerObservations.removeAll()
        effectObservations.removeAll()
    }

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refresh()
        }
    }

    private func refresh() {
        guard let root = view?.layer else {
            layerObservations.removeAll()
            effectObservations.removeAll()
            return
        }
        var pending = [root]
        var seen = Set<ObjectIdentifier>()
        while let layer = pending.popLast() {
            let id = ObjectIdentifier(layer)
            guard seen.insert(id).inserted else { continue }
            if layerObservations[id] == nil {
                layerObservations[id] = [
                    layer.observe(\.sublayers) { [weak self] _, _ in self?.scheduleRefresh() },
                    layer.observe(\.filters) { [weak self] _, _ in self?.scheduleRefresh() }
                ]
            }
            if refractionEnabled {
                _ = TEDockGlassSetRefraction(layer,
                                            DockLiquidGlassConfiguration.dockInnerRefractionHeight,
                                            DockLiquidGlassConfiguration.dockInnerRefractionAmount)
            }
            if diagonalHighlightEnabled {
                if effectObservations[id] == nil {
                    effectObservations[id] = TEDockGlassObserveEffect(layer) { [weak self] in
                        self?.scheduleRefresh()
                    }
                }
                _ = TEDockGlassSetHighlight(layer,
                                           DockLiquidGlassConfiguration.diagonalKeyAngle,
                                           DockLiquidGlassConfiguration.diagonalFillAngle,
                                           highlightAmount.map { NSNumber(value: $0) })
            }
            pending.append(contentsOf: layer.sublayers ?? [])
        }
        layerObservations = layerObservations.filter { seen.contains($0.key) }
        effectObservations = effectObservations.filter { diagonalHighlightEnabled && seen.contains($0.key) }
    }
}

/// SwiftUI glass backing (fallback when the system variant is unavailable or turned off). Shared by the five floating panels (during exploration only the taskbar was wired up).
@available(macOS 26.0, *)
private struct DockLiquidGlassPlate: View {
    let cornerRadius: CGFloat
    let configuration: DockLiquidGlassConfiguration

    var body: some View {
        let inset = CGFloat(configuration.contentInset)
        // Expand first then shrink: leaves headroom for the glass's own edge rendering, and finally a negative padding restores the layout size.
        let shape = RoundedRectangle(
            cornerRadius: cornerRadius + inset,
            style: .continuous
        ).inset(by: inset)
        let tint = Color(nsColor: NSColor(deviceWhite: 127.0 / 255.0, alpha: 1))
            .opacity(configuration.clearTintOpacity)

        shape
            .fill(Color.clear)
            .glassEffect(.clear.tint(tint).interactive(false), in: shape)
            .background {
                shape.fill(Color.white.opacity(configuration.whiteOverlayOpacity))
            }
            // The edge highlight is **not drawn here** — see `View.dockPanelRim`: the backing is wrapped in `.padding(-2)`,
            // and drawing at this layer would get clipped.
            // The panel never becomes the key window; if not forced, the material renders as "inactive" and the whole thing looks gray.
            .materialActiveAppearance(.active)
            .environment(\.appearsActive, true)
            .padding(-inset)
    }

}

/// The WindowServer side of glass compositing. It owns a mouse-transparent panel, so that the window blur does not composite the
/// SwiftUI glass in the content window a second time.
///
/// **No shadow is drawn here.** The window this view lives in has a frame exactly equal to the backing itself, so a layer shadow drawn outside the window would be
/// clipped away entirely; the drop shadow belongs to the content window's `.dockShadow`, which has a 20pt transparent margin to use.
final class DockTaskbarLiquidGlassBackgroundView: NSView {
    private let liveBackdropSubscriptionView = NSVisualEffectView()
    private let materialView = NSVisualEffectView()
    private let dimmingOverlayView = NSView()
    private var configuration: DockLiquidGlassConfiguration
    private var plateCornerRadius: CGFloat

    init(
        frame frameRect: NSRect,
        cornerRadius: CGFloat,
        configuration: DockLiquidGlassConfiguration
    ) {
        self.configuration = configuration
        self.plateCornerRadius = cornerRadius
        super.init(frame: frameRect)

        wantsLayer = true
        configureVisualEffectView(liveBackdropSubscriptionView)
        // Very-low-alpha subscription layer: keeps WindowServer continuously feeding the content behind to this window,
        // otherwise the background blur would freeze on some frame.
        liveBackdropSubscriptionView.material = .underWindowBackground
        liveBackdropSubscriptionView.alphaValue = 3.0 / 255.0

        configureVisualEffectView(materialView)
        materialView.material = .menu
        materialView.alphaValue = configuration.backgroundMaterialOpacity

        dimmingOverlayView.wantsLayer = true
        for view in [liveBackdropSubscriptionView, materialView, dimmingOverlayView] {
            view.frame = bounds
            view.autoresizingMask = [.width, .height]
            addSubview(view)
        }
        apply(cornerRadius: cornerRadius, configuration: configuration)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateOverlayColor()
    }

    func apply(
        cornerRadius: CGFloat,
        configuration: DockLiquidGlassConfiguration
    ) {
        guard cornerRadius != plateCornerRadius || configuration != self.configuration else { return }
        self.configuration = configuration
        plateCornerRadius = cornerRadius
        materialView.alphaValue = configuration.backgroundMaterialOpacity
        materialView.isHidden = configuration.backgroundMaterialOpacity <= 0
        dimmingOverlayView.isHidden = configuration.dimmingOpacity <= 0
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        // Not a visual layer: WindowServer needs a non-zero-alpha shape before it will do the background blur.
        layer?.backgroundColor = NSColor.black
            .withAlphaComponent(configuration.backgroundPlateOpacity)
            .cgColor
        for view in [liveBackdropSubscriptionView, materialView, dimmingOverlayView] {
            view.wantsLayer = true
            view.layer?.cornerRadius = cornerRadius
            view.layer?.cornerCurve = .continuous
            view.layer?.masksToBounds = true
        }
        updateOverlayColor()
    }

    private func configureVisualEffectView(_ view: NSVisualEffectView) {
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = false
    }

    private func updateOverlayColor() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let color = isDark ? NSColor.black : NSColor.white
        dimmingOverlayView.layer?.backgroundColor = color
            .withAlphaComponent(configuration.dimmingOpacity)
            .cgColor
    }
}
