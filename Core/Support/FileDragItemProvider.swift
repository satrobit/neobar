import Foundation

/// The item provider a folder / shelf popup cell hands to a real file drag.
///
/// Registers the file URL only — the shape a Finder drag has — so the receiver works on the file
/// itself. Never `NSItemProvider(contentsOf:)`: it registers the content type first
/// (`public.zip-archive`, `public.plain-text`, …) with no name, and Finder / mail clients take that
/// data copy and name it after the type ("Zip Archive.zip").
///
/// Never set `suggestedName` either: SwiftUI then copies the file into
/// `~/Library/Caches/com.apple.SwiftUI.Drag-<UUID>/` and puts **the copy's** URL on the drag
/// pasteboard, so every receiver — the Trash chip, a pinned folder, the shelf, Finder — acts on
/// the copy and the user's file stays where it was.
enum FileDragItemProvider {
    static func make(for url: URL) -> NSItemProvider {
        NSItemProvider(object: url as NSURL)
    }
}
