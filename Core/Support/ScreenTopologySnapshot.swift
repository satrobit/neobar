import Foundation

/// One ordered reading of the connected displays. Every consumer in a topology
/// transition uses this value so a transient UUID failure cannot split decisions.
struct ScreenTopologySnapshot: Equatable {
    let physicalDisplayCount: Int
    let identifiedDisplayUUIDs: [String]
    let attributionTable: WindowDisplayAttribution.Table
}
