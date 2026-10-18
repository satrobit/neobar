import Foundation
import os

@MainActor
final class DrawerStore: ObservableObject {
    @Published private(set) var bundleIDs: [String] = []
    private let key = "drawerBundleIDs"
    private static let legacyFavoriteKey = "launchFavoriteBundleIDs"
    private let defaults: UserDefaults
    private let logger = Logger(subsystem: "app.neobar.NeoBar", category: "drawer-store")

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var ids = defaults.stringArray(forKey: key) ?? []

        // Migration: after merging the old launchFavoriteBundleIDs, delete the old key (also when it is an empty array, leaving no stale key)
        if let favorites = defaults.stringArray(forKey: Self.legacyFavoriteKey) {
            defaults.removeObject(forKey: Self.legacyFavoriteKey)
            for fav in favorites where !fav.isEmpty && !ids.contains(fav) {
                ids.append(fav)
            }
            if !favorites.isEmpty {
                logger.info("merged \(favorites.count) entries from launchFavoriteBundleIDs into drawerBundleIDs")
            }
        }

        bundleIDs = ids
        if let stored = defaults.stringArray(forKey: key), stored != ids {
            persist()
        } else if defaults.stringArray(forKey: key) == nil && !ids.isEmpty {
            persist()
        }
    }

    func contains(_ id: String) -> Bool { bundleIDs.contains(id) }

    func add(_ id: String) {
        guard !id.isEmpty, !bundleIDs.contains(id) else { return }
        bundleIDs.append(id)
        persist()
    }

    func remove(_ id: String) {
        bundleIDs.removeAll { $0 == id }
        persist()
    }

    private func persist() {
        defaults.set(bundleIDs, forKey: key)
    }
}
