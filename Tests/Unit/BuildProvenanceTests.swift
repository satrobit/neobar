import XCTest
@testable import NeoBar

final class BuildProvenanceTests: XCTestCase {
    func testInstalledReleaseBuildGetsNoSuffix() {
        XCTAssertNil(BuildProvenance.suffix(
            isDebugBuild: false,
            bundlePath: "/Applications/NeoBar.app"
        ))
    }

    func testDebugBuildIsMarkedRegardlessOfLocation() {
        // The incident scene: the login item was pinned to DerivedData, and this package is what came up at boot.
        XCTAssertEqual(BuildProvenance.suffix(
            isDebugBuild: true,
            bundlePath: "/Users/dev/Projects/NeoBar/build/DerivedData/Build/Products/Debug/NeoBar.app"
        ), String(localized: "Debug Build"))
        // A dev build is still a dev build even when copied into /Applications: the Debug check takes priority over the location check.
        XCTAssertEqual(BuildProvenance.suffix(
            isDebugBuild: true,
            bundlePath: "/Applications/NeoBar.app"
        ), String(localized: "Debug Build"))
    }

    func testReleaseBuildOutsideApplicationsIsMarked() {
        XCTAssertEqual(BuildProvenance.suffix(
            isDebugBuild: false,
            bundlePath: "/Users/dev/Projects/NeoBar/build/ReleaseDD/Build/Products/Release/NeoBar.app"
        ), String(localized: "Not Installed"))
        // A rollback backup package is also outside /Applications, and must likewise be recognized.
        XCTAssertEqual(BuildProvenance.suffix(
            isDebugBuild: false,
            bundlePath: "/Users/dev/Projects/neobar-rebuild-artifacts/2026-07-25-stage4/rollback/NeoBar.app"
        ), String(localized: "Not Installed"))
    }

    func testInstalledPrefixRequiresTrailingSlashSoLookalikePathsAreNotInstalled() {
        // Without the trailing slash, this path would be misjudged as an installed location.
        XCTAssertEqual(BuildProvenance.suffix(
            isDebugBuild: false,
            bundlePath: "/ApplicationsOld/NeoBar.app"
        ), String(localized: "Not Installed"))
    }

    func testVersionTitleAppendsSuffixWithSeparator() {
        XCTAssertEqual(BuildProvenance.versionTitle(
            version: "0.7.0",
            build: "8",
            isDebugBuild: true,
            bundlePath: "/anywhere/NeoBar.app"
        ), String(format: String(localized: "Version %@ (%@)"), "0.7.0", "8") + " · " + String(localized: "Debug Build"))

        XCTAssertEqual(BuildProvenance.versionTitle(
            version: "0.7.0",
            build: "8",
            isDebugBuild: false,
            bundlePath: "/Applications/NeoBar.app"
        ), String(format: String(localized: "Version %@ (%@)"), "0.7.0", "8"))
    }

    func testVersionTitleDegradesExactlyLikeTheOldImplementation() {
        let installed = "/Applications/NeoBar.app"
        XCTAssertEqual(BuildProvenance.versionTitle(
            version: "0.7.0", build: nil, isDebugBuild: false, bundlePath: installed
        ), String(format: String(localized: "Version %@"), "0.7.0"))
        XCTAssertEqual(BuildProvenance.versionTitle(
            version: nil, build: "8", isDebugBuild: false, bundlePath: installed
        ), String(format: String(localized: "Version (%@)"), "8"))
        XCTAssertNil(BuildProvenance.versionTitle(
            version: nil, build: nil, isDebugBuild: false, bundlePath: installed
        ))
    }

    func testSuffixStillAppendsWhenOnlyOneOfVersionOrBuildIsPresent() {
        XCTAssertEqual(BuildProvenance.versionTitle(
            version: "0.7.0", build: nil, isDebugBuild: true, bundlePath: "/tmp/x.app"
        ), String(format: String(localized: "Version %@"), "0.7.0") + " · " + String(localized: "Debug Build"))
        // When both are missing the whole row isn't shown, and the suffix shouldn't conjure up a line out of thin air either.
        XCTAssertNil(BuildProvenance.versionTitle(
            version: nil, build: nil, isDebugBuild: true, bundlePath: "/tmp/x.app"
        ))
    }
}
