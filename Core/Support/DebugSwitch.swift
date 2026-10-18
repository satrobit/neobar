import Foundation

/// The single registry of all `DOCK_*` environment-variable switches (since 2026-09-05). Reading a switch always goes through here, and the `"DOCK_..."` literal no longer
/// appears in source: `Scripts/check_debug_switches.py` (run by both CI and release pre-checks) blocks it. Three polarities:
/// - `.killSwitch`: default **on**, `=0` turns it off. Leaves an in-the-field fallback path for mechanisms that have been promoted.
/// - `.trace`: default **off**, `=1` turns it on. Diagnostic prints / trace files / behaviors still experimental.
/// - `.value`: takes the raw string, parsed by the call site itself (milliseconds, material name, level value, ...).
///
/// How to pass them to the dev build is in `Docs/28`: `launchctl setenv K V` -> `open` -> `launchctl unsetenv K`.
enum DebugSwitch: String, CaseIterable, Sendable {
    enum Kind: Sendable { case killSwitch, trace, value }

    // MARK: Mechanism switches that default to on (=0 turns off)
    /// AX event reads use time-limited background batch reads; =0 falls back to untimed synchronous reads on the main thread
    case eventAxAsync = "DOCK_EVENT_AX_ASYNC"
    /// Per-pid skip gate for the 5s periodic reconcile (PeriodicReconcileSkipDecision)
    case reconcileSkip = "DOCK_RECONCILE_SKIP"
    /// Scan probe gate for unmanaged apps (ScanProbeGateDecision)
    case scanGate = "DOCK_SCAN_GATE"
    /// Frontmost pid uses an event-maintained cache, without querying NSWorkspace
    case frontmostCache = "DOCK_FRONTMOST_CACHE"
    /// Reuse gate for the full CG table on event reads (CGSnapshotReuseDecision)
    case cgSnapshotReuse = "DOCK_CG_SNAPSHOT_REUSE"
    /// AX element cache (AXElementCache)
    case axElementCache = "DOCK_AX_ELEMENT_CACHE"
    /// Releases the seat of a window hidden without a destroy notification (`AbsentSeatReleaseDecision`)
    case absentSeatRelease = "DOCK_ABSENT_SEAT_RELEASE"
    /// Switch frontmost via the SkyLight private interface
    case skylightFocus = "DOCK_SKYLIGHT_FOCUS"
    /// AX window handle fast path
    case fastWindowHandle = "DOCK_FAST_WINDOW_HANDLE"
    /// Badge reads only the Dock elements of messaging apps instead of walking the whole tree
    case badgeTargeted = "DOCK_BADGE_TARGETED"
    /// Stop badge polling when the task strip is hidden / there are no readable apps
    case badgePause = "DOCK_BADGE_PAUSE"
    /// Optimistic-state settle gate after minimize
    case minimizeSettleGate = "DOCK_MINIMIZE_SETTLE_GATE"
    /// Frontmost grace during the minimize handoff
    case handoffActiveGrace = "DOCK_HANDOFF_ACTIVE_GRACE"
    /// Frontmost prediction after the minimize handoff
    case handoffActivePrediction = "DOCK_HANDOFF_ACTIVE_PREDICTION"
    /// The "frontmost judgment is stale" guard in action planning
    case staleActiveGuard = "DOCK_STALE_ACTIVE_GUARD"
    /// Drag landing animation (DragLandingPlan)
    case dragLanding = "DOCK_DRAG_LANDING"
    /// macOS 26 Liquid Glass backing plate; =0 falls back to frosted glass
    case liquidGlass = "DOCK_LIQUID_GLASS"
    /// Fixed-scale background refraction on the taskbar and drawer capsule; =0 disables it.
    case liquidGlassDockRefraction = "DOCK_LIQUID_GLASS_DOCK_REFRACTION"
    /// Accepted diagonal system rim lighting; =0 restores the system's vertical light directions.
    case liquidGlassDiagonalHighlight = "DOCK_LIQUID_GLASS_DIAGONAL_HIGHLIGHT"
    /// Accepted stronger key/fill lights; =0 preserves the system's native light strength.
    case liquidGlassHighlightBoost = "DOCK_LIQUID_GLASS_HIGHLIGHT_BOOST"
    /// Balanced clearance around the strip's end icons; =0 restores the wider end insets.
    case stripBalancedInsets = "DOCK_STRIP_BALANCED_INSETS"
    /// Desktop / fullscreen space-switch intent listener (session event tap)
    case spaceIntent = "DOCK_SPACE_INTENT"
    /// Prediction yielding before native fullscreen entry
    case fullscreenIntent = "DOCK_FULLSCREEN_INTENT"
    /// Fullscreen judgment asks SkyLight for the space type
    case fullscreenSlsVerdict = "DOCK_FULLSCREEN_SLS_VERDICT"
    /// After hiding the strip for a whole-screen covering window (frame ~ whole-screen fallback), watch it and re-judge as soon as it goes off-screen
    case overlayWindowWatch = "DOCK_OVERLAY_WINDOW_WATCH"
    /// Membership repair for showing on all desktops (issue #19)
    case spaceMembershipRepair = "DOCK_SPACE_MEMBERSHIP_REPAIR"
    /// Pin the resident panels into a private space (no graying when sliding between desktops)
    case overlaySpace = "DOCK_OVERLAY_SPACE"
    /// Reverse the scroll-wheel direction on the task strip
    case scrollReverser = "DOCK_SCROLL_REVERSER"
    /// Maximized-window avoidance
    case windowLift = "DOCK_WINDOW_LIFT"
    /// Avoidance writes the frame with animation
    case windowLiftAnim = "DOCK_WINDOW_LIFT_ANIM"
    /// Window lift also covers bottom-docked tiles (halves / quarters); =0 lifts maximized windows only.
    case windowLiftTiles = "DOCK_WINDOW_LIFT_TILES"
    /// Pause hover monitoring while a menu is open
    case menuHoverSuspend = "DOCK_MENU_HOVER_SUSPEND"
    /// Hover monitoring slim mode
    case hoverMonitorLean = "DOCK_HOVER_MONITOR_LEAN"
    /// Pointer polling for the whole-strip single block of the task strip
    case stripHoverPoll = "DOCK_STRIP_HOVER_POLL"
    /// While dragging to adjust height, hide the system cursor and self-draw the up/down arrow panel; =0 neither hides nor draws
    case resizeCursor = "DOCK_RESIZE_CURSOR"
    /// Instant press feedback when pressing a chip
    case chipPressDown = "DOCK_CHIP_PRESS_DOWN"
    /// Follow suppression of card labels against window titles that flip back and forth (WindowTitleSettle)
    case titleSettle = "DOCK_TITLE_SETTLE"
    /// When Finder has no window, clicking its icon first sends the Dock-style "reopen" event (FinderNewWindowOpener); =0 only opens a folder per preference
    case finderReopenEvent = "DOCK_FINDER_REOPEN_EVENT"

    // MARK: Tracing / experiments that default to off (=1 turns on)
    /// Write multi-screen ownership to the log (category display-trace)
    case displayTrace = "DOCK_DISPLAY_TRACE"
    /// Print the launch feedback timeline
    case launchTrace = "DOCK_LAUNCH_TRACE"
    /// Print the chip click probe
    case chipProbe = "DOCK_CHIP_PROBE"
    /// Segmented recording of click latency (ClickLatencyTrace)
    case clickTrace = "DOCK_CLICK_TRACE"
    /// Hover / frame-change trace file (HoverTrace)
    case hoverTrace = "DOCK_HOVER_TRACE"
    /// Edge hover / screen-switch diagnostic prints
    case edgehoverTrace = "DOCK_EDGEHOVER_TRACE"
    /// Print horizontal scroll-wheel scrolling
    case stripWheelTrace = "DOCK_STRIP_WHEEL_TRACE"
    /// Chip animation / bubble trace
    case chipAnimTrace = "DOCK_CHIP_ANIM_TRACE"
    /// Enable only the per-frame probes for label width / panel width and the relayout lines (without the hover trace's 8ms stall sampling and pointer polling)
    case labelProbe = "DOCK_LABEL_PROBE"
    /// Space-switch intent trace
    case spaceIntentTrace = "DOCK_SPACE_INTENT_TRACE"
    /// Print scroll-wheel reversal events
    case scrollReverserTrace = "DOCK_SCROLL_REVERSER_TRACE"
    /// Window avoidance trace
    case windowLiftTrace = "DOCK_WINDOW_LIFT_TRACE"
    /// Experiment: fall back to an app-level hide when minimize fails
    case minimizeAppFallback = "DOCK_MINIMIZE_APP_FALLBACK"
    /// Acceptance aid: drop every per-window destroy notification, imitating an app that hides
    /// windows without posting one (Bilibili 1.18), so `DOCK_ABSENT_SEAT_RELEASE` can be exercised locally
    case simulateNoDestroy = "DOCK_SIMULATE_NO_DESTROY"

    // MARK: Value-typed (the call site parses them itself)
    /// AX read timeout in milliseconds for the periodic reconcile (default 100; 0 = old synchronous path)
    case reconcileAxTimeoutMs = "DOCK_RECONCILE_AX_TIMEOUT_MS"
    /// AX timeout in milliseconds for the launch seed probe (0 = untimed)
    case seedAxTimeoutMs = "DOCK_SEED_AX_TIMEOUT_MS"
    /// Drag landing flight duration in milliseconds
    case dragFlightMs = "DOCK_DRAG_FLIGHT_MS"
    /// Layout curve for label lengthening / shortening: "ms,c1x,c1y,c2x,c2y" (shared by both sides, see `LabelWidthAnimation`)
    case labelAnim = "DOCK_LABEL_ANIM"
    /// Window inventory diagnostic log: 1 / 0 overrides the UserDefaults InventoryLog
    case inventoryLog = "DOCK_INVENTORY_LOG"
    /// Experiment: raw NSWindow.Level values of the three task-strip panels
    case panelLevel = "DOCK_PANEL_LEVEL"
    /// Experiment: panel material name
    case panelMaterial = "DOCK_PANEL_MATERIAL"
    /// A folder path: its popup content is drawn off-screen to a PNG (`StackPopupSnapshotProbe`).
    case stackPopupSnapshot = "DOCK_STACK_POPUP_SNAPSHOT"
    /// Experiment: panel saturation
    case panelSaturation = "DOCK_PANEL_SATURATION"
    /// Experiment: panel thickness tier (=1 turns on)
    case panelThickness = "DOCK_PANEL_THICKNESS"
    /// Experiment: chip pill fill
    case chipPillFill = "DOCK_CHIP_PILL_FILL"
    /// Experiment: inactive tab color
    case labelInactive = "DOCK_LABEL_INACTIVE"
    /// Transit-cell tile color scheme blue|graphite|light
    case shelfTile = "DOCK_SHELF_TILE"
    /// Glass tuning: clarity
    case liquidGlassClearTint = "DOCK_LIQUID_GLASS_CLEAR_TINT"
    /// Glass tuning: white overlay
    case liquidGlassWhiteOverlay = "DOCK_LIQUID_GLASS_WHITE_OVERLAY"
    /// Glass tuning: darkening
    case liquidGlassDimming = "DOCK_LIQUID_GLASS_DIMMING"
    /// Glass tuning: stroke peak
    case liquidGlassBorder = "DOCK_LIQUID_GLASS_BORDER"
    /// Glass tuning: stroke edge
    case liquidGlassBorderEdge = "DOCK_LIQUID_GLASS_BORDER_EDGE"
    /// Glass tuning: stroke corner cut
    case liquidGlassBorderCut = "DOCK_LIQUID_GLASS_BORDER_CUT"
    /// Glass tuning: stroke corner spread
    case liquidGlassBorderSpread = "DOCK_LIQUID_GLASS_BORDER_SPREAD"
    /// Glass tuning: stroke line width
    case liquidGlassBorderWidth = "DOCK_LIQUID_GLASS_BORDER_WIDTH"
    /// Glass tuning: inner stroke
    case liquidGlassBorderInner = "DOCK_LIQUID_GLASS_BORDER_INNER"
    /// Glass tuning: background material opacity
    case liquidGlassBackgroundOpacity = "DOCK_LIQUID_GLASS_BACKGROUND_OPACITY"
    /// Glass tuning: window blur radius
    case liquidGlassWindowBlur = "DOCK_LIQUID_GLASS_WINDOW_BLUR"
    /// Glass tuning: content inset
    case liquidGlassContentInset = "DOCK_LIQUID_GLASS_CONTENT_INSET"
    /// Private `NSGlassEffectView` variant for the plate (default 3 = the Dock's own material); `off` = SwiftUI plate
    case liquidGlassSystemVariant = "DOCK_LIQUID_GLASS_SYSTEM_VARIANT"

    var kind: Kind {
        switch self {
        case .eventAxAsync, .reconcileSkip, .scanGate, .frontmostCache,
             .cgSnapshotReuse, .axElementCache, .absentSeatRelease, .skylightFocus, .fastWindowHandle,
             .badgeTargeted, .badgePause, .minimizeSettleGate, .handoffActiveGrace,
             .handoffActivePrediction, .staleActiveGuard, .dragLanding, .liquidGlass, .liquidGlassDockRefraction,
             .liquidGlassDiagonalHighlight, .liquidGlassHighlightBoost, .stripBalancedInsets,
             .spaceIntent, .fullscreenIntent, .fullscreenSlsVerdict, .overlayWindowWatch, .spaceMembershipRepair,
             .overlaySpace, .scrollReverser, .windowLift, .windowLiftAnim, .windowLiftTiles,
             .menuHoverSuspend, .hoverMonitorLean, .stripHoverPoll, .resizeCursor, .chipPressDown, .titleSettle,
             .finderReopenEvent:
            return .killSwitch
        case .displayTrace, .launchTrace, .chipProbe, .clickTrace,
             .hoverTrace, .edgehoverTrace, .stripWheelTrace, .chipAnimTrace, .labelProbe,
             .spaceIntentTrace, .scrollReverserTrace, .windowLiftTrace, .minimizeAppFallback,
             .simulateNoDestroy:
            return .trace
        case .reconcileAxTimeoutMs, .seedAxTimeoutMs, .dragFlightMs, .labelAnim, .inventoryLog,
             .panelLevel, .panelMaterial, .panelSaturation, .panelThickness,
             .chipPillFill, .labelInactive, .shelfTile, .liquidGlassClearTint,
             .liquidGlassWhiteOverlay, .liquidGlassDimming, .liquidGlassBorder, .liquidGlassBorderEdge,
             .liquidGlassBorderCut, .liquidGlassBorderSpread, .liquidGlassBorderWidth, .liquidGlassBorderInner,
             .liquidGlassBackgroundOpacity, .liquidGlassWindowBlur, .liquidGlassContentInset,
             .liquidGlassSystemVariant, .stackPopupSnapshot:
            return .value
        }
    }

    /// Raw string (unset -> nil). The only way to read value-typed switches; boolean ones can also use it to see the original text.
    func value(in environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        environment[rawValue]
    }

    /// Boolean read; polarity is decided by `kind`, word-for-word equivalent to the `!= "0"` / `== "1"` at each call site before the migration.
    func isEnabled(in environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        switch kind {
        case .killSwitch: return environment[rawValue] != "0"
        case .trace: return environment[rawValue] == "1"
        case .value:
            assertionFailure("\(rawValue) is a value switch; read it with value(in:)")
            return environment[rawValue] != nil
        }
    }
}
