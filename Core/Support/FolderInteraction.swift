import Foundation

/// A switchable policy for the pinned folder's "primary left-click behavior".
///
/// Reserved for A/B: if we later switch between "left-click preview vs left-click opens a Finder window", only change here (or wire `primaryAction`
/// to return per the user's choice in settings), and **all left-click call sites uniformly go through `DockStripView.folderPrimaryTap`**,
/// rather than hardcoding behavior in various places, to avoid scattering.
enum FolderPrimaryAction {
    /// Left-click = open a Finder window at that path.
    case openFinderWindow
    /// Left-click = open the content preview popup.
    case preview
}

enum FolderInteraction {
    /// Currently the pinned folder's left-click = content preview (2026-07-09: left-click wants the "click to open, click to close" toggle feel;
    /// opening a real Finder window moves to the right-click "Open in Finder"). For the A/B, change just this one place.
    static var primaryAction: FolderPrimaryAction { .preview }
}
