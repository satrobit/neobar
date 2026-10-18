import CoreGraphics
import Foundation
import OSLog

/// AppleEvents target of a Finder window (title + screen frame), used for unique matching.
struct FinderWindowAppleEventsTarget: Sendable {
    let title: String
    let cocoaFrame: CGRect
}

/// One Finder window enumerated by AppleScript (name + frame + target path).
struct AEFinderWindow {
    let name: String
    let cocoaFrame: CGRect
    let url: URL
}

/// Result of parsing AppleScript output (including a count and a first-error summary for logging).
struct AEFinderWindowParseResult {
    let windows: [AEFinderWindow]
    let rawLineCount: Int
    let validURLCount: Int
    let firstErrorSummary: String?
}

/// The **pure-logic** layer for reverse-looking-up a Finder window's path: AppleScript script text, output parsing, and unique matching by "title + position".
/// Extracted from `FinderWindowContentsReader`'s AX / AppleEvent I/O so that it is **purely unit-testable** and does not drag the AX
/// dependency into the test target. Behavior was verified on real hardware by spike#2; unit tests lock it against regressions.
enum FinderAppleEventMatcher {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.neobar.NeoBar",
        category: "FinderContents"
    )

    static func appleEventWindowListingScript() -> String {
        """
        tell application "Finder"
          with timeout of 2 seconds
            set out to ""
            set finderWindows to (get Finder windows)
            repeat with w in finderWindows
              set rowName to ""
              set leftValue to ""
              set topValue to ""
              set rightValue to ""
              set bottomValue to ""
              set targetValue to ""
              set fieldErrors to ""

              try
                set rowName to (name of w as text)
              on error errMsg number errNum
                set fieldErrors to fieldErrors & "name:" & (errNum as text) & ";"
              end try

              try
                set b to bounds of w
                set leftValue to (item 1 of b as text)
                set topValue to (item 2 of b as text)
                set rightValue to (item 3 of b as text)
                set bottomValue to (item 4 of b as text)
              on error errMsg number errNum
                set fieldErrors to fieldErrors & "bounds:" & (errNum as text) & ";"
              end try

              try
                set t to target of w
                try
                  set targetValue to ((URL of t) as text)
                on error urlErrMsg number urlErrNum
                  try
                    set targetValue to POSIX path of (t as alias)
                  on error pathErrMsg number pathErrNum
                    set fieldErrors to fieldErrors & "url:" & (urlErrNum as text) & ";path:" & (pathErrNum as text) & ";"
                  end try
                end try
              on error errMsg number errNum
                set fieldErrors to fieldErrors & "target:" & (errNum as text) & ";"
              end try

              set out to out & rowName & tab & leftValue & tab & topValue & tab & rightValue & tab & bottomValue & tab & targetValue & tab & fieldErrors & linefeed
            end repeat
            return out
          end timeout
        end tell
        """
    }

    static func parseAppleEventWindowOutput(_ output: String) -> AEFinderWindowParseResult {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: true)
        var windows: [AEFinderWindow] = []
        var validURLCount = 0
        var firstErrorSummary: String?

        for line in lines {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 7 else {
                firstErrorSummary = firstErrorSummary ?? "bad-field-count"
                continue
            }

            let fieldErrors = parts[6]
            if !fieldErrors.isEmpty {
                firstErrorSummary = firstErrorSummary ?? fieldErrors
            }

            guard let left = Double(parts[1]),
                  let top = Double(parts[2]),
                  let right = Double(parts[3]),
                  let bottom = Double(parts[4]) else {
                firstErrorSummary = firstErrorSummary ?? "bad-bounds"
                continue
            }

            guard let url = fileURL(fromAppleEventValue: parts[5]) else {
                firstErrorSummary = firstErrorSummary ?? "invalid-target-url"
                continue
            }
            guard validDirectoryURL(url) != nil else {
                firstErrorSummary = firstErrorSummary ?? "unsupported-target-url"
                continue
            }
            validURLCount += 1

            windows.append(
                AEFinderWindow(
                    name: parts[0],
                    cocoaFrame: comparableFrameFromFinderBounds(
                        left: CGFloat(left),
                        top: CGFloat(top),
                        right: CGFloat(right),
                        bottom: CGFloat(bottom)
                    ),
                    url: url
                )
            )
        }

        return AEFinderWindowParseResult(
            windows: windows,
            rawLineCount: lines.count,
            validURLCount: validURLCount,
            firstErrorSummary: firstErrorSummary
        )
    }

    static func matchAppleEventWindow(target: FinderWindowAppleEventsTarget, candidates: [AEFinderWindow], requestID: String = "test") -> AEFinderWindow? {
        let matches = candidates.filter { candidate in
            candidate.name == target.title &&
            framesMatch(target.cocoaFrame, candidate.cocoaFrame, tolerance: 8)
        }
        logger.info("ae-match request=\(requestID, privacy: .public) candidateCount=\(candidates.count, privacy: .public) matchCount=\(matches.count, privacy: .public) title=\(target.title, privacy: .public)")
        return matches.count == 1 ? matches[0] : nil
    }

    static func fileURL(fromAppleEventValue rawValue: String) -> URL? {
        guard rawValue.isEmpty == false else { return nil }
        if rawValue.hasPrefix("file://") {
            return URL(string: rawValue)
        }
        if rawValue.hasPrefix("/") {
            return URL(fileURLWithPath: rawValue)
        }
        return nil
    }

    static func validDirectoryURL(_ url: URL) -> URL? {
        guard url.isFileURL else { return nil }
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
        return url
    }

    private static func framesMatch(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat) -> Bool {
        abs(lhs.minX - rhs.minX) <= tolerance &&
        abs(lhs.minY - rhs.minY) <= tolerance &&
        abs(lhs.width - rhs.width) <= tolerance &&
        abs(lhs.height - rhs.height) <= tolerance
    }

    private static func comparableFrameFromFinderBounds(left: CGFloat, top: CGFloat, right: CGFloat, bottom: CGFloat) -> CGRect {
        CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }
}
