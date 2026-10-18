import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsWindowView: View {
    static let contentWidth: CGFloat = 560

    @ObservedObject var store: AppSettingsStore
    @ObservedObject var coordinator: SettingsCoordinator
    @ObservedObject var tabState: SettingsTabState
    /// Action for the "Reopen the welcome guide" button on the "General" page. **No default value**: no test here
    /// checks the SwiftUI call site, so a default would let an "omitted argument" compile (AGENTS.md's no-default iron rule).
    let onShowWelcomeGuide: () -> Void

    var body: some View {
        // ScrollView is kept as a small-screen fallback: every page is normally shorter than one screen, so measuring the height grows the window to the content height and no scrolling appears.
        // **The indicator must be off**: when the scrollbar style is "automatic" and a mouse is attached it is the space-reserving kind, and when it appears it eats about 15pt of visible width,
        // so during the 0.2s page-switch animation the content overflows -> the scrollbar is present -> the whole page shifts horizontally. The inner content must not hard-code a width either (see below).
        ScrollView(.vertical, showsIndicators: false) {
            SettingsWindowContent(
                store: store,
                coordinator: coordinator,
                tabState: tabState,
                onShowWelcomeGuide: onShowWelcomeGuide
            )
        }
        .frame(width: Self.contentWidth)
    }
}

struct SettingsWindowContent: View {
    @ObservedObject var store: AppSettingsStore
    @ObservedObject var coordinator: SettingsCoordinator
    @ObservedObject var tabState: SettingsTabState
    let onShowWelcomeGuide: () -> Void

    @State private var presentedAlert: SettingsAlert?
    @State private var showsScrollReverserHelp = false

    var body: some View {
        Group {
            switch tabState.selected {
            case .general: generalPane
            case .advanced: advancedPane
            case .about: aboutPane
            }
        }
        // No padding here: each pane brings its own, because the system form already insets
        // its boxes (`systemForm`) and the macOS 12 layouts pad by `Self.paneMargin`.
        // **Do not hard-code the width**: it is wrapped in a ScrollView, and a rigid width gets centered when the visible area narrows = the whole page shifts.
        // With a flexible width the left edge always stays at the padding, at worst reflowing text. The height-measuring probe is still given the contentWidth proposal.
        .frame(maxWidth: .infinity, alignment: .leading)
        .alert(item: $presentedAlert) { alert in
            guard let actionTitle = alert.actionTitle, let action = alert.action else {
                return Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    dismissButton: .default(Text("OK"))
                )
            }
            return Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                primaryButton: .default(Text(actionTitle), action: action),
                secondaryButton: .cancel(Text("Later"))
            )
        }
    }

    // Page bodies are all computed properties of **this root view** -- the draft @State must stay on the root; pushing it down into page-level subviews = cleared on every page switch.
    /// Every pane is the system's own grouped `Form` on macOS 13+ (`systemForm`), so radius,
    /// fill and dividers follow each OS release; macOS 12 has no grouped form and keeps the
    /// hand-built layouts in the `else` branches.
    ///
    /// The "General" page: one box — label leading, control trailing — with the setup-guide entry under
    /// it. Rows carry no grey note; the one disclosure this page owes (scroll reversal) sits
    /// behind that row's help button.
    @ViewBuilder
    private var generalPane: some View {
        if #available(macOS 13.0, *) {
            VStack(alignment: .trailing, spacing: 0) {
                systemForm {
                    languagePicker
                    // Plain stacks, not `LabeledContent`: that aligns on the text baseline, which
                    // an AppKit-backed control lacks — the recorder drops below its own label.
                    HStack {
                        Text("Appearance")
                        Spacer(minLength: 12)
                        appearanceCards
                    }
                    if Self.showsFrontWindowBarToggle {
                        frontWindowBarToggle
                            .toggleStyle(.switch)
                    }
                    HStack {
                        Text("Show/hide taskbar shortcut")
                        Spacer(minLength: 12)
                        hotKeyControls
                    }
                    HStack {
                        scrollReverserLabel
                        Spacer(minLength: 12)
                        scrollReverserToggle
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                }
                welcomeGuideButton
                    .padding(.trailing, Self.paneMargin)
            }
            .padding(.bottom, Self.paneMargin)
        } else {
            settingsPane {
                settingsGroup {
                    groupRow {
                        Text("Language")
                    } control: {
                        languagePicker
                            .labelsHidden()
                            .fixedSize()
                    }
                    Divider().opacity(0.5)
                    groupRow {
                        Text("Appearance")
                    } control: {
                        appearanceCards
                    }
                    if Self.showsFrontWindowBarToggle {
                        Divider().opacity(0.5)
                        groupRow {
                            Text("Mark the active window with a bar")
                        } control: {
                            frontWindowBarToggle
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .labelsHidden()
                        }
                    }
                    Divider().opacity(0.5)
                    groupRow {
                        Text("Show/hide taskbar shortcut")
                    } control: {
                        hotKeyControls
                    }
                    Divider().opacity(0.5)
                    groupRow {
                        scrollReverserLabel
                    } control: {
                        scrollReverserToggle
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .labelsHidden()
                    }
                }
                HStack {
                    Spacer()
                    welcomeGuideButton
                }
            }
            .padding(Self.paneMargin)
        }
    }

    /// Distance from the window edge to a pane's content, boxes included.
    private static let paneMargin: CGFloat = 28
    /// Margin a grouped `Form` keeps around its boxes.
    private static let systemFormMargin: CGFloat = 20

    /// A pane as the system's grouped form, its boxes `paneMargin` from the window's top and
    /// sides. The form's own bottom margin is left as is — what follows decides the rest.
    @available(macOS 13.0, *)
    private func systemForm<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        Form(content: content)
            .formStyle(.grouped)
            // The window is sized to its content and the page scrolls as a whole; a form that
            // scrolls by itself has no height to measure.
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
            .padding([.horizontal, .top], Self.paneMargin - Self.systemFormMargin)
    }

    /// Bottom padding for a pane that ends with its form.
    private static let afterFormMargin = paneMargin - systemFormMargin

    // "Advanced" = switches that need extra capabilities, are right by default, and basically never need touching. It is a separate page not to hide them,
    // but so the common pages keep only what is adjusted day to day; anyone who truly wants to refuse this capability can find it (owner 2026-08-09;
    // when pages were split on 2026-08-24 the owner confirmed keeping the "Advanced" page).
    @ViewBuilder
    private var advancedPane: some View {
        if #available(macOS 13.0, *) {
            systemForm {
                Section {
                    fullscreenIntentToggle
                } footer: {
                    Text(fullscreenIntentNote)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.bottom, Self.afterFormMargin)
        } else {
            settingsPane {
                settingRow(note: fullscreenIntentNote) {
                    fullscreenIntentToggle
                }
            }
            .padding(Self.paneMargin)
        }
    }

    private var fullscreenIntentToggle: some View {
        Toggle(
            "Predict full-screen transitions to prevent taskbar flicker",
            isOn: binding(
                get: { store.fullscreenIntentEnabled },
                set: store.setFullscreenIntentEnabled
            )
        )
    }

    private var fullscreenIntentNote: String {
        String(localized: "To keep the taskbar from flashing when you switch into full screen, NeoBar has to hide it before your input reaches the app. It therefore watches global left-clicks, key presses and trackpad gestures, and recognizes only four of them: the window’s green button, Control-Command-F, Control-Left/Right arrow, and a three-finger horizontal swipe. What you type is never recorded, logged, or sent anywhere. Turning this off disables the watching completely.")
    }

    @ViewBuilder
    private var aboutPane: some View {
        if #available(macOS 13.0, *) {
            systemForm {
                aboutVersionRow
                diagnosticsRow
            }
            .padding(.bottom, Self.afterFormMargin)
        } else {
            settingsPane {
                aboutVersionRow
                diagnosticsRow
            }
            .padding(Self.paneMargin)
        }
    }

    /// Copies `DiagnosticReport` to the clipboard. Nothing is sent anywhere.
    private var diagnosticsRow: some View {
        HStack(spacing: 12) {
            Text("Diagnostic Info")
            Spacer()
            Button("Copy") {
                let report = DiagnosticReport.collect(appVersion: coordinator.versionTitle)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(report.text, forType: .string)
                Self.presentCopiedDiagnostics(report.text)
            }
        }
    }

    /// Shows what was just copied, so the user sees exactly what they are about to paste.
    /// An `NSAlert` sheet rather than `SettingsAlert`: a SwiftUI alert cannot hold a scrolling
    /// text box, and the report as a plain message makes the alert a screen tall.
    private static func presentCopiedDiagnostics(_ text: String) {
        // The scrollable-text-view factory sizes the document to its content and starts at the
        // top; a hand-built NSTextView in a scroll view opens scrolled one line down.
        let scrollView = NSTextView.scrollableTextView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 420, height: 236)
        scrollView.borderType = .bezelBorder
        if let textView = scrollView.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            textView.textContainerInset = NSSize(width: 6, height: 6)
            textView.string = text
        }

        let alert = NSAlert()
        alert.messageText = String(localized: "Diagnostic Info Copied")
        alert.informativeText = String(localized: "It contains only the app, system and display details shown below — no personal information.")
        alert.accessoryView = scrollView
        alert.addButton(withTitle: String(localized: "OK"))
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    // Launch at login moved twice on 2026-08-24 alone: it entered the settings window along with dedup, and after the owner reconsidered it was settled as
    // **only in the status bar menu (first item)**. It's no longer placed here, and the didBecomeActive refresh is no longer needed either.

    /// Interface language (added 2026-08-24; on 2026-09-01 reduced from three options to two, dropping "Follow System"; see `Docs/27`).
    /// Writes `AppleLanguages` in the **app's own domain** (the same key as macOS 13+ per-app language); takes effect after restart.
    /// Reading the current state must go through `CFPreferencesCopyAppValue` -- `array(forKey:)` inherits the global domain,
    /// and can't distinguish "never set" from "explicitly set" (the `AppLanguageOption` comment is authoritative).
    ///
    /// ⚠️ For someone who never set a language the key doesn't exist, and the picker then shows an **inferred value** (the `.lproj`
    /// actually loaded). **This read path must never write back**: writing back would pin the language for every user who never chose one.
    private var languagePicker: some View {
        Picker(
            String(localized: "Language"),
            selection: Binding(
                get: { Self.currentLanguageOption() },
                set: { applyLanguage($0) }
            )
        ) {
            ForEach(AppLanguageOption.allCases, id: \.self) { option in
                Text(option.displayName).tag(option)
            }
        }
        .pickerStyle(.menu)
    }

    private static func currentLanguageOption() -> AppLanguageOption {
        let bundleID = (Bundle.main.bundleIdentifier ?? "") as CFString
        let value = CFPreferencesCopyAppValue("AppleLanguages" as CFString, bundleID) as? [String]
        return AppLanguageOption.current(
            appDomainValue: value,
            // The `.lproj` actually loaded -- more accurate than inferring the system language: if the user set a third language for NeoBar alone in System Settings,
            // the UI actually falls back to English, and this answers English.
            effectiveLocalization: Bundle.main.preferredLocalizations.first ?? "en"
        )
    }

    /// The selected option is **always written to the key**, even if the click is on the currently displayed one -- that one may be just an inferred value (key absent),
    /// and clicking it means "pin to this"; without writing, it would still follow the system. But when the UI language didn't actually change, **no restart prompt is shown**:
    /// asking people to restart when nothing changed is a nuisance.
    private func applyLanguage(_ option: AppLanguageOption) {
        let previous = Self.currentLanguageOption()
        UserDefaults.standard.set(option.appleLanguagesValue, forKey: "AppleLanguages")
        guard option != previous else { return }
        presentedAlert = SettingsAlert(
            title: String(localized: "Language"),
            message: String(localized: "The language change takes effect after NeoBar restarts."),
            actionTitle: String(localized: "Restart NeoBar"),
            action: { Self.relaunch() }
        )
    }

    /// Spawn a shell process that "sleeps half a second then runs open", then quit. By the time the new instance launches the old one has fully exited,
    /// so `terminateOtherInstances()` won't kill anyone in return. No need to clear the environment again -- the process entry
    /// `ProcessEnvironmentScrub.apply()` has already done it, and what the child inherits is a clean environment.
    private static func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 0.5; /usr/bin/open \"$0\"", Bundle.main.bundleURL.path]
        try? process.run()
        NSApp.terminate(nil)
    }

    /// Show/hide taskbar hotkey: a recorder field + a "Restore Default" button that appears only after customization. The row height is constant
    ///(the recording state changes only the text, not the size, and the button appears within the same row), so there's no need to add a sink to
    /// `SettingsWindowController.sessionSubscriptions`.
    @ViewBuilder
    private var hotKeyControls: some View {
        HStack(spacing: 10) {
            if store.edgeToggleShortcut != nil {
                Button("Reset to Default") { applyShortcut(nil) }
            }
            HotKeyRecorder(
                currentGlyphs: store.edgeToggleShortcut?.glyphs
                    ?? GlobalHotKeyShortcut.edgeAutoHideMode.displayGlyphs,
                onRecord: { applyShortcut($0) },
                onRejectKey: {
                    presentedAlert = SettingsAlert(
                        title: String(localized: "Can’t Use This Shortcut"),
                        message: String(localized: "This key can’t be used as the shortcut key.")
                    )
                }
            )
            .fixedSize()
        }
    }

    /// App-wide appearance (`AppearanceMode`). The third option is `System`, never `Auto`:
    /// macOS's Auto switches by time of day, this one follows whatever macOS is showing.
    private var appearanceCards: some View {
        AppearanceModeCards(selection: store.appearanceMode, onSelect: store.setAppearanceMode)
    }

    /// Globally reverse the mouse wheel. It acts on the whole system, not just the taskbar, so it goes under "General".
    /// The description must state clearly that it "only rewrites the direction value, and neither records nor sends" -- this is the only feature in the whole project that rewrites other people's input events.
    /// It sits behind the help button beside the title, not under the toggle: the page shows
    /// no notes, but this disclosure must stay reachable in the app — and a hover tooltip is
    /// not reachable enough (it needs a still pointer and an active window).
    private var scrollReverserToggle: some View {
        Toggle(
            "Reverse mouse scroll direction",
            isOn: binding(get: { store.scrollReverserEnabled }, set: store.setScrollReverserEnabled)
        )
    }

    /// The front-window bar is held back from release: the row stays built (its strings stay referenced
    /// for check_localization) but is not shown, so `frontWindowBar` keeps its default off.
    private static let showsFrontWindowBarToggle = false

    private var frontWindowBarToggle: some View {
        Toggle(
            "Mark the active window with a bar",
            isOn: binding(get: { store.frontWindowBar }, set: store.setFrontWindowBar)
        )
    }

    private var scrollReverserLabel: some View {
        HStack(spacing: 6) {
            Text("Reverse mouse scroll direction")
            // A text-sized symbol, not the system help bezel: that one is as tall as the row.
            Button { showsScrollReverserHelp = true } label: {
                Image(systemName: "questionmark.circle")
                    .foregroundStyle(.secondary)
            }
                .buttonStyle(.plain)
                // A bare symbol reads as an unnamed button; say the disclosure itself.
                .accessibilityLabel(Text(scrollReverserHelp))
                .popover(isPresented: $showsScrollReverserHelp, arrowEdge: .bottom) {
                    Text(scrollReverserHelp)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: 300, alignment: .leading)
                        .padding(14)
                }
        }
    }

    private var scrollReverserHelp: String {
        String(localized: "Flips mouse-wheel scrolling system-wide, like Scroll Reverser. Trackpads and Magic Mouse are not affected. NeoBar only inverts the direction values of scroll-wheel events; nothing is recorded or sent anywhere. If Scroll Reverser or Mos is also running, the two cancel out — keep only one.")
    }

    /// Reopen the first-run guide (the window that writes the recommended system Dock settings). Moved from the status bar menu on 2026-09-01
    ///(owner's call): it is an entry to "open another interface", not a switch to flip casually.
    /// Placed under the "General" page's group box -- the box holds settings, this is an entry.
    ///
    /// ⚠️ The closure goes straight through to `AppDelegate.showWelcomeWindow()`; it **must never be changed to go through
    /// `presentWelcomeGuideIfNeeded()`, nor rely on deleting `hasSeenWelcome`**: that decision function happens to skip
    /// existing users whose "system Dock is already auto-hidden" and writes the key back, and existing users are the entire audience of this entry.
    private var welcomeGuideButton: some View {
        Button("Show Setup Guide Again") { onShowWelcomeGuide() }
    }

    private func applyShortcut(_ stored: StoredHotKeyShortcut?) {
        if case .failure(let error) = coordinator.applyEdgeToggleShortcut(stored) {
            presentedAlert = SettingsAlert(
                hotKeyError: error,
                attemptedGlyphs: stored?.glyphs ?? GlobalHotKeyShortcut.edgeAutoHideMode.displayGlyphs
            )
        }
    }

    private var aboutVersionRow: some View {
        HStack(spacing: 12) {
            if let versionTitle = coordinator.versionTitle {
                Text(versionTitle)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    /// Row container of a page. Section titles were removed with the 2026-08-24 pagination (the window title takes over), leaving only uniform row spacing.
    ///
    /// The row spacing of 20 is paired with `settingRow`'s 3: the **contrast of 20 : 3** is what makes "a setting row + the
    /// gray description under it" read as a whole. It used to be 12 : 3, and the four lines of text blurred together (owner 2026-09-01).
    private func settingsPane<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// macOS 12 stand-in for the grouped form's box: rows stacked edge to edge, a `Divider()`
    /// between them.
    private func settingsGroup<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .padding(.horizontal, 14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }

    /// One row of a `settingsGroup`: label leading, control(s) pushed to the trailing edge.
    private func groupRow<Label: View, Control: View>(
        @ViewBuilder label: () -> Label,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(spacing: 10) {
            label()
            Spacer(minLength: 12)
            control()
        }
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }

    /// A toggle + one line of gray description. The description is for people who "don't know what this toggle does";
    /// there's no room for it in the menu, but the settings window has plenty.
    private func settingRow<Content: View>(
        note: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            content()
            Text(note)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func binding<Value>(
        get: @escaping () -> Value,
        set: @escaping (Value) -> Void
    ) -> Binding<Value> {
        Binding(get: get, set: set)
    }
}

/// The three `AppearanceMode` choices as plain cards: a symbol over the name, the chosen one
/// tinted and ringed in the accent colour.
private struct AppearanceModeCards: View {
    let selection: AppearanceMode
    let onSelect: (AppearanceMode) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(AppearanceMode.allCases, id: \.self) { mode in
                let isSelected = mode == selection
                Button { onSelect(mode) } label: {
                    VStack(spacing: 5) {
                        Image(systemName: Self.symbolName(for: mode))
                            .font(.system(size: 16))
                            .foregroundColor(isSelected ? .accentColor : .secondary)
                            .frame(height: 18)
                        Text(mode.displayName)
                            .font(.caption)
                    }
                    .padding(.horizontal, 10)
                    .frame(minWidth: 76, minHeight: 52)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.05))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.accentColor, lineWidth: 1.5)
                            .opacity(isSelected ? 1 : 0)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }

    private static func symbolName(for mode: AppearanceMode) -> String {
        switch mode {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }
}

private struct SettingsAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    /// Optional second button (such as "Restart Now" for the language switch). When nil there is only "OK".
    let actionTitle: String?
    let action: (() -> Void)?

    init(title: String, message: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    /// Hotkey change failed -> one actionable sentence in plain language. Rejection reasons are given one by one (each has a different next step);
    /// registration failure has only one real cause (the combination is registered exclusively by another app).
    init(hotKeyError: HotKeyChangeError, attemptedGlyphs: String) {
        switch hotKeyError {
        case .rejected(.missingPrimaryModifier):
            self.init(
                title: String(localized: "Can’t Use This Shortcut"),
                message: String(localized: "Use at least one of Command, Control or Option.")
            )
        case .rejected(.unreliableModifiers):
            self.init(
                title: String(localized: "Can’t Use This Shortcut"),
                message: String(localized: "Option alone or Option-Shift is unreliable on macOS 15.")
            )
        case .rejected(.reservedBySystem):
            self.init(
                title: String(localized: "Can’t Use This Shortcut"),
                message: String(localized: "This combination belongs to macOS (⌥⌘D shows/hides the Dock; Control-Option is VoiceOver’s).")
            )
        case .rejected(.forbiddenKey):
            self.init(
                title: String(localized: "Can’t Use This Shortcut"),
                message: String(localized: "Escape and Delete can’t be the key.")
            )
        case .registrationFailed:
            self.init(
                title: String(localized: "Couldn’t Register the Shortcut"),
                message: String(
                    format: String(localized: "%@ is already taken by another app. The previous shortcut stays active."),
                    attemptedGlyphs
                )
            )
        }
    }
}

// App-only half of `DiagnosticReport`: the pure struct is also compiled into the test target,
// which has neither the glass bridge nor the panels.
extension DiagnosticReport {
    /// Variants read back for the report; the Dock's own material has been seen at 2 and at 3.
    static let reportedVariants = 0 ... 6

    /// Main thread, from a user action only — the variant read-back builds throwaway windows,
    /// which must not happen inside a SwiftUI update.
    static func collect(appVersion: String?) -> DiagnosticReport {
        let workspace = NSWorkspace.shared
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return DiagnosticReport(
            appVersion: appVersion,
            systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            hardwareModel: hardwareModel(),
            language: Bundle.main.preferredLocalizations.first ?? "en",
            appearance: "\(isDark ? "dark" : "light") (\(NSApp.appearance == nil ? "follows system" : "fixed"))",
            reduceTransparency: workspace.accessibilityDisplayShouldReduceTransparency,
            increaseContrast: workspace.accessibilityDisplayShouldIncreaseContrast,
            displays: NSScreen.screens.map {
                "\(Int($0.frame.width))x\(Int($0.frame.height))@\(Int($0.backingScaleFactor))x"
            },
            glassPath: glassPath(),
            glassComposite: glassComposite(),
            glassRefresh: TEDockGlassSupportsWindowStateRefresh()
                ? "supported" : "unsupported (no _windowChangedKeyState)",
            glassTint: UserDefaults.standard.object(forKey: "NSGlassTintAmount").map { "\($0)" },
            glassVariants: glassVariantReadings(),
            glassPanels: livePanelReadings(),
            glassPanelsAtFirstActivation: panelsAtFirstActivation
        )
    }

    /// Hidden panels stay listed: an auto-hidden bar reads "none" otherwise, which looks like
    /// "no glass" — the very thing this line exists to tell apart.
    private static func livePanelReadings() -> [GlassReading] {
        NSApp.windows
            .filter { $0 is DockLiquidGlassPanel }
            .map { window in
                GlassReading(
                    label: "\(Int(window.frame.width))x\(Int(window.frame.height))"
                        + (window.isVisible ? "" : " hidden"),
                    reading: window.contentView?.layer.flatMap { TEDockGlassDescribeLayer($0) },
                    state: glassState(of: window)
                )
            }
    }

    private static var panelsAtFirstActivation: [GlassReading]?
    private static var firstActivationObserver: NSObjectProtocol?

    /// Records the live panels the first time the app becomes active with the bar up. AppKit posts
    /// `willBecomeActive` before it re-samples the window state into the glass (on 27.0 the
    /// re-sample lands after `didBecomeActive`; `scratch/order_probe.swift`), so this is a reading
    /// the activation has not touched yet. One shot, for those panels only — later faults and
    /// panels rebuilt after a display change are not covered. An activation before the bar
    /// exists (permission onboarding) is skipped, not consumed.
    static func armFirstActivationSnapshot() {
        guard firstActivationObserver == nil, panelsAtFirstActivation == nil else { return }
        firstActivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            let panels = livePanelReadings()
            guard !panels.isEmpty else { return }
            panelsAtFirstActivation = panels
            if let observer = firstActivationObserver { NotificationCenter.default.removeObserver(observer) }
            firstActivationObserver = nil
        }
    }

    /// The window state baked into a system-variant plate, told apart by two never-shown windows
    /// of the plate's own size: a plain `NSWindow` (inactive) and a `DockLiquidGlassPanel` (its
    /// predicates answer active). Nil for panels on another material.
    private static func glassState(of window: NSWindow) -> GlassState? {
        guard let variant = DockGlassPresentation.activeSystemVariant,
              let plate = DockGlassPresentation.systemVariantGlassViews(in: window).first,
              let reading = plate.layer.flatMap({ TEDockGlassDescribeLayer($0) }) else { return nil }
        let size = plate.bounds.size
        return classify(
            reading: reading,
            inactive: referenceReading(variant: variant, size: size, activePredicates: false),
            active: referenceReading(variant: variant, size: size, activePredicates: true)
        )
    }

    /// `TEDockGlassDescribeVariant` at a chosen size and window class. Main thread, from a user
    /// action only: it builds a throwaway window.
    private static func referenceReading(variant: Int, size: NSSize, activePredicates: Bool) -> String? {
        guard #available(macOS 26.0, *), size.width > 0, size.height > 0 else { return nil }
        let frame = NSRect(origin: .zero, size: size)
        let window: NSWindow = activePredicates
            ? DockLiquidGlassPanel(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: true)
            : NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let glass = NSGlassEffectView(frame: frame)
        glass.contentView = NSView(frame: frame)
        guard TEDockGlassSetSystemVariant(glass, variant) else { return nil }
        window.contentView = NSView(frame: frame)
        window.contentView?.addSubview(glass)
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        // The live plate re-samples once after attach (`DockSystemGlassEffectView`); mirror it so
        // the reference is what that plate would read, not what a plain view reads.
        _ = TEDockGlassRefreshWindowState(glass)
        return glass.layer.flatMap { TEDockGlassDescribeLayer($0) }
    }

    /// `glassPath` is the configuration; this is what the running bar actually got. The glass
    /// composite exists exactly when its background panel does (`PanelCoordinator.usesLiquidGlass`),
    /// and that panel keeps its view for the bar's whole life, so counting those windows is the
    /// same answer every unit would give.
    private static func glassComposite() -> String {
        guard DockGlassPresentation.shouldAttemptTaskbarComposite else { return "off (frosted path)" }
        let backgrounds = NSApp.windows.filter { $0.contentView is DockTaskbarLiquidGlassBackgroundView }.count
        guard backgrounds > 0 else { return "down (bar on the frosted fallback)" }
        return "up (\(backgrounds) background panel\(backgrounds == 1 ? "" : "s"))"
    }

    private static func glassPath() -> String {
        guard DockGlassPresentation.shouldAttemptTaskbarComposite else { return "frosted" }
        if let variant = DockGlassPresentation.activeSystemVariant { return "variant \(variant)" }
        return DockGlassPresentation.configuration.systemVariant == nil
            ? "swiftui clear (variant switched off)"
            : "swiftui clear (no variant selector)"
    }

    private static func glassVariantReadings() -> [GlassReading] {
        guard TEDockGlassSupportsSystemVariant() else { return [] }
        return reportedVariants.map { GlassReading(label: "\($0)", reading: TEDockGlassDescribeVariant($0)) }
    }

    private static func hardwareModel() -> String? {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}
