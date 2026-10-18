import Foundation

/// The segment of title shared by several window cards of the same app does not help tell them apart, so it is removed from the label (issue #41).
///
/// When Safari has two windows of the same profile open, the titles are "Personal — Start Page" and "Personal — Bilibili"; "Personal —" is identical on both cards,
/// yet it pushes the second half that really distinguishes the windows past the `WindowTitleTextMetrics.maximumWidth` (140pt) truncation.
/// The app-name suffix (`WindowDisplayTitle.trimmingAppNameSuffix`) is a special case of this, but it cannot reach
/// **prefix**-style repeats such as the profile name, nor repeats such as "mio: " that are not an app name.
///
/// **Being dynamic is intentional** (owner 2026-09-04): after opening a window of the "Work" profile, "Personal" starts to distinguish windows,
/// so all three cards show it again. Labels therefore grow and shrink as windows open and close -- exactly "show only the part that currently distinguishes".
///
/// The call site is in the projection layer (`DockStripView.makeProjection`), grouping by **the cards actually displayed on this bar**:
/// in multi-screen mode 4 each screen shows only its own windows and the shared segment differs per screen; computing over the full set in the data layer would strip
/// the only distinguishing information from the last remaining card on some screen.
enum StripSharedAffixTrim {
    /// A group of titles of the same app -> the titles after removing the common prefix / suffix (order corresponds one to one with the input).
    ///
    /// **All or nothing**: if any entry would be truncated to empty, or the common segment cannot be cut at a separator boundary, the whole group is returned unchanged.
    /// Trimming only some of the cards is the worst outcome -- the user sees a row of misaligned half titles.
    static func trimmingSharedAffixes(_ titles: [String]) -> [String] {
        guard titles.count >= 2 else { return titles }

        let afterPrefix = trimmingSharedPrefix(titles)
        return trimmingSharedSuffix(afterPrefix)
    }

    // MARK: - Prefix

    private static func trimmingSharedPrefix(_ titles: [String]) -> [String] {
        guard let raw = sharedPrefix(titles), !raw.isEmpty else { return titles }
        // **Fall back to the last separator boundary**. This step cannot be skipped: the raw common prefix of "mio: Notifications" and "mio: New Tab"
        // is "mio: N" (both words start with N), and cutting directly would give "otifications".
        guard let cut = raw.range(ofLastSeparatorBoundary: separators)?.upperBound else { return titles }
        let affix = String(raw[raw.startIndex..<cut])
        guard !affix.isEmpty else { return titles }

        let trimmed = titles.map { String($0.dropFirst(affix.count)) }
        return isAcceptable(trimmed) ? trimmed.map(cleaned) : titles
    }

    private static func sharedPrefix(_ titles: [String]) -> String? {
        titles.dropFirst().reduce(titles[0]) { $0.commonPrefix(with: $1) }
    }

    // MARK: - Suffix

    private static func trimmingSharedSuffix(_ titles: [String]) -> [String] {
        let reversed = titles.map { String($0.reversed()) }
        guard let rawReversed = sharedPrefix(reversed), !rawReversed.isEmpty else { return titles }
        let raw = String(rawReversed.reversed())
        // In the suffix direction find the **first** separator boundary (in the pre-reversal string that is the leftmost one).
        guard let cut = raw.range(ofFirstSeparatorBoundary: separators)?.lowerBound else { return titles }
        let affix = String(raw[cut..<raw.endIndex])
        guard !affix.isEmpty else { return titles }

        let trimmed = titles.map { String($0.dropLast(affix.count)) }
        return isAcceptable(trimmed) ? trimmed.map(cleaned) : titles
    }

    // MARK: - Guardrails

    /// After trimming, every entry must still have something left. Leaving one empty label would turn that card into a nameless window card.
    private static func isAcceptable(_ trimmed: [String]) -> Bool {
        trimmed.allSatisfy { !cleaned($0).isEmpty }
    }

    private static func cleaned(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Separator boundaries. Compared with the table in `WindowDisplayTitle` it adds the colon -- that table only serves the trailing app name,
    /// whereas prefix-style repeats such as "mio: " depend precisely on the colon. Longer ones come first, so a shorter one does not hit first and cut away half.
    static let separators = [" — ", " – ", " - ", " | ", " · ", " » ", " > ",
                            "：", ": ", "—", "–", "|", "·", "»", ">", ":", "-"]
}

private extension String {
    /// The position of the **last** separator occurrence within this string (used to fall back the common prefix).
    func range(ofLastSeparatorBoundary separators: [String]) -> Range<String.Index>? {
        separators.compactMap { range(of: $0, options: .backwards) }
            .max { $0.upperBound < $1.upperBound }
    }

    /// The position of the **first** separator occurrence within this string (used to tighten the common suffix).
    func range(ofFirstSeparatorBoundary separators: [String]) -> Range<String.Index>? {
        separators.compactMap { range(of: $0) }
            .min { $0.lowerBound < $1.lowerBound }
    }
}
