import AppKit
import Foundation

/// Selects the concrete app bundle that should receive a launch request.
/// Bundle discovery and Info.plist reads remain at the composition boundary.
enum AppLaunchTargetDecision {
    struct Candidate: Equatable {
        let url: URL
        let isNested: Bool
        let declaresNoWindow: Bool

        init(url: URL, declaresNoWindow: Bool) {
            self.url = url
            self.isNested = AppLaunchTargetDecision.hasApplicationAncestor(of: url)
            self.declaresNoWindow = declaresNoWindow
        }

        var isEligibleMainApplication: Bool {
            !isNested && !declaresNoWindow
        }
    }

    static func select(
        launchServicesCandidates: [Candidate],
        preferred: Candidate?
    ) -> Candidate? {
        let candidates = orderedUniqueCandidates(
            launchServicesCandidates: launchServicesCandidates,
            preferred: preferred
        )

        if let preferred, preferred.isEligibleMainApplication {
            return preferred
        }
        if let mainApplication = candidates.first(where: \.isEligibleMainApplication) {
            return mainApplication
        }
        return preferred ?? candidates.first
    }

    static func orderedUniqueCandidates(
        launchServicesCandidates: [Candidate],
        preferred: Candidate?
    ) -> [Candidate] {
        var canonicalPaths = Set<String>()
        return (launchServicesCandidates + [preferred].compactMap { $0 }).filter { candidate in
            canonicalPaths.insert(canonicalPath(candidate.url)).inserted
        }
    }

    static func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
    }

    static func canonicalPath(_ url: URL) -> String {
        canonicalURL(url).path
    }

    private static func hasApplicationAncestor(of url: URL) -> Bool {
        canonicalURL(url).deletingLastPathComponent().pathComponents.contains { component in
            (component as NSString).pathExtension.caseInsensitiveCompare("app") == .orderedSame
        }
    }
}

enum AppLaunchOpenConfiguration {
    static func make() -> NSWorkspace.OpenConfiguration {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = false
        configuration.allowsRunningApplicationSubstitution = false
        return configuration
    }
}
