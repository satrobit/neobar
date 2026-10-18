import AppKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Visual Effect Background

/// The sole frosted-glass backing for all floating panels (strip / drawer / capsule / the two popups).
/// The `.behindWindow` blur and saturation boost are computed by WindowServer behind the window, and the material itself follows the system appearance.
struct DockVisualEffectView: NSViewRepresentable {
    /// Passed in by the caller according to the current appearance (`DockThemeTokens.panelMaterial`).
    var material: DockPanelMaterial = .popover

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material.nsMaterial
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    /// The material must really be applied: on an appearance change SwiftUI only reruns update and does not rebuild the NSView.
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        let resolved = material.nsMaterial
        if nsView.material != resolved { nsView.material = resolved }
    }
}
