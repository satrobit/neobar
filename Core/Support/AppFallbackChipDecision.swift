import Foundation

/// Projects zero-seat tracked processes into at most one app-level fallback per bundle.
enum AppFallbackChipDecision {
    struct Process: Equatable {
        let pid: pid_t
        let bundleID: String?
        let appName: String
        let hasSeats: Bool
        let isFrontmost: Bool
    }

    struct Fallback: Equatable {
        let pid: pid_t
        let windowID: String
    }

    private enum GroupKey: Hashable {
        case bundle(String)
        case unbundled(pid_t)
    }

    static func fallbacks(for processes: [Process]) -> [Fallback] {
        var grouped: [GroupKey: [(index: Int, process: Process)]] = [:]
        for (index, process) in processes.enumerated() {
            let key = process.bundleID.map(GroupKey.bundle) ?? .unbundled(process.pid)
            grouped[key, default: []].append((index, process))
        }

        return grouped.compactMap { key, members -> (index: Int, fallback: Fallback)? in
            guard !members.contains(where: { $0.process.hasSeats }) else { return nil }
            guard let representative = members.last(where: { $0.process.isFrontmost }) ?? members.last else {
                return nil
            }
            let windowID: String
            switch key {
            case .bundle(let bundleID):
                windowID = "app-\(bundleID)"
            case .unbundled(let pid):
                windowID = "app-unbundled-\(pid)"
            }
            return (representative.index, Fallback(pid: representative.process.pid, windowID: windowID))
        }
        .sorted { $0.index < $1.index }
        .map(\.fallback)
    }
}
