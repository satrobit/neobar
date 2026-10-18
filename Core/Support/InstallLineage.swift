import Foundation

/// Whether this process started with an untouched application preference domain.
/// The caller must capture this before constructing any store that writes defaults.
enum InstallLineage: Equatable {
    case pristine
    case priorUse

    static func classify(persistentDomain: [String: Any]?) -> InstallLineage {
        persistentDomain?.isEmpty ?? true ? .pristine : .priorUse
    }

    static func capture(
        defaults: UserDefaults = .standard,
        bundleID: String? = Bundle.main.bundleIdentifier
    ) -> InstallLineage {
        guard let bundleID, !bundleID.isEmpty else { return .priorUse }
        return classify(persistentDomain: defaults.persistentDomain(forName: bundleID))
    }
}
