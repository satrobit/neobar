import Foundation

/// "Follow suppression" of card labels against window titles (2026-09-18).
///
/// Web pages repeatedly change `document.title` by themselves (new-message flashing in OA systems, carousels), so a browser window title flips back and forth every second;
/// the card dutifully follows by changing its text, widening and narrowing, pushing the whole row of cards on its right back and forth (a user's screen recording shows 44 seconds without a stop). The inventory layer must report
/// the title faithfully (window identification and tab-group collapsing depend on it), so suppression happens only at the **rendered label** layer:
/// - A title change is followed immediately as usual: navigation and tab switching must not be delayed;
/// - Starting with the (`flipThreshold` + 1)th change of the same card within `memoryWindow`, it is judged as flip-flopping and the label is **frozen at the one currently displayed**;
/// - Only once the raw title has been quiet for `quietInterval` is it released, switching to the latest value in one step.
/// A pure state machine, with the clock injected by the caller; `AppRuntime` takes the output to override the projection layer's label, while the hover bubble and menu still show the raw title.
struct WindowTitleSettle {
    struct Policy: Equatable {
        /// Sliding window for counting changes.
        var memoryWindow: TimeInterval = 6
        /// Number of changes allowed to follow as usual within the window; exceeding it freezes.
        var flipThreshold: Int = 3
        /// How long the raw title must stay unchanged before the freeze is released.
        var quietInterval: TimeInterval = 2
    }

    private struct Entry {
        var displayed: String
        var raw: String
        var lastChangeAt: TimeInterval
        var changeTimes: [TimeInterval]
    }

    let policy: Policy
    private var entries: [String: Entry] = [:]

    init(policy: Policy = Policy()) {
        self.policy = policy
    }

    /// Feed one round of current titles (card id -> raw title), returning the **frozen** cards (id -> the title they should display).
    /// Cards that don't appear in the input are forgotten immediately; newly appearing cards start from the current title.
    mutating func observe(rawTitles: [String: String], now: TimeInterval) -> [String: String] {
        entries = entries.filter { rawTitles[$0.key] != nil }
        var held: [String: String] = [:]
        for (id, raw) in rawTitles {
            guard var entry = entries[id] else {
                entries[id] = Entry(displayed: raw, raw: raw, lastChangeAt: now, changeTimes: [])
                continue
            }
            if raw != entry.raw {
                entry.raw = raw
                entry.lastChangeAt = now
                entry.changeTimes.removeAll { $0 < now - policy.memoryWindow }
                entry.changeTimes.append(now)
                if entry.changeTimes.count <= policy.flipThreshold { entry.displayed = raw }
            } else if entry.displayed != raw, now - entry.lastChangeAt >= policy.quietInterval {
                entry.displayed = raw
            }
            entries[id] = entry
            if entry.displayed != entry.raw { held[id] = entry.displayed }
        }
        return held
    }

    /// The earliest moment a frozen card can be released; no freeze -> nil. The caller `observe`s once more at that time.
    var nextReleaseAt: TimeInterval? {
        entries.values
            .filter { $0.displayed != $0.raw }
            .map { $0.lastChangeAt + policy.quietInterval }
            .min()
    }
}
