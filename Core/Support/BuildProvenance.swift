import Foundation

/// The "where did this package come from" marker on the menu's version line.
///
/// It exists because of a real incident: the login item was pinned by `SMAppService.mainApp.register()` to
/// `build/DerivedData/.../Debug/` (it registers the bundle that is running at the time), so what started automatically at boot
/// was always the development build rather than the release package in `/Applications`. After release the mainline version number
/// wasn't bumped either, so the two looked identical on the menu, and "the minimize feel is off" was misjudged as a version regression,
/// and "two task strips on screen" was misjudged as the fix not working. Writing the origin straight into the version line makes them distinguishable by eye.
enum BuildProvenance {
    /// The official install location. The trailing `/` can't be omitted -- otherwise paths like `/ApplicationsOld/Foo.app`
    /// would be misjudged as installed by `hasPrefix`.
    static let installedPrefix = "/Applications/"

    /// Version line suffix; `nil` = a Release package at the official install location, no marker added.
    ///
    /// Debug takes priority over the location check: a development build is still a development build even if copied into `/Applications`,
    /// and its feel differs from the release package (Debug has no compiler optimization), which matters more than where it is.
    static func suffix(isDebugBuild: Bool, bundlePath: String) -> String? {
        if isDebugBuild { return String(localized: "Debug Build") }
        return bundlePath.hasPrefix(installedPrefix) ? nil : String(localized: "Not Installed")
    }

    /// The assembled full version line. The fallback text when either version / build is missing matches the old implementation before the marker was added.
    static func versionTitle(
        version: String?,
        build: String?,
        isDebugBuild: Bool,
        bundlePath: String
    ) -> String? {
        let base: String
        switch (version, build) {
        case let (version?, build?): base = String(format: String(localized: "Version %@ (%@)"), version, build)
        case let (version?, nil): base = String(format: String(localized: "Version %@"), version)
        case let (nil, build?): base = String(format: String(localized: "Version (%@)"), build)
        case (nil, nil): return nil
        }
        guard let suffix = suffix(isDebugBuild: isDebugBuild, bundlePath: bundlePath) else {
            return base
        }
        return "\(base) · \(suffix)"
    }
}
