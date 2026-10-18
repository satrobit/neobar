import Foundation

/// The **pure decision layer** of the membership menu: given the surface the icon sits on (strip / drawer) + Finder / kept / messaging
/// state, it produces the membership items that should appear (order = render order, no closures). Extracted as pure logic for unit testing; mapping `Item`
/// to menu items carrying actions is done by `LauncherMembershipItem.items`, consumed uniformly by the four menu-construction paths.
///
/// Fixed matrix (the messaging item's title is constant; membership is expressed through the native checked state):
/// - strip ordinary: Keep in Dock + Pin to the left of the Dock bar (unchecked)
/// - strip messaging: Keep in Dock + Pin to the left of the Dock bar (checked)
/// - drawer ordinary: Keep in Dock only
/// - drawer messaging: Keep in Dock + Pin to the left of the Dock bar (checked)
/// - Finder: Keep in Dock only (since 2026-08-20 Finder joins the unified keep checkbox, but still cannot enter the messaging area)
enum AppMembershipMenuPlan {
    enum Surface: Equatable { case strip, drawer }

    /// Presentation state without closures, for the rendering layer to map to concrete actions.
    enum Item: Equatable {
        case keep(isChecked: Bool)
        case messaging(isChecked: Bool)
    }

    static func items(surface: Surface,
                      isFinder: Bool,
                      isKept: Bool,
                      isMessaging: Bool) -> [Item] {
        // Finder gets only the keep checkbox: an icon in the messaging area represents "this app's main window", and Finder has no such semantics.
        if isFinder { return [.keep(isChecked: isKept)] }
        // The keep checkbox always comes first, the messaging command after.
        var items: [Item] = [.keep(isChecked: isKept)]
        if isMessaging {
            items.append(.messaging(isChecked: true))
        } else if surface == .strip {
            // "Pin to the left of the Dock bar" appears only for ordinary apps on the strip: marking in the drawer doesn't change placement (the drawer has higher priority),
            // so it has no visible effect, hence the drawer surface doesn't offer this command.
            items.append(.messaging(isChecked: false))
        }
        return items
    }
}
