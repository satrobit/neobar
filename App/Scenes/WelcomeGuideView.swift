import AppKit
import SwiftUI

/// Window root view. Same structure as the permission guide: the scrollbar normally doesn't appear, the window height is determined by the content's natural height,
/// and scrolling is truly needed only when truncated by the screen height.
struct WelcomeGuideWindowContent: View {
    let onApply: (WelcomeGuideSelection) -> Void
    let onDismiss: () -> Void

    var body: some View {
        ScrollView(.vertical) {
            WelcomeGuideView(onApply: onApply, onDismiss: onDismiss)
        }
        .frame(width: WelcomeGuideView.contentWidth)
    }
}

/// One-time first-run guide: the three recommended settings for yielding the system Dock to NeoBar.
///
/// The three belong to the **one** matter of "how the system Dock should cooperate with NeoBar", so they sit on the same screen (owner decided 2026-08-28,
/// extending 2026-08-20's "one screen talks about one thing" -- that rule blocked cramming the unrelated topics of Dock and drawer together).
/// Discoverability of the drawer's empty state is still a separate matter with its own to-do card, and is not squeezed in here.
///
/// Each of the three can be ticked on its own: this writes someone else's system preferences, and the user should be able to take only Dock hiding without changing the minimize animation.
///
/// ⚠️ **The "plainness" of this screen was settled step by step by the owner on 2026-08-28 after viewing it on a real device; it is not unfinished**: explanatory text
/// (subtitle, opening summary, the gray note under each checkbox) is all gone, the icon to the left of the title was removed, and the
/// gray block behind the ⌥⌘D passage was removed too. Sections are separated only by spacing and one divider line. On seeing bare switches, don't "helpfully" add back icons, color blocks, or notes.
/// The only remaining explanation is the splash preview on the left of the button row.
struct WelcomeGuideView: View {
    let onApply: (WelcomeGuideSelection) -> Void
    let onDismiss: () -> Void

    @State private var selection = WelcomeGuideSelection.recommended

    /// Fixed width: the window height is decided by `fittingSize`, and the width must not jitter with the copy length.
    /// Values match the permission guide; the two guide windows should look like one family.
    static let contentWidth: CGFloat = 520

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            // With the icon gone, the title must carry this screen's center of gravity itself, so it is one size larger than before.
            Text("Recommended Dock Settings")
                .font(.title2.weight(.semibold))

            options

            comeBackNote

            // With the color block removed, this line is the only divider between the "suggestion zone / action zone".
            Divider()

            HStack(spacing: 8) {
                // The only splash preview. Placed where the finger is about to tap, not inside a paragraph; **shown unconditionally** --
                // appearing/disappearing with the checkbox would make the window height not match the content (the height is measured only once, when the window is built).
                // The note yields, the buttons never do: without `fixedSize()` the HStack
                // squeezes the primary button to "Apply Recommended Set…" even in English
                // (measured 173pt of the 207pt it needs) while the note keeps free space.
                Text("The screen will flash once when you apply this.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Not Now") { onDismiss() }
                    .keyboardShortcut(.cancelAction)
                    .fixedSize()
                Button("Apply Recommended Settings") { onApply(selection) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection.isEmpty)
                    .fixedSize()
            }
        }
        .padding(28)
        .frame(width: Self.contentWidth, alignment: .leading)
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Hide the Dock (auto-hide, and don’t wake it at the bottom edge)", isOn: $selection.hidesDock)
            Toggle("Use the scale effect when minimizing", isOn: $selection.usesScaleMinimizeEffect)
            Toggle("Minimize windows into their app icon", isOn: $selection.minimizesIntoAppIcon)
        }
    }

    /// The way back must be spelled out (owner explicitly required 2026-08-20): this step makes the system Dock disappear entirely,
    /// and not telling the user how to bring it back would make him feel he has lost the Dock.
    ///
    /// ⚠️ When "Hide system Dock" is unticked it **only fades, never hides**: the window height was fixed with a one-shot probe when the window was built
    ///(`AppDelegate.showWelcomeWindow`) and is never re-measured afterwards, so any view added or removed with the tick would make the height not match.
    ///
    /// ⚠️ `⌥⌘D` belongs to macOS, so here it **can only be written as plain text**. NeoBar's global hotkey uses ⌥⇧⌘D;
    /// registering ⌥⌘D as a `keyEquivalent` would steal the system's shortcut (see the hotkey rules in AGENTS.md).
    private var comeBackNote: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Want the Dock back?")
                .font(.callout.weight(.semibold))
            Text("Press ⌥⌘D at any time — that’s macOS’s own shortcut for showing and hiding the Dock. You can also change this later from the NeoBar menu bar item.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.secondary)
        }
        .opacity(selection.hidesDock ? 1 : 0.4)
    }
}
