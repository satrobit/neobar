import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Hotkey recording field in the settings window. Click to enter the recording state ("Press new combination…"); pressing a combination reports it immediately;
/// Esc, clicking again, or losing focus all cancel. **Fixed size**: the recording state only swaps the text, not the row height,
/// so the settings window needn't re-measure its height (the height-measuring rule of `SettingsWindowController`).
///
/// Uses the first responder's `keyDown` rather than `NSEvent.addLocalMonitorForEvents`: a monitor must be remembered to tear down
/// and also swallows keys meant for other input fields; the first responder naturally receives only its own. While recording, `performKeyEquivalent`
/// must return true: combinations like ⌘Q / ⌘W go through the key-equivalent channel first, and unless intercepted they would directly trigger window commands.
struct HotKeyRecorder: NSViewRepresentable {
    let currentGlyphs: String
    let onRecord: (StoredHotKeyShortcut) -> Void
    /// Reported to the upper layer to show a hint when the main key can't be displayed (function keys not in the table, etc.).
    let onRejectKey: () -> Void

    func makeNSView(context: Context) -> HotKeyRecorderNSView {
        let view = HotKeyRecorderNSView()
        view.idleGlyphs = currentGlyphs
        view.onRecord = onRecord
        view.onRejectKey = onRejectKey
        return view
    }

    func updateNSView(_ view: HotKeyRecorderNSView, context: Context) {
        view.idleGlyphs = currentGlyphs
        view.onRecord = onRecord
        view.onRejectKey = onRejectKey
    }
}

final class HotKeyRecorderNSView: NSView {
    var idleGlyphs: String = "" {
        didSet { if !isRecording { label.stringValue = idleGlyphs } }
    }
    var onRecord: ((StoredHotKeyShortcut) -> Void)?
    var onRejectKey: (() -> Void)?

    private let label = NSTextField(labelWithString: "")
    private var isRecording = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        label.alignment = .center
        label.font = .systemFont(ofSize: NSFont.systemFontSize(for: .regular))
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 6),
        ])
        refreshChrome()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("HotKeyRecorderNSView is code-only") }

    override var intrinsicContentSize: NSSize { NSSize(width: 132, height: 24) }
    override var acceptsFirstResponder: Bool { true }
    /// Focus means "recording", so only a click may give it: left in the key-view loop, the
    /// window hands it focus on open and the next shortcut typed rebinds the hot key.
    override var canBecomeKeyView: Bool { false }

    override func mouseDown(with event: NSEvent) {
        if isRecording {
            window?.makeFirstResponder(nil)
        } else {
            window?.makeFirstResponder(self)
        }
    }

    override func becomeFirstResponder() -> Bool {
        isRecording = true
        showPrompt()
        refreshChrome()
        return true
    }

    override func resignFirstResponder() -> Bool {
        endRecording()
        return true
    }

    override func flagsChanged(with event: NSEvent) {
        guard isRecording else { return }
        let mods = Self.carbonModifiers(from: event.modifierFlags)
        if mods == 0 {
            showPrompt()
        } else {
            label.stringValue = HotKeyGlyphs.modifierString(carbonModifiers: mods)
        }
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }
        handleRecordingKey(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording, event.type == .keyDown else {
            return super.performKeyEquivalent(with: event)
        }
        handleRecordingKey(event)
        return true
    }

    private func handleRecordingKey(_ event: NSEvent) {
        if Int(event.keyCode) == kVK_Escape {
            window?.makeFirstResponder(nil)
            return
        }
        let mods = Self.carbonModifiers(from: event.modifierFlags)
        guard let glyphs = HotKeyGlyphs.display(
            keyCode: UInt32(event.keyCode),
            carbonModifiers: mods,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers
        ) else {
            window?.makeFirstResponder(nil)
            onRejectKey?()
            return
        }
        let stored = StoredHotKeyShortcut(
            keyCode: UInt32(event.keyCode),
            carbonModifiers: mods,
            glyphs: glyphs
        )
        window?.makeFirstResponder(nil)
        onRecord?(stored)
    }

    private func endRecording() {
        guard isRecording else { return }
        isRecording = false
        label.stringValue = idleGlyphs
        refreshChrome()
    }

    private func showPrompt() {
        label.stringValue = String(localized: "Press new shortcut…")
    }

    // A `CGColor` is resolved once, for the appearance current at that moment: re-resolve under
    // this view's own appearance, and again whenever it changes, or the box keeps the old one.
    private func refreshChrome() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshChrome()
    }

    private static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        return mods
    }
}
