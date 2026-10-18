import AppKit
import ApplicationServices

/// Reads per-app badge strings from the system Dock's accessibility tree.
///
/// Apps publish unread counts by setting their Dock tile badge; there is no public
/// API to read another app's badge directly, but the Dock process exposes each icon
/// as an AX element whose `AXStatusLabel` attribute carries the badge text ("3",
/// "99+", "•"). Mapping element → app uses the Dock item's `AXURL` (the .app bundle
/// URL), which is exact — no name matching.
///
/// Requires Accessibility permission, which this app already needs. Apps only get a
/// Dock icon while running (or pinned), and messaging chips only render while the
/// app runs, so coverage is aligned by construction.
/// Product of one full tree walk: the Dock process pid + bundleID -> AXDockItem element references. Element references are reused across ticks
/// (the targeted read touches only these references every 0.5s, no longer walking the whole tree); they are discarded and rebuilt wholesale when the Dock restarts, a read fails, identity re-verification fails, or the messaging list
/// changes. AXUIElement is a thread-safe CFType, so carrying it across threads
/// follows the same precedent as AXWindowSnapshot.element.
struct DockItemCache: @unchecked Sendable {
    let dockPID: pid_t
    let elementsByBundleID: [String: AXUIElement]
}

struct DockBadgeWalkOutcome {
    let badges: [String: String]
    /// nil when the Dock process wasn't found (the next tick will do a full walk again).
    let cache: DockItemCache?
    /// Persistent cache of app path -> bundleID (reused across tree walks, saving a Bundle(url:) disk read on every tick).
    let pathToBundleID: [String: String]
}

enum DockBadgeTargetedOutcome: Equatable {
    case ok([String: String])
    /// Dock generation change / element read error / identity re-verification failure: this round's result is untrustworthy. The caller must keep the last published value
    /// (a transient error must not make the badge flash away) and schedule a re-walk of the whole tree.
    case cacheInvalid
}

protocol DockBadgeReading: Sendable {
    func readBadges() -> [String: String]
    func fullWalk(previousPathMap: [String: String]) -> DockBadgeWalkOutcome
    func targetedRead(
        cache: DockItemCache,
        bundleIDs: [String],
        previousBadges: [String: String]
    ) -> DockBadgeTargetedOutcome
}

struct DockBadgeReader: DockBadgeReading, Sendable {
    /// Returns [bundleID: badge text] for every Dock item that currently shows a badge.
    /// Call off the main thread; AX messaging to the Dock can block briefly.
    func readBadges() -> [String: String] {
        guard let dock = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.dock").first else { return [:] }

        let dockElement = AXUIElementCreateApplication(dock.processIdentifier)
        _ = AXUIElementSetMessagingTimeout(dockElement, 0.25)

        var bundleIDByPath: [String: String] = [:]
        var result: [String: String] = [:]
        // Dock AX hierarchy: application element → AXList children → AXDockItem children.
        for list in children(of: dockElement) {
            for item in children(of: list) {
                guard let badge = stringAttribute("AXStatusLabel", of: item),
                      !badge.isEmpty,
                      let url = urlAttribute(kAXURLAttribute as String, of: item),
                      let bundleID = bundleID(forAppURL: url, cache: &bundleIDByPath) else { continue }
                result[bundleID] = badge
            }
        }
        return result
    }

    /// Full tree walk: the same tree as `readBadges()`, but also caches **every** app tile's element reference (one extra read of
    /// the AXURL/item), in exchange for reading only the one or two messaging-app elements on each later tick. The tree walk is a low-frequency action (10s self-heal + list
    /// change + read-error recovery), not on the 0.5s hot path.
    func fullWalk(previousPathMap: [String: String]) -> DockBadgeWalkOutcome {
        guard let dock = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            return DockBadgeWalkOutcome(badges: [:], cache: nil, pathToBundleID: previousPathMap)
        }

        let dockElement = AXUIElementCreateApplication(dock.processIdentifier)
        _ = AXUIElementSetMessagingTimeout(dockElement, 0.25)

        var pathMap = previousPathMap
        var badges: [String: String] = [:]
        var elements: [String: AXUIElement] = [:]
        for list in children(of: dockElement) {
            for item in children(of: list) {
                guard let url = urlAttribute(kAXURLAttribute as String, of: item),
                      let bid = bundleID(forAppURL: url, cache: &pathMap) else { continue }
                _ = AXUIElementSetMessagingTimeout(item, 0.25)
                elements[bid] = item
                if let badge = stringAttribute("AXStatusLabel", of: item) {
                    badges[bid] = badge
                }
            }
        }
        return DockBadgeWalkOutcome(
            badges: badges,
            cache: DockItemCache(dockPID: dock.processIdentifier, elementsByBundleID: elements),
            pathToBundleID: pathMap
        )
    }

    /// Targeted read: reads AXStatusLabel only for items in `bundleIDs` that have cached elements (1-3 AX round trips per tick).
    /// Three conservative invalidations: (1) Dock pid generation change; (2) any read error other than "no badge"; (3) **items whose value changed** have their element's AXURL
    /// re-verified before publishing to still point at the same bundleID (closing off the silent error of "a recycled element reporting a count for another app";
    /// zero cost in steady state -- no re-verification if the value is unchanged).
    func targetedRead(
        cache: DockItemCache,
        bundleIDs: [String],
        previousBadges: [String: String]
    ) -> DockBadgeTargetedOutcome {
        guard let dock = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.dock").first,
              dock.processIdentifier == cache.dockPID else { return .cacheInvalid }

        var badges: [String: String] = [:]
        for bid in bundleIDs {
            guard let item = cache.elementsByBundleID[bid] else { continue }
            switch statusLabelRead(of: item) {
            case .value(let badge): badges[bid] = badge
            case .absent: break
            case .readError: return .cacheInvalid
            }
        }
        for bid in bundleIDs where badges[bid] != previousBadges[bid] {
            guard let item = cache.elementsByBundleID[bid],
                  let url = urlAttribute(kAXURLAttribute as String, of: item),
                  Bundle(url: url)?.bundleIdentifier == bid else { return .cacheInvalid }
        }
        return .ok(badges)
    }

    // MARK: - AX helpers

    private enum AttributeRead {
        case value(String)
        /// Normal "no badge": the read succeeded but is empty / has no value / the attribute is unsupported.
        case absent
        /// Other errors (element invalid, timeout, etc.) -- must be distinguished from "no badge", otherwise a transient error would make the badge flash away.
        case readError
    }

    private func statusLabelRead(of element: AXUIElement) -> AttributeRead {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, "AXStatusLabel" as CFString, &value)
        switch err {
        case .success:
            guard let text = value as? String else { return .absent }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? .absent : .value(trimmed)
        case .noValue, .attributeUnsupported:
            return .absent
        default:
            return .readError
        }
    }


    private func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let elements = value as? [AXUIElement] else { return [] }
        return elements
    }

    private func stringAttribute(_ attribute: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func urlAttribute(_ attribute: String, of element: AXUIElement) -> URL? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let url = value as? NSURL else { return nil }
        return url as URL
    }

    private func bundleID(forAppURL url: URL, cache: inout [String: String]) -> String? {
        let path = url.path
        if let cached = cache[path] { return cached }
        guard let bundleID = Bundle(url: url)?.bundleIdentifier else { return nil }
        cache[path] = bundleID
        return bundleID
    }
}
