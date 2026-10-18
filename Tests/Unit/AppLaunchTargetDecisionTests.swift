import AppKit
import Foundation
import XCTest

final class AppLaunchTargetDecisionTests: XCTestCase {
    private func candidate(_ path: String, declaresNoWindow: Bool = false) -> AppLaunchTargetDecision.Candidate {
        AppLaunchTargetDecision.Candidate(
            url: URL(fileURLWithPath: path),
            declaresNoWindow: declaresNoWindow
        )
    }

    func testSelectsOuterMainApplicationFromVideoFusionCandidateShape() {
        let outer = candidate("/Applications/VideoFusion-macOS.app")
        let nestedMain = candidate(
            "/Applications/VideoFusion-macOS.app/Contents/Frameworks/VideoFusion-macOS.app",
            declaresNoWindow: true
        )
        let trayHelper = candidate(
            "/Applications/VideoFusion-macOS.app/Contents/Frameworks/VideoFusion-macOSTrayHelper.app",
            declaresNoWindow: true
        )

        XCTAssertEqual(
            AppLaunchTargetDecision.select(
                launchServicesCandidates: [outer, nestedMain, trayHelper],
                preferred: outer
            ),
            outer
        )
    }

    func testNestedPreferredStillSelectsOuterMainApplication() {
        let outer = candidate("/Applications/Example.app")
        let nested = candidate("/Applications/Example.app/Contents/Frameworks/Example.app")

        XCTAssertEqual(
            AppLaunchTargetDecision.select(
                launchServicesCandidates: [nested, outer],
                preferred: nested
            ),
            outer
        )
    }

    func testEligiblePreferredWinsAmongMultipleTopLevelApplications() {
        let first = candidate("/Applications/Example.app")
        let preferred = candidate("/Applications/Example Beta.app")

        XCTAssertEqual(
            AppLaunchTargetDecision.select(
                launchServicesCandidates: [first, preferred],
                preferred: preferred
            ),
            preferred
        )
    }

    func testOnlyHelpersFallBackToPreferredThenFirstCandidate() {
        let first = candidate("/Applications/First Helper.app", declaresNoWindow: true)
        let preferred = candidate("/Applications/Preferred Helper.app", declaresNoWindow: true)

        XCTAssertEqual(
            AppLaunchTargetDecision.select(
                launchServicesCandidates: [first, preferred],
                preferred: preferred
            ),
            preferred
        )
        XCTAssertEqual(
            AppLaunchTargetDecision.select(
                launchServicesCandidates: [first],
                preferred: nil
            ),
            first
        )
        XCTAssertNil(
            AppLaunchTargetDecision.select(
                launchServicesCandidates: [],
                preferred: nil
            )
        )
    }

    func testCanonicalSymlinkPathsAreDeduplicated() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let application = root.appendingPathComponent("Example.app", isDirectory: true)
        let alias = root.appendingPathComponent("Example Alias.app")
        try FileManager.default.createDirectory(at: application, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: alias.path,
            withDestinationPath: application.path
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let candidates = AppLaunchTargetDecision.orderedUniqueCandidates(
            launchServicesCandidates: [
                AppLaunchTargetDecision.Candidate(url: alias, declaresNoWindow: false),
                AppLaunchTargetDecision.Candidate(url: application, declaresNoWindow: false)
            ],
            preferred: nil
        )

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(
            AppLaunchTargetDecision.canonicalPath(alias),
            AppLaunchTargetDecision.canonicalPath(application)
        )
    }

    func testOpenConfigurationDisablesNewInstanceAndRunningSubstitution() {
        let configuration = AppLaunchOpenConfiguration.make()

        XCTAssertFalse(configuration.createsNewApplicationInstance)
        XCTAssertFalse(configuration.allowsRunningApplicationSubstitution)
    }
}
