import Foundation

/// Plain-text diagnostics the user copies from Settings ▸ About and pastes to us.
///
/// It is data for us, like a log line: the labels stay English in every UI language. Nothing
/// here is sent anywhere — the feedback form's disclosed fields are unchanged.
struct DiagnosticReport: Equatable {
    struct GlassReading: Equatable {
        let label: String
        /// `TEDockGlassDescribeLayer`'s output; nil when no glass filter could be read.
        let reading: String?
        /// Only for a live panel on the system-variant plate: which window state its material is.
        var state: GlassState? = nil
    }

    /// Which window state AppKit sampled into a live glass panel, decided against two throwaway
    /// windows of the same size and variant on the same machine — never against a table of
    /// per-version numbers: the inactive blur radius grows with the panel's height, so a reading
    /// from any other size (the `glass variants` line is 400x54) is not comparable.
    enum GlassState: Equatable {
        case active
        case inactive
        /// Matches neither reference; both are carried so the paste still tells us what they were.
        case unmatched(inactive: String?, active: String?)
        /// The two references read the same on this machine (the fields that differ here are
        /// unreadable, or the predicates are ignored), so no reading could tell the states apart.
        case undecidable(inactive: String, active: String)
    }

    /// `R` (refraction) is dropped before comparing: the taskbar and capsule overwrite it with the
    /// fixed Dock amount, and it also scales with height, so it never tells states apart.
    static func classify(reading: String?, inactive: String?, active: String?) -> GlassState? {
        guard let reading, inactive != nil || active != nil else { return nil }
        if let inactive, let active, stateSignature(inactive) == stateSignature(active) {
            return .undecidable(inactive: inactive, active: active)
        }
        let signature = stateSignature(reading)
        if let active, stateSignature(active) == signature { return .active }
        if let inactive, stateSignature(inactive) == signature { return .inactive }
        return .unmatched(inactive: inactive, active: active)
    }

    private static func stateSignature(_ reading: String) -> [String] {
        reading.split(separator: " ").map(String.init).filter { !$0.hasPrefix("R") }
    }

    var appVersion: String?
    var systemVersion: String
    var hardwareModel: String?
    var language: String
    var appearance: String
    var reduceTransparency: Bool
    var increaseContrast: Bool
    var displays: [String]
    var glassPath: String
    /// Whether the taskbar's glass composite is actually up (`glassPath` is only the configuration).
    var glassComposite: String
    /// Whether this AppKit still has the hook the glass view uses to re-sample its window state.
    var glassRefresh: String
    var glassTint: String?
    /// What each private variant number resolves to on this system.
    var glassVariants: [GlassReading]
    /// What the live glass panels actually carry, hidden ones included (an auto-hidden bar is
    /// still the bar; the label says so).
    var glassPanels: [GlassReading]
    /// The live panels as they were the first time this process became active with the bar up;
    /// nil when that has not happened yet. Activation re-samples the glass (healing the inactive
    /// material) and Settings activates the app before the user can press Copy, so `glassPanels`
    /// may already be post-activation. This line covers only those panels at that moment:
    /// panels rebuilt later (a display change) and later faults are outside it.
    var glassPanelsAtFirstActivation: [GlassReading]? = nil

    var text: String {
        let system = [systemVersion, hardwareModel].compactMap { $0 }.joined(separator: " · ")
        return [
            "NeoBar diagnostics",
            "app: \(appVersion ?? "unknown")",
            "macOS: \(system)",
            "language: \(language)",
            "appearance: \(appearance)",
            "accessibility: reduceTransparency=\(reduceTransparency ? 1 : 0) increaseContrast=\(increaseContrast ? 1 : 0)",
            "displays: \(Self.joined(displays, separator: ", "))",
            "glass path: \(glassPath)",
            "glass composite: \(glassComposite)",
            "glass refresh: \(glassRefresh)",
            "glass tint: \(glassTint ?? "unset")",
            "glass variants: \(Self.joined(glassVariants.map(Self.line), separator: " | "))",
            "glass panels: \(Self.joined(glassPanels.map(Self.line), separator: " | "))",
            "glass panels at first activation: "
                + (glassPanelsAtFirstActivation.map { Self.joined($0.map(Self.line), separator: " | ") }
                    ?? "not captured"),
        ].joined(separator: "\n")
    }

    private static func line(_ reading: GlassReading) -> String {
        let base = "\(reading.label)=\(reading.reading ?? "unreadable")"
        switch reading.state {
        case nil: return base
        case .active?: return base + " [active]"
        case .inactive?: return base + " [inactive]"
        case .unmatched(let inactive, let active)?:
            return base + " [unmatched; inactive=\(inactive ?? "unreadable") active=\(active ?? "unreadable")]"
        case .undecidable(let inactive, let active)?:
            return base + " [undecidable; inactive=\(inactive) active=\(active)]"
        }
    }

    private static func joined(_ items: [String], separator: String) -> String {
        items.isEmpty ? "none" : items.joined(separator: separator)
    }
}
