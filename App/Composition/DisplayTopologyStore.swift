import Combine

/// The single source for the connected-display table (display UUID + Quartz frame + primary).
/// The taskbar projection (mode ④'s per-display filter) and the window inventory (`AppTracker`'s
/// attribution key) read this same table, so the two can never disagree about which display a
/// window is on. `TaskbarScreenOrchestrator` is the sole sampler of the screen-parameters
/// notification and pushes one shared snapshot in here; this type never re-reads the screens.
@MainActor
final class DisplayTopologyStore: ObservableObject {
    @Published private(set) var table: WindowDisplayAttribution.Table
    private(set) var latestSnapshot: ScreenTopologySnapshot

    init(initialSnapshot snapshot: ScreenTopologySnapshot) {
        latestSnapshot = snapshot
        table = snapshot.attributionTable
    }

    func apply(_ snapshot: ScreenTopologySnapshot) {
        latestSnapshot = snapshot
        if snapshot.attributionTable != table {
            table = snapshot.attributionTable
        }
    }
}
