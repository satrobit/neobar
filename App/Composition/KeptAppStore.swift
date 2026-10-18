import Foundation
import os

/// The list of apps with "Keep in Dock". While running they show window cards as usual; after quitting they collapse into one app icon left in place.
///
/// Since 2026-08-20 Finder is also managed by this store (`FinderTaskbarPolicy`), ticked by default and can be unticked.
/// Ordering is managed uniformly by `StripOrderStore`; this store handles only membership and persistence.
@MainActor
final class KeptAppStore: ObservableObject {
    /// V3 lets a messaging app also be kept (kept alone now decides post-exit
    /// visibility). Key existence is the migration marker, including an explicitly
    /// persisted empty array on a fresh install. Older kept keys stay frozen
    /// read-only so a code rollback still reads the exact pre-upgrade list.
    static let defaultsKey = "keptAppBundleIDsV3"
    static let previousDefaultsKey = "keptAppBundleIDsV2"
    /// One-time seeding marker for Finder. **Cannot reuse the V3 key** -- the existence of the V3 key is itself the migration marker,
    /// and existing users' V3 was written long ago, so only a separate key can express "has the one-time Finder top-up tick been done".
    static let finderSeedKey = "keptAppFinderSeededV1"
    private static let v1Key = "keptAppBundleIDs"
    private static let legacyKey = "pinnedAppBundleIDs"
    private static let drawerKey = "drawerBundleIDs"
    private static let messagingV2Key = "messagingBundleIDsV2"
    private static let messagingV1Key = "messagingBundleIDs"

    @Published private(set) var bundleIDs: [String]

    private let defaults: UserDefaults
    private let logger = Logger(subsystem: "app.neobar.NeoBar", category: "kept-app-store")

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // Already on V3.
        if defaults.object(forKey: Self.defaultsKey) != nil {
            let stored = defaults.stringArray(forKey: Self.defaultsKey) ?? []
            bundleIDs = Self.cleaned(stored)
            if bundleIDs != stored { persist() }
            seedFinderOnce()
            return
        }

        // First migration to V3. Messaging apps now join kept so they stay visible
        // after exit under the unified model. Frozen legacy keys (V2 / V1 / pinned)
        // are left untouched for a clean code rollback.
        let messaging = Self.authoritativeMessagingNames(defaults)
        let seed: [String]
        if defaults.object(forKey: Self.previousDefaultsKey) != nil {
            // Kept V2 exists: keep its order first, messaging appended.
            let v2 = defaults.stringArray(forKey: Self.previousDefaultsKey) ?? []
            seed = v2 + messaging
        } else {
            // No kept V2 (upgrading straight past it): fold V1 + pinned + drawer + messaging.
            let v1 = defaults.stringArray(forKey: Self.v1Key) ?? []
            let legacy = defaults.stringArray(forKey: Self.legacyKey) ?? []
            let drawer = defaults.stringArray(forKey: Self.drawerKey) ?? []
            seed = v1 + legacy + drawer + messaging
        }
        bundleIDs = Self.cleaned(seed)
        persist() // Empty is intentional: V3 key existence is the migration marker.
        seedFinderOnce()
        logger.info("initialized keptAppBundleIDsV3 with \(self.bundleIDs.count) entries")
    }

    /// Finder is ticked by default, topped up only once (owner 2026-08-20). For existing users the look is unchanged after upgrade;
    /// if the user later unticks it themselves, the marker is already true, so it won't be re-enabled on the next launch.
    /// Appended at the **tail**: neither the existing kept order nor `StripOrderStore`'s cross-machine-restart ranking is disturbed.
    private func seedFinderOnce() {
        guard !defaults.bool(forKey: Self.finderSeedKey) else { return }
        defaults.set(true, forKey: Self.finderSeedKey)
        guard !contains(FinderTaskbarPolicy.bundleID) else { return }
        add(FinderTaskbarPolicy.bundleID)
        logger.info("seeded Finder into keptAppBundleIDsV3 (one-shot)")
    }

    /// The native Dock's all-apps entry on macOS 26+ (Apps, a Spotlight panel). Launchpad
    /// (macOS 12-15, `com.apple.launchpad.launcher`) is deliberately not seeded: it is a
    /// full-screen page that covers the taskbar and brings the native Dock back, and its icons
    /// cannot be dragged onto the taskbar — do not add it back as a fallback.
    static let systemAppLauncherBundleID = "com.apple.apps.launcher"

    /// A fresh install keeps the system's all-apps entry right after Finder, as the native Dock
    /// does. Fresh is decided by `InstallLineage` only (AGENTS.md): upgraders never get it, so
    /// unlike Finder there is no seed marker — an un-check is simply never undone.
    func seedSystemAppLauncherForFreshInstall(lineage: InstallLineage, isInstalled: (String) -> Bool) {
        guard lineage == .pristine, isInstalled(Self.systemAppLauncherBundleID) else { return }
        add(Self.systemAppLauncherBundleID)
        logger.info("seeded \(Self.systemAppLauncherBundleID, privacy: .public) into keptAppBundleIDsV3 (fresh install)")
    }

    /// Authoritative messaging names for the kept-V3 seed, independent of store
    /// init order: if the messaging V2 key exists (even an explicit empty array)
    /// read only it; otherwise fall back to the legacy messaging key. Never union.
    private static func authoritativeMessagingNames(_ defaults: UserDefaults) -> [String] {
        if defaults.object(forKey: messagingV2Key) != nil {
            return defaults.stringArray(forKey: messagingV2Key) ?? []
        }
        return defaults.stringArray(forKey: messagingV1Key) ?? []
    }

    /// Only a non-empty check remains: since 2026-08-20 Finder is also allowed as kept, so there is no exception list here any more.
    static func canKeep(_ bundleID: String) -> Bool {
        normalized(bundleID) != nil
    }

    func canKeep(_ bundleID: String) -> Bool {
        Self.canKeep(bundleID)
    }

    func contains(_ bundleID: String) -> Bool {
        guard let normalized = Self.normalized(bundleID) else { return false }
        return bundleIDs.contains(normalized)
    }

    func add(_ bundleID: String) {
        guard Self.canKeep(bundleID),
              let normalized = Self.normalized(bundleID),
              !bundleIDs.contains(normalized) else { return }
        bundleIDs.append(normalized)
        persist()
    }

    func remove(_ bundleID: String) {
        guard let normalized = Self.normalized(bundleID) else { return }
        let previousCount = bundleIDs.count
        bundleIDs.removeAll { $0 == normalized }
        if bundleIDs.count != previousCount {
            persist()
        }
    }

    private static func cleaned(_ bundleIDs: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for bundleID in bundleIDs {
            guard canKeep(bundleID),
                  let normalized = normalized(bundleID),
                  seen.insert(normalized).inserted else { continue }
            result.append(normalized)
        }
        return result
    }

    private static func normalized(_ bundleID: String) -> String? {
        let normalized = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private func persist() {
        defaults.set(bundleIDs, forKey: Self.defaultsKey)
    }
}
