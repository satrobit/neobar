import AppKit
import Combine
import SwiftUI

/// Shared by the two hosting roots of one taskbar; a resize must not inherit chip animations.
@MainActor
final class PanelHeightResizePresentation: ObservableObject {
    @Published var isActive = false

    func nonInteractiveHeightChanges(
        from heights: Published<DockPanelHeight>.Publisher
    ) -> AnyPublisher<DockPanelHeight, Never> {
        heights
            .removeDuplicates()
            .dropFirst()
            // Reject at publication, before a queued delivery can outlive the drag.
            .filter { [weak self] _ in self?.isActive == false }
            .receive(on: DispatchQueue.main)
            // A new drag may have started while an ordinary change was queued.
            .filter { [weak self] _ in self?.isActive == false }
            .eraseToAnyPublisher()
    }
}

private struct PanelHeightResizingKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var isPanelHeightResizing: Bool {
        get { self[PanelHeightResizingKey.self] }
        set { self[PanelHeightResizingKey.self] = newValue }
    }
}

struct PanelHeightResizeModifier: ViewModifier {
    @ObservedObject var presentation: PanelHeightResizePresentation

    func body(content: Content) -> some View {
        content
            .environment(\.isPanelHeightResizing, presentation.isActive)
            .transaction { transaction in
                if presentation.isActive {
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                }
            }
    }
}

/// Hosts manually sized panel content without letting the hosted view become the
/// window's content view and participate in automatic window sizing.
@MainActor
final class ManualPanelHost {
    let contentView: NSView

    init(contentView: NSView, in panel: NSPanel) {
        self.contentView = contentView

        let initialSize = panel.contentView?.bounds.size
            ?? panel.contentRect(forFrameRect: panel.frame).size
        let container = NSView(frame: NSRect(origin: .zero, size: initialSize))
        panel.contentView = container

        contentView.frame = container.bounds
        contentView.autoresizingMask = [.width, .height]
        container.addSubview(contentView)
    }

    var fittingSize: NSSize { contentView.fittingSize }

    /// ObservedObject invalidation alone does not refresh NSHostingView's fitting size in the
    /// publishing call stack. Lay out explicitly before measuring and after resizing its panel.
    func layoutContent() {
        contentView.needsLayout = true
        contentView.layoutSubtreeIfNeeded()
    }
}

/// Window levels above `.floating`, the level every panel is created at.
enum PanelLevel {
    /// The drawer while a drag from outside has it open. The system Apps panel (Spotlight's app
    /// list, a window of `Siri`) sits at 23 on macOS 27; at `.floating` the drawer opened under it.
    static let raisedDrawer = NSWindow.Level.statusBar
    /// The drag carrier: above every panel of ours, the raised drawer included — an app dropped
    /// from outside lands on the carrier, into that drawer.
    static let carrier = NSWindow.Level(rawValue: raisedDrawer.rawValue + 1)
}

/// The window behavior set shared by the seven floating panels. **There must be only this one place with the literal**:
/// the fix for issue #19 reassigns this set as is to restore the "resident on all desktops" membership,
/// and once the restored values diverge from the values at creation, the fix would silently change the panel into a different behavior.
enum PanelCollectionBehavior {
    static let standard: NSWindow.CollectionBehavior =
        [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
}

/// Turn off AppKit's automatic window constraining. By default the system moves windows near/across a screen edge back into the "current display" usable area (avoiding the menu bar).
/// In the multi-display **shared edge** scenario this is fatal: when the task strip is placed at the bottom of the upper display, the window origin's y falls on the lower display's side, and the system uses the lower display
/// to constrain it, pressing the whole window to just under the lower display's menu bar -> the task strip / capsule end up on the wrong display (root cause of the 2026-06-23 three-display bug; measured y=970
/// was pressed to y=857 = lower display's usable-area top 949 - window height 92). Our panels are always positioned precisely by hand and never cover the menu bar, so we simply
/// return the original frame and don't let the system constrain a second time.
class NonConstrainingPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    // `isMovable = false` only stops mouse drags: any process with Accessibility access can still
    // relocate the window through `kAXPositionAttribute`, and `PanelCoordinator` never puts it
    // back (`setFrames` compares targets, not live frames). A window manager reacting to the
    // per-tick frame changes of a grip drag is exactly such a process. NSWindow serves AX
    // position / size writes through the legacy attribute API below; disallowing
    // `setAccessibilityFrame(_:)` via `isAccessibilitySelectorAllowed` does not block them.
    override func accessibilityIsAttributeSettable(_ attribute: NSAccessibility.Attribute) -> Bool {
        if attribute == .position || attribute == .size { return false }
        return super.accessibilityIsAttributeSettable(attribute)
    }

    override func accessibilitySetValue(_ value: Any?, forAttribute attribute: NSAccessibility.Attribute) {
        if attribute == .position || attribute == .size { return }
        super.accessibilitySetValue(value, forAttribute: attribute)
    }
}

/// Liquid Glass is hosted in a non-key floating panel. These private AppKit appearance hooks are
/// the same narrow override used by native-looking third-party docks to keep the material active.
final class DockLiquidGlassPanel: NonConstrainingPanel {
    @objc(_hasActiveAppearance)
    func bestDockHasActiveAppearance() -> Bool { true }

    @objc(_hasActiveAppearanceIgnoringKeyFocus)
    func bestDockHasActiveAppearanceIgnoringKeyFocus() -> Bool { true }

    @objc(_hasKeyAppearance)
    func bestDockHasKeyAppearance() -> Bool { true }

    @objc(_hasMainAppearance)
    func bestDockHasMainAppearance() -> Bool { true }

    @objc(_hasActiveControls)
    func bestDockHasActiveControls() -> Bool { true }
}
