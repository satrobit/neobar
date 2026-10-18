import Foundation

/// Click -> the window actually starts moving: where the time in between goes. Off by default; `DOCK_CLICK_TRACE=1` turns it on.
///
/// **Why it exists**: the repo has been burned several times by "estimating latency from constants in the code and then deciding based on the estimate"
/// (`Docs/27`, "How firm is this judgment: not very"; `Docs/28`). In the 2026-08-11 round, the handle capture of minimize restore was going to change,
/// and before and after the change must be measured with the same ruler. `Docs/22` §12 records: it was precisely by timestamping the slps landing moment
/// that it became clear at a glance that "the flickering case lands at +400~900ms, the clean case within +220ms" --
/// verifying only the end state can't reveal that.
///
/// Paired by `windowID`, changing no existing function signature (execution is on another thread, so task-local can't be threaded through).
/// Two quick clicks on the same card will overlap, which is acceptable for a diagnostic scenario: `end` is flushed in pairs in order of occurrence.
enum ClickLatencyTrace {
    static let isEnabled = DebugSwitch.clickTrace.isEnabled(in: ProcessInfo.processInfo.environment)

    /// Start of a click. `kind` = the planned action, `status` = the window status in the snapshot (for classification).
    static func begin(windowID: String, kind: String, status: String, bundleID: String?) {
        guard isEnabled else { return }
        runtime.begin(windowID: windowID, kind: kind, status: status, bundleID: bundleID,
                      at: ProcessInfo.processInfo.systemUptime)
    }

    /// Intermediate milestone. `detail` records branch info such as "which tier the handle hit".
    static func mark(windowID: String?, _ stage: String, detail: String? = nil) {
        guard isEnabled, let windowID else { return }
        runtime.mark(windowID: windowID, stage: stage, detail: detail,
                     at: ProcessInfo.processInfo.systemUptime)
    }

    static func end(windowID: String?, success: Bool) {
        guard isEnabled, let windowID else { return }
        runtime.end(windowID: windowID, success: success,
                    at: ProcessInfo.processInfo.systemUptime)
    }

    private static let runtime = Runtime()

    private final class Runtime: @unchecked Sendable {
        private let queue = DispatchQueue(label: "app.neobar.NeoBar.click-latency-trace")
        private var sessions: [String: Session] = [:]

        private struct Session {
            let windowID: String
            let kind: String
            let status: String
            let bundleID: String?
            let startedAt: TimeInterval
            var stages: [(String, TimeInterval, String?)] = []
        }

        func begin(windowID: String, kind: String, status: String, bundleID: String?, at: TimeInterval) {
            queue.async { [self] in
                sessions[windowID] = Session(windowID: windowID, kind: kind, status: status,
                                             bundleID: bundleID, startedAt: at)
            }
        }

        func mark(windowID: String, stage: String, detail: String?, at: TimeInterval) {
            queue.async { [self] in
                sessions[windowID]?.stages.append((stage, at, detail))
            }
        }

        func end(windowID: String, success: Bool, at: TimeInterval) {
            queue.async { [self] in
                guard let session = sessions.removeValue(forKey: windowID) else { return }
                append(line: line(for: session, success: success, endedAt: at))
            }
        }

        /// Milliseconds, relative to `t_tap`. Written as one flat JSON line per click, so `jq` gives percentiles directly.
        private func line(for session: Session, success: Bool, endedAt: TimeInterval) -> String {
            func ms(_ t: TimeInterval) -> Double { ((t - session.startedAt) * 1000 * 100).rounded() / 100 }
            var fields: [String] = [
                "\"kind\":\(quote(session.kind))",
                "\"status\":\(quote(session.status))",
                "\"bundleID\":\(session.bundleID.map(quote) ?? "null")",
                "\"success\":\(success)",
                "\"totalMs\":\(ms(endedAt))"
            ]
            for (stage, at, detail) in session.stages {
                fields.append("\"\(stage)Ms\":\(ms(at))")
                if let detail { fields.append("\"\(stage)Detail\":\(quote(detail))") }
            }
            return "{\(fields.joined(separator: ","))}"
        }

        private func quote(_ value: String) -> String {
            let escaped = value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }

        private lazy var fileURL: URL? = {
            let fm = FileManager.default
            guard let base = fm.urls(for: .libraryDirectory, in: .userDomainMask).first else { return nil }
            let dir = base.appendingPathComponent("Logs/app.neobar.NeoBar", isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir.appendingPathComponent("click-latency.jsonl")
        }()

        private func append(line: String) {
            guard let fileURL, let data = (line + "\n").data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: fileURL)
            }
        }
    }
}
