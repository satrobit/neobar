import AppKit
import SwiftUI

// MARK: - Native right-click menu infrastructure
//
// The chips use a hand-built AppKit `NSMenu` instead of SwiftUI's `.contextMenu`,
// so the "Quit App" / "Force Quit" pair can use AppKit's native *alternate item*
// (`isAlternate` + Option modifier): with the menu already open, holding Option
// swaps the visible item live — exactly like the system Dock. SwiftUI's
// `.contextMenu` is a static snapshot once open and cannot do this.

/// An `NSMenuItem` that runs a closure when picked (AppKit needs target/action).
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func invoke() { handler() }
}

/// A transparent overlay NSView that provides a native menu on right-click /
/// control-click, while passing every other click through to the SwiftUI chip
/// beneath it (so tap-to-activate and drag-reorder are unaffected).
final class MenuHostNSView: NSView {
    var builder: (() -> NSMenu)?
    /// Channel where the caller handles presentation itself (right-click on the taskbar / capsule goes through this). When set, `builder` is no longer used:
    /// the NeoBar menu is the **same** `NSMenu` instance owned by `StatusMenuController` (the sliders inside are stateful
    /// custom-drawn NSViews and can't be cloned), and the popup timing is also its responsibility, so the menu object is not leaked out.
    var popUpHandler: ((NSEvent, NSView) -> Void)?
    /// Hit-test filter (screen coordinates). The taskbar backplate uses it to narrow the responsive area to "blank space at both ends + dividers";
    /// other call sites don't set it, and behavior is exactly as before.
    var shouldClaim: ((CGPoint) -> Bool)?

    // Only claim right-click / control-click; return nil otherwise so the click
    // falls through to the SwiftUI content below this overlay.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard super.hitTest(point) != nil, let e = NSApp.currentEvent else { return nil }
        if let shouldClaim, !shouldClaim(NSEvent.mouseLocation) { return nil }
        switch e.type {
        case .rightMouseDown, .rightMouseUp, .rightMouseDragged:
            return self
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged:
            return e.modifierFlags.contains(.control) ? self : nil
        default:
            return nil
        }
    }

    override func rightMouseDown(with event: NSEvent) { popUp(event) }
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { popUp(event) }
        else { super.mouseDown(with: event) }
    }

    private func popUp(_ event: NSEvent) {
        if let popUpHandler {
            popUpHandler(event, self)
            return
        }
        guard let menu = builder?(), !menu.items.isEmpty else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

struct NativeMenuHost: NSViewRepresentable {
    var builder: (() -> NSMenu)?
    var popUpHandler: ((NSEvent, NSView) -> Void)?
    var shouldClaim: ((CGPoint) -> Bool)?

    init(builder: @escaping () -> NSMenu) {
        self.builder = builder
    }

    init(
        popUpHandler: @escaping (NSEvent, NSView) -> Void,
        shouldClaim: ((CGPoint) -> Bool)? = nil
    ) {
        self.popUpHandler = popUpHandler
        self.shouldClaim = shouldClaim
    }

    func makeNSView(context: Context) -> MenuHostNSView {
        let v = MenuHostNSView()
        v.builder = builder
        v.popUpHandler = popUpHandler
        v.shouldClaim = shouldClaim
        return v
    }
    func updateNSView(_ v: MenuHostNSView, context: Context) {
        // keep the closures capturing current SwiftUI state
        v.builder = builder
        v.popUpHandler = popUpHandler
        v.shouldClaim = shouldClaim
    }
}

extension View {
    /// Attach a native AppKit right-click menu, rebuilt fresh on each open.
    func nativeContextMenu(_ builder: @escaping () -> NSMenu) -> some View {
        overlay(NativeMenuHost(builder: builder))
    }
}

// MARK: - Shared menu fragments

enum AppMenuBuilder {

    /// Render one membership descriptor as a native AppKit menu item. AppKit owns
    /// the checkmark; SwiftUI/store state is captured when the menu is rebuilt.
    static func membershipItem(_ descriptor: LauncherMembershipItem) -> NSMenuItem {
        let item = ClosureMenuItem(descriptor.label, handler: descriptor.action)
        if let isChecked = descriptor.isChecked {
            item.state = isChecked ? .on : .off
        }
        return item
    }

    /// Append "Quit App" plus, for non-self apps, the Option-alternate "Force Quit".
    /// The two are an alternate pair: same (empty) key equivalent, the second
    /// `isAlternate` with the Option modifier → live swap while the menu is open.
    static func appendQuitItems(
        to menu: NSMenu,
        bundleID: String?,
        onForceQuit: (() -> Void)? = nil,
        onQuit: @escaping () -> Void
    ) {
        let quit = ClosureMenuItem(String(localized: "Quit App"), handler: onQuit)
        quit.keyEquivalentModifierMask = []
        menu.addItem(quit)

        guard let bid = bundleID, bid != Bundle.main.bundleIdentifier else { return }
        let force = ClosureMenuItem(String(localized: "Force Quit")) {
            if let onForceQuit {
                onForceQuit()
            } else {
                NSRunningApplication
                    .runningApplications(withBundleIdentifier: bid)
                    .first?
                    .forceTerminate()
            }
        }
        force.keyEquivalentModifierMask = [.option]
        force.isAlternate = true
        menu.addItem(force)
    }

    /// Dock-style window list (app-level icons only; concrete window cards don't list it): ✓ = frontmost window, ◇ = minimized,
    /// click = activate (restore if minimized). Entries come from the pure `WindowListMenuPlan` (read-only snapshot,
    /// no AX at all on the menu path). An empty list adds nothing.
    static func appendWindowList(
        to menu: NSMenu,
        entries: [WindowMenuEntry],
        activate: @escaping (String) -> Void
    ) {
        guard !entries.isEmpty else { return }
        for entry in entries {
            let item = ClosureMenuItem(entry.title) { activate(entry.actionWindowID) }
            switch entry.marker {
            case .none:
                break
            case .front:
                item.state = .on
            case .minimized:
                // ◇: the native Dock's minimized marker. The SF Symbol "diamond" exists as far back as macOS 12;
                // if it can't be obtained (theoretical defense), fall back to a text prefix so the marker doesn't silently vanish.
                if let diamond = NSImage(
                    systemSymbolName: "diamond",
                    accessibilityDescription: String(localized: "Minimized")
                ) {
                    item.state = .on
                    item.onStateImage = diamond
                } else {
                    item.title = "◇ " + entry.title
                }
            }
            menu.addItem(item)
        }
        menu.addItem(.separator())
    }

    /// "Most-used files" section (changed from the sort of "recently used files" on 2026-08-24), inline at the menu top.
    /// Candidates = the system recents list (20 read as the sorting pool) ∪ NeoBar's own count ledger; count descending, ties by recency,
    /// those never counted go to the bottom in the system recents order (right after an upgrade this matches the old "recents"). The current top item is also handed to
    /// `DocumentUsageStore` for sampling (opening the menu is a fallback resample). Opens each doc in its
    /// owning app. Adds nothing when there's no readable data.
    static func appendRecentDocuments(to menu: NSMenu, bundleID: String?) {
        guard let bid = bundleID else { return }
        let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid)
        let recentPaths = RecentDocumentsReader.recentDocuments(for: bid, maxCount: 20).map(\.path)
        // The menu is only built on the main thread (NSMenu can only be used on the main thread anyway), but this type is non-isolated,
        // and the compiler can't see that -- assumeIsolated turns that fact into a runtime assertion.
        let ranked = MainActor.assumeIsolated { () -> [String] in
            let usage = DocumentUsageStore.shared
            usage.noteRecentSample(bundleID: bid, topPath: recentPaths.first)
            return usage.ranked(bundleID: bid, recentPaths: recentPaths)
        }
        let entries = ranked.map { path in
            RecentMenuEntry(title: (path as NSString).lastPathComponent, url: URL(fileURLWithPath: path))
        }
        appendRecentItems(to: menu, title: String(localized: "Most Used Files"), entries: entries) { url in
            MainActor.assumeIsolated {
                DocumentUsageStore.shared.recordOpen(bundleID: bid, path: url.path)
            }
            openRecent(url, appURL: appURL)
        }
    }

    /// Top recent-folders section for the Finder chip, inline. Opens each folder in Finder.
    static func appendFinderRecentFolders(to menu: NSMenu) {
        appendRecentItems(to: menu, title: String(localized: "Recent Folders"),
                          entries: RecentDocumentsReader.recentFinderFolders()) { NSWorkspace.shared.open($0) }
    }

    /// Shared builder: a grayed section header + the file/folder rows (16pt icon) added
    /// inline to `menu` (no submenu), then a separator.
    private static func appendRecentItems(to menu: NSMenu, title: String,
                                          entries: [RecentMenuEntry], open: @escaping (URL) -> Void) {
        guard !entries.isEmpty else { return }
        // Grayed, non-clickable section header (action == nil auto-disables it; macOS 12
        // compatible — not the macOS 14 NSMenuItem.sectionHeader).
        let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for entry in entries {
            let it = ClosureMenuItem(entry.title) { open(entry.url) }
            // copy() before resizing: icon(forFile:) returns a shared cached NSImage;
            // mutating its size in place would shrink it everywhere else too.
            let icon = NSWorkspace.shared.icon(forFile: entry.url.path).copy() as? NSImage
            icon?.size = NSSize(width: 16, height: 16)
            it.image = icon
            menu.addItem(it)
        }
        menu.addItem(.separator())
    }

    /// Open a recent doc in its owning app (matches the native Dock); fall back to
    /// the default app if the owner can't be resolved or refuses to open it.
    private static func openRecent(_ url: URL, appURL: URL?) {
        guard let appURL else { NSWorkspace.shared.open(url); return }
        NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: .init()) { _, error in
            if error != nil { DispatchQueue.main.async { NSWorkspace.shared.open(url) } }
        }
    }

    /// Finder-only shortcuts at the top of the Finder chip menu, plus a separator.
    static func appendFinderItems(to menu: NSMenu) {
        menu.addItem(ClosureMenuItem(String(localized: "Go to Folder…")) { triggerFinderShortcut(goToFolder: true) })
        menu.addItem(ClosureMenuItem(String(localized: "Connect to Server…")) { triggerFinderShortcut(goToFolder: false) })
        menu.addItem(.separator())
    }

    // Key codes from HIToolbox/Events.h — defined locally to avoid a Carbon dependency
    private static let keyG: CGKeyCode = 0x05  // kVK_ANSI_G
    private static let keyK: CGKeyCode = 0x28  // kVK_ANSI_K

    private static func triggerFinderShortcut(goToFolder: Bool) {
        guard let finder = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.finder").first else { return }
        finder.activate(options: .activateIgnoringOtherApps)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            let src = CGEventSource(stateID: .combinedSessionState)
            let keyCode = goToFolder ? keyG : keyK
            let flags: CGEventFlags = goToFolder ? [.maskCommand, .maskShift] : [.maskCommand]
            for keyDown in [true, false] {
                let e = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: keyDown)
                e?.flags = flags
                e?.postToPid(finder.processIdentifier)
            }
        }
    }
}
