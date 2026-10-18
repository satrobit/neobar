import AppKit
import SwiftUI

/// `DOCK_STACK_POPUP_SNAPSHOT=<folder>`: draws that folder's popup content — the real
/// `FolderGridPopupView`, sorted by name as the native Dock sorts — in a window parked far
/// off-screen and writes it to `<tmp>/neobar-stack-popup.png`, so titles, icons, thumbnails and
/// names can be diffed against a native capture without anyone clicking. `shelf` and `trash`
/// instead of a path draw those two popups. The plate is not in the
/// picture (glass and frosted backdrops only exist composited on screen); neither is anything
/// blended against it.
@MainActor
enum StackPopupSnapshotProbe {
    private static var window: NSWindow?

    static func runIfRequested() {
        guard let folder = DebugSwitch.stackPopupSnapshot.value(), !folder.isEmpty else { return }
        if folder.hasPrefix("fan:") {
            runFan(path: String(folder.dropFirst(4)))
            return
        }
        let url = URL(fileURLWithPath: folder)
        let isFolder = folder != "shelf" && folder != "trash"
        let entries = isFolder
            ? FolderContentsLoader.sorted((try? FolderContentsLoader.load(directory: url)) ?? [], by: .name)
            : []
        FolderIconResolver.warm(paths: entries.map(\.url.path), timeout: 2)
        let screen = NSScreen.main?.frame.size ?? CGSize(width: 1352, height: 878)
        let context = StackPopupContext(
            limits: StackGridLayout.limits(screenSize: screen, availablePlateHeight: screen.height - 110),
            arrow: StackPopupArrowModel())
        var failures: [String] = []
        let lock = NSLock()
        FolderIconResolver.onThumbnailFailure = { line in lock.lock(); failures.append(line); lock.unlock() }
        let content: AnyView
        switch folder {
        case "shelf":
            content = AnyView(ShelfGridPopupView(shelfStore: ShelfStore(), context: context, usesLiquidGlass: false))
        case "trash":
            content = AnyView(TrashGridPopupView(trashStore: .shared, context: context, usesLiquidGlass: false))
        default:
            content = AnyView(FolderGridPopupView(rootURL: url, initialEntries: entries, sortOrder: .name,
                                                  context: context, usesLiquidGlass: false))
        }
        let hosting = NSHostingView(rootView: content)
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: size.width, height: size.height),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = hosting
        window.orderFrontRegardless()
        Self.window = window
        // Thumbnails arrive asynchronously; give them time before drawing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            let output = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("neobar-stack-popup.png")
            if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                hosting.cacheDisplay(in: hosting.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: output)
            }
            lock.lock()
            let report = (["\(entries.count) entries, window \(size.width)x\(size.height), scale \(hosting.window?.backingScaleFactor ?? 0)"] + failures)
                .joined(separator: "\n")
            lock.unlock()
            try? report.write(to: output.deletingPathExtension().appendingPathExtension("txt"), atomically: true, encoding: .utf8)
            FolderIconResolver.onThumbnailFailure = nil
            window.orderOut(nil)
            Self.window = nil
        }
    }

    /// `fan:<folder>`: the fan's landed state for that folder, sorted by name, its tile centre
    /// 100pt in from the picture's right and bottom (`StackFanLayout` puts items right of it).
    /// The capsules' glass is not in the picture; their text and every icon are.
    private static func runFan(path: String) {
        let url = URL(fileURLWithPath: path)
        let entries = FolderContentsLoader.sorted((try? FolderContentsLoader.load(directory: url)) ?? [], by: .name)
        FolderIconResolver.warm(paths: entries.map(\.url.path), timeout: 2)
        let shown = Array(entries.prefix(10))
        var items = shown.map { StackFanItem(kind: .entry($0), title: $0.name) }
        items.append(StackFanItem(kind: .openInFinder, title: String(localized: "Open in Finder")))
        let font = NSFont.systemFont(ofSize: StackFanLayout.labelFontSize)
        let labelSizes = items.map {
            StackFanLayout.labelSize(textSize: ($0.title as NSString).size(withAttributes: [.font: font]))
        }
        // Tile centre at (0, 0); the picture is the fan's box.
        let layout = StackFanLayout(tileCenter: .zero, squareSide: ChipPillMetrics.bareIconVisibleSlot,
                                    labelSizes: labelSizes)
        let box = layout.boundingBox.union(CGRect(x: -20, y: -20, width: 40, height: 40)).insetBy(dx: -4, dy: -4).integral
        let fan = StackPopupFanView(items: items, layout: layout,
                                    pileRects: items.map { _ in CGRect(x: -16, y: -16, width: 32, height: 32) },
                                    windowFrame: box,
                                    actions: .init(activate: { _ in }, dismiss: {}, menu: { _ in nil }))
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: box.width, height: box.height),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = fan
        fan.windowWillTake(box)
        window.orderFrontRegardless()
        Self.window = window
        fan.loadThumbnails(scale: window.backingScaleFactor)
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            let output = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("neobar-stack-popup.png")
            if let rep = fan.bitmapImageRepForCachingDisplay(in: fan.bounds) {
                fan.cacheDisplay(in: fan.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: output)
            }
            let report = "fan \(items.count) items, box \(box), tile centre at (\(-box.minX), \(-box.minY)) from the bottom-left\n"
                + layout.items.enumerated().map { "item \($0.offset) centre \($0.element.center) angle \($0.element.rotation * 180 / .pi)" }
                    .joined(separator: "\n")
            try? report.write(to: output.deletingPathExtension().appendingPathExtension("txt"), atomically: true, encoding: .utf8)
            window.orderOut(nil)
            Self.window = nil
        }
    }
}
