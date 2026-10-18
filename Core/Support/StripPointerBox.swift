import CoreGraphics

/// Enter / exit hysteresis box for "is the pointer on the task strip" (pure geometry, covered by unit tests). Easy to enter, hard to leave, with a hysteresis band in between:
/// a jitter at the boundary does not flip it. Two sets of criteria:
/// - `.drawerConversion`: dragging a drawer icon down onto the strip to promote / undo. Generous above (enter 16 / exit 40),
///   because the pointer comes from above, and near the strip a single jitter must not undo the promotion.
/// - `.stripPresence`: a payload dragged from the strip leaves / returns to the strip (closes up once dragged out). Above, aligned to the native Dock (enter 0 / exit 6):
///   the gap closes as soon as the pointer leaves the strip top, and reopens under the pointer as soon as it returns inside the strip -- measured frame by frame from a native screen recording (owner 2026-09-03;
///   the earlier 24pt was reported as "have to lift very high before the task strip closes up"). The 6pt hysteresis band only blocks pointer jitter.
///
/// On the right side, both extend all the way to the outer edge of the drawer entry capsule (`rightReach` = capsule spacing + capsule width): when dragging down the drawer's rightmost column
/// the cursor stays on the capsule throughout, and unless it is merged in it can never get into the box (measured 2026-08-18: across a whole trip, all 60 frames of enter were false);
/// conversely, an icon on the strip moved sideways onto the capsule still counts as on the strip, yielding without closing up.
struct StripPointerBox: Equatable {
    enum Profile {
        case drawerConversion
        case stripPresence

        /// Height above the strip top that still counts as "in" / "clearly out".
        var topEnter: CGFloat { self == .drawerConversion ? 16 : 0 }
        var topOut: CGFloat { self == .drawerConversion ? 40 : 6 }
    }

    let enter: Bool
    let clearlyOut: Bool

    /// - Parameters:
    ///   - pointer: screen coordinates (bottom-left).
    ///   - stripRect: the screen rect of the task strip's root view (`DockStripView.stripRootScreenRect`).
    ///   - rightReach: the width beyond the strip's right edge that still counts as "on the strip" (the capsule).
    static func classify(pointer g: CGPoint, stripRect r: CGRect, rightReach: CGFloat,
                         profile: Profile) -> StripPointerBox {
        let enter      = g.x >= r.minX - 8  && g.x <= r.maxX + rightReach
                      && g.y >= r.minY - 8  && g.y <= r.maxY + profile.topEnter
        let clearlyOut = g.x < r.minX - 24  || g.x > r.maxX + rightReach + 16
                      || g.y < r.minY - 24  || g.y > r.maxY + profile.topOut
        return StripPointerBox(enter: enter, clearlyOut: clearlyOut)
    }
}
