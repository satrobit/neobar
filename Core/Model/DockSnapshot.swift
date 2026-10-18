import Foundation

/// The window-inventory snapshot the taskbar reads: published by `AppTracker`, consumed by `AppRuntime`, the whole app's window ground truth.
/// Split out of `DockState.swift` on 2026-09-05; the other half of that file (the `DockState` container) was used only by the old observation pipeline of the diagnostic tool
/// window-lab, and has moved with that pipeline to `Tools/WindowLab/Pipeline/`.
struct DockSnapshot: Equatable, Sendable {
    var windows: [WindowID: WindowRecord]
    var orderedWindowIDs: [WindowID]

    static let empty = DockSnapshot(windows: [:], orderedWindowIDs: [])
}
