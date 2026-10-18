import Combine
import Foundation

/// App-wide appearance (settings window → General → Appearance). The bar, capsule, drawer, bubble,
/// menus, settings and guide windows all follow it; the stack popups stay dark either way.
///
/// It is applied as `NSApp.appearance` (`AppDelegate`) and nowhere else: the materials and SwiftUI's
/// `colorScheme` both derive from the window appearance, so one switch keeps text and plate together.
///
/// The raw value is persisted — renaming a case resets everyone who chose it to `system`.
enum AppearanceMode: String, CaseIterable {
    /// Whatever macOS is showing right now, including its own automatic light/dark schedule.
    case system
    case light
    case dark

    static let `default` = AppearanceMode.system

    var displayName: String {
        switch self {
        case .system: return String(localized: "System")
        case .light: return String(localized: "Light")
        case .dark: return String(localized: "Dark")
        }
    }
}

/// Hover effect tier.
/// - `standard`: icon scales 36->24pt + name pops up below + the whole folder cell grows (native Dock feel).
/// - `quiet`: **completely still** while the mouse moves over the strip -- no scaling, no movement, no name popping up, no capsule fill brightening.
///
/// Two places not affected by this tier (set by the owner 2026-08-02): **icons inside the drawer panel** are unchanged,
/// and the 2x2 grid in the **drawer entry capsule** still grows slightly -- the capsule belongs to the drawer.
/// The "show the full text in a floating layer when the title is too long" behavior is kept in both tiers: it is the only way to read a truncated title, and it moves no card.
///
/// **Externally it is just one checkbox**: the menu calls it "Show app name on mouse hover", **checked = `.standard`**,
/// unchecked = `.quiet` (renamed by the owner 2026-08-02; the old "Hover effect > Standard / Quiet" was too abstract).
/// That name **deliberately says only half of it** -- unchecking also stops the icon scaling and folder-cell growth;
/// don't narrow the behavior to match the name; see `Docs/27` for the reasoning. Elsewhere in the code it is still called
/// the "quiet tier" (= `.quiet` = unchecked), and the enum is kept in case a third tier is added later.
enum HoverStyle: String, CaseIterable {
    case standard
    case quiet

    /// **Default `.quiet`** (decided by the owner 2026-09-01; it was `.standard` before): on a fresh install, moving the mouse over the
    /// task strip doesn't pop up the app-name bubble, only a slight grow. Existing users already have a value in the key and are unaffected.
    static let `default` = HoverStyle.quiet

    /// Whether hover produces **expressive** changes (name bubble, folder-cell growth). Chip views all use this as the criterion
    /// rather than comparing cases themselves; the menu's checked state reads it too (`.on` <=> `isExpressive`).
    var isExpressive: Bool { self == .standard }

    /// Whether expressive hover is happening right now (name bubble / folder-cell growth). Shared by all chips, so they don't each write `isExpressive && isHovered`.
    func showsExpressiveHover(isHovering: Bool) -> Bool { isExpressive && isHovering }

    /// Hover feedback of the quiet tier: the whole piece **grows slightly**.
    ///
    /// **Always false in the standard tier** -- its feedback is the name bubble, and on 2026-08-17 the owner required the standard tier to stay pixel-identical.
    /// This was added because the quiet tier originally had **no feedback at all**: when the app name moved into the bubble on 2026-08-16,
    /// the chip's hover geometry was frozen along the way (icon doesn't shrink, pill doesn't make room); the standard tier still had the bubble, but the quiet tier dropped to zero.
    ///
    /// The form first tried was a "fade-in background color without size change" (the one `Docs/27` anticipated early on); after trying it on a real device on 2026-08-17
    /// the owner said "meh", so it became a slight grow. **Growing is safe today**: the reason it was rejected back then was "changing size would reflow
    /// the whole row", which referred to the old layout with the app name under the icon, where the card widened as soon as the name appeared;
    /// since the name moved into the bubble neither tier reflows, and this uses `scaleEffect` (a pure rendering transform that doesn't touch layout).
    ///
    func showsQuietHoverFeedback(isHovering: Bool) -> Bool {
        !isExpressive && isHovering
    }
}

/// User-customized show/hide task strip shortcut (nil = default ⌥⇧⌘D).
/// `glyphs` is frozen from NSEvent's characters at the moment of recording (reason in `HotKeyGlyphs`); the display side only reads it.
struct StoredHotKeyShortcut: Equatable {
    let keyCode: UInt32
    let carbonModifiers: UInt32
    let glyphs: String
}


@MainActor
final class AppSettingsStore: ObservableObject {
    static let delayStep: Double = 0.1
    static let finiteDelayMin: Double = 0.1
    static let finiteDelayMax: Double = 3.0
    static let neverHideDelay: Double = -1.0
    static let neverWakeDelay: Double = 999.0
    static let sliderIndexMax = 31
    // nonisolated: it must be referenced from snapDelay's default argument (a nonisolated evaluation context).
    nonisolated static let defaultNativeDockAutoHideDelay: Double = 1.0
    /// **NeoBar's own tier on a fresh install: always shown** (decided by the owner 2026-09-01; before that it was auto-hide with a 0.1s wake).
    /// Used only in the one place, `register`.
    ///
    /// ⚠️ **This and the one below are two constants and must never be merged.** This one is "what a first install looks like",
    /// the one below is "which tier to use when auto-hide is on" -- the latter must be a **finite value**, since two fallbacks depend on it:
    /// the remembered value must not be `-1` (otherwise ⌥⇧⌘D switching away from always-shown stays always-shown and the shortcut becomes a no-op),
    /// and the non-finite fallback of `snapDelay` must not be `-1` either (otherwise NaN would be interpreted as the "always shown" sentinel).
    nonisolated static let firstRunEdgeAutoHideDelay: Double = AppSettingsStore.neverHideDelay
    /// Default tier when auto-hide is **on**, and also the fallback for remembered and non-finite values. See the ⚠️ above.
    nonisolated static let defaultEnabledEdgeAutoHideDelay: Double = 0.1

    @Published private(set) var launchAtLogin: Bool
    /// Whether the shelf shows at the head of the pinned-folder zone. When turned off it is no longer rendered; staged files are unaffected.
    @Published private(set) var showShelf: Bool
    @Published private(set) var showTrash: Bool
    /// Front-window bar: the running dot under the card whose window is in front stretches into a
    /// short bar (`FrontWindowIndicatorDecision`). Off by default for everyone (owner 2026-10-16),
    /// so it sits in `register(defaults:)` like the other plain toggles — no fresh-install seed.
    @Published private(set) var frontWindowBar: Bool
    /// Task strip size tier. Panel geometry and all chip sizes inside the strip derive from it.
    @Published private(set) var dockPanelHeight: DockPanelHeight
    /// Hover effect tier. Affects only the hover visuals of chips in the strip; the resting layout is pixel-identical (so no relayout is needed).
    @Published private(set) var hoverStyle: HoverStyle
    /// Maximized windows avoid the task strip (menu "Maximized windows avoid the task strip").
    /// **Seeded on for fresh installs, kept off for existing users** (owner 2026-09-01; previously off for everyone) --
    /// it pairs with "task strip always shown by default" decided in the same round: always-shown covers the bottom edge of maximized windows, and avoidance fills exactly that gap.
    /// But this feature really rewrites **other apps'** window sizes, so it can't be turned on for existing users just because of an upgrade;
    /// seeding goes through `seedWindowLiftEnabledForFreshInstall()`; see the comment there.
    @Published private(set) var windowLiftEnabled: Bool
    /// Predictively hide the task strip before the standard green button / Control-Command-F input is delivered; on by default.
    @Published private(set) var fullscreenIntentEnabled: Bool
    /// Custom show/hide task strip shortcut; nil = default ⌥⇧⌘D. **Written only by `SettingsCoordinator.applyEdgeToggleShortcut`
    /// after registration succeeds** -- persisting first and then failing to register would split the stored key from the key actually in effect.
    @Published private(set) var edgeToggleShortcut: StoredHotKeyShortcut?
    /// See `AppearanceMode`. Missing or unrecognised stored value = `system`.
    @Published private(set) var appearanceMode: AppearanceMode
    /// Globally reverse the mouse wheel (discrete wheels only; trackpad / Magic Mouse untouched). **Default off** --
    /// the ability to rewrite system-wide input events must be an explicit user choice, same reasoning as `windowLiftEnabled`.
    @Published private(set) var scrollReverserEnabled: Bool
    /// Task strip display position. Default `.followMouse` = current behavior (stays on the bottom edge, switching screens); `.pinned` pins to a given screen.
    @Published private(set) var taskbarScreenPlacement: TaskbarScreenPlacement
    /// This machine has already seen the first-run welcome guide (the screen suggesting hiding the system Dock).
    /// A one-time display state, unrelated to "whether it was actually hidden" -- a user who clicked "Later" also counts as having seen it,
    /// so we don't pester again; anyone who wants to change it uses the system Dock slider in the status-bar menu.
    @Published private(set) var hasSeenWelcome: Bool
    @Published private(set) var nativeDockAutoHideDelay: Double
    @Published private(set) var edgeAutoHideDelay: Double
    /// The delay value to return to when the "auto-hide" toggle (menu / global shortcut) restores from always-shown.
    /// Only finite tiers (0.1...3.0) or no-wake (999) are allowed, never always-shown (-1) itself.
    private(set) var lastEnabledEdgeAutoHideDelay: Double
    /// The system Dock group's mirrored remembered value, same rules as above (the fallback default tier is 1.0).
    private(set) var lastEnabledNativeDockAutoHideDelay: Double

    var nativeDockAutoHideEnabled: Bool { nativeDockAutoHideDelay != Self.neverHideDelay }
    var edgeAutoHideEnabled: Bool { edgeAutoHideDelay != Self.neverHideDelay }
    var taskbarPerDisplaySeedPending: Bool {
        defaults.bool(forKey: Keys.taskbarScreenPerDisplaySeedPending)
    }
    var hasStoredTaskbarScreenChoice: Bool {
        defaults.object(forKey: Keys.taskbarScreenMode) != nil
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        Self.migrateLegacyEnabledKey(
            defaults: defaults,
            enabledKey: Keys.nativeDockAutoHideEnabled,
            delayKey: Keys.nativeDockAutoHideDelay
        )
        Self.migrateLegacyEnabledKey(
            defaults: defaults,
            enabledKey: Keys.edgeAutoHideEnabled,
            delayKey: Keys.edgeAutoHideDelay
        )
        // The remembered key (lastEnabledDelay) registers no default: it distinguishes "never written" from "actually written";
        // when never written, the seeding logic below decides, rather than silently getting a fake history value from a registered default.
        defaults.register(defaults: [
            Keys.launchAtLogin: false,
            Keys.showShelf: true,
            Keys.showTrash: true,
            Keys.frontWindowBar: false,
            Keys.fullscreenIntentEnabled: true,
            Keys.nativeDockAutoHideDelay: Self.defaultNativeDockAutoHideDelay,
            // First install = always shown; the remembered seed is still a finite tier, see the constant's comment.
            Keys.edgeAutoHideDelay: Self.firstRunEdgeAutoHideDelay,
        ])

        launchAtLogin = defaults.bool(forKey: Keys.launchAtLogin)
        showShelf = defaults.bool(forKey: Keys.showShelf)
        showTrash = defaults.bool(forKey: Keys.showTrash)
        frontWindowBar = defaults.bool(forKey: Keys.frontWindowBar)
        // Deliberately **not** in the register above: missing key means false = existing users stay off.
        // On a fresh install, `seedWindowLiftEnabledForFreshInstall()` explicitly writes true --
        // registering a true would turn it on for **all** existing users who never touched this switch, and this feature
        // rewrites other apps' window sizes, so it can't take effect silently through an upgrade.
        windowLiftEnabled = defaults.bool(forKey: Keys.windowLiftEnabled)
        // Likewise deliberately not in register: missing key means false = never subscribed yet.
        // Same as above: missing key means false = welcome guide not yet seen.
        hasSeenWelcome = defaults.bool(forKey: Keys.hasSeenWelcome)
        fullscreenIntentEnabled = defaults.bool(forKey: Keys.fullscreenIntentEnabled)
        // Deliberately not registered: missing key means nil = default ⌥⇧⌘D; corrupt data (hand-edited, wrong type) also falls back to nil.
        edgeToggleShortcut = Self.storedHotKeyShortcut(defaults.dictionary(forKey: Keys.edgeToggleShortcut))
        // Likewise deliberately not registered: missing key means false, which is exactly "off by default"; registering a false would be misread as default on.
        scrollReverserEnabled = defaults.bool(forKey: Keys.scrollReverserEnabled)
        // Read only, never written back here: a missing key keeps meaning "follow the system".
        appearanceMode = AppearanceMode(rawValue: defaults.string(forKey: Keys.appearance) ?? "") ?? .default
        // Deliberately not registered: missing key means followMouse = current behavior, so existing users notice nothing on upgrade.
        let pinnedSelection = Self.storedPinnedScreenSelection(
            defaults.dictionary(forKey: Keys.taskbarScreenPinned)
        )
        switch defaults.string(forKey: Keys.taskbarScreenMode) {
        case nil, TaskbarScreenMode.followMouse.rawValue:
            taskbarScreenPlacement = .followMouse
        case TaskbarScreenMode.allScreens.rawValue:
            taskbarScreenPlacement = .allScreens
        case TaskbarScreenMode.allScreensPerDisplay.rawValue:
            taskbarScreenPlacement = .allScreensPerDisplay
        case TaskbarScreenMode.pinned.rawValue:
            if let pinnedSelection {
                taskbarScreenPlacement = .pinned(pinnedSelection)
            } else {
                // pinned but the selection is missing/corrupt -> fall back and immediately rewrite the mode key (consistent with the convention for dockPanelHeight: corrupt value = rewrite)
                taskbarScreenPlacement = .followMouse
                defaults.set(TaskbarScreenMode.followMouse.rawValue, forKey: Keys.taskbarScreenMode)
            }
        default:
            // Unknown string (a new tier from a future version read by an older version) -> run as followMouse but **don't rewrite the key**,
            // so a downgrade doesn't destroy the choice the user made in the newer version.
            taskbarScreenPlacement = .followMouse
        }
        // Bar height: the new key wins; a user upgrading from the four-tier releases carries only
        // the legacy `dockSize` string, which is mapped once (the legacy key is read here and
        // never written or removed, so a rollback still finds it). Corrupt values fall back to
        // the native height and are rewritten immediately, like every other key here.
        dockPanelHeight = Self.storedDockPanelHeight(defaults: defaults)
        hoverStyle = HoverStyle(rawValue: defaults.string(forKey: Keys.hoverStyle) ?? "") ?? .default
        let nativeDelay = Self.sanitizedStoredDelay(
            defaults.object(forKey: Keys.nativeDockAutoHideDelay),
            fallback: Self.defaultNativeDockAutoHideDelay
        )
        nativeDockAutoHideDelay = nativeDelay
        if nativeDelay == Self.neverHideDelay {
            lastEnabledNativeDockAutoHideDelay = Self.sanitizedLastEnabledDelay(
                Self.storedNumericValue(defaults.object(forKey: Keys.nativeDockAutoHideLastEnabledDelay)),
                fallback: Self.defaultNativeDockAutoHideDelay
            )
        } else {
            lastEnabledNativeDockAutoHideDelay = nativeDelay
        }
        let edgeDelay = Self.sanitizedStoredDelay(
            defaults.object(forKey: Keys.edgeAutoHideDelay),
            fallback: Self.defaultEnabledEdgeAutoHideDelay
        )
        edgeAutoHideDelay = edgeDelay
        if edgeDelay == Self.neverHideDelay {
            lastEnabledEdgeAutoHideDelay = Self.sanitizedLastEnabledDelay(
                Self.storedNumericValue(defaults.object(forKey: Keys.edgeAutoHideLastEnabledDelay)),
                fallback: Self.defaultEnabledEdgeAutoHideDelay
            )
        } else {
            lastEnabledEdgeAutoHideDelay = edgeDelay
        }
        defaults.set(Double(dockPanelHeight.points), forKey: Keys.dockPanelHeight)
        defaults.set(hoverStyle.rawValue, forKey: Keys.hoverStyle)
        defaults.set(nativeDelay, forKey: Keys.nativeDockAutoHideDelay)
        defaults.set(lastEnabledNativeDockAutoHideDelay, forKey: Keys.nativeDockAutoHideLastEnabledDelay)
        defaults.set(edgeDelay, forKey: Keys.edgeAutoHideDelay)
        defaults.set(lastEnabledEdgeAutoHideDelay, forKey: Keys.edgeAutoHideLastEnabledDelay)
    }

    /// Called on every accepted tick of a height drag (the drag decision already dedupes to
    /// whole points, so a tick that changes nothing never reaches the publisher or the disk).
    func setDockPanelHeight(_ value: DockPanelHeight) {
        guard dockPanelHeight != value else { return }
        dockPanelHeight = value
        defaults.set(Double(value.points), forKey: Keys.dockPanelHeight)
    }

    /// Should be called only by `SettingsCoordinator.applyEdgeToggleShortcut` **after registration succeeds** (see the property comment).
    func setEdgeToggleShortcut(_ value: StoredHotKeyShortcut?) {
        guard edgeToggleShortcut != value else { return }
        edgeToggleShortcut = value
        guard let value else {
            defaults.removeObject(forKey: Keys.edgeToggleShortcut)
            return
        }
        defaults.set(
            [
                "keyCode": Int(value.keyCode),
                "modifiers": Int(value.carbonModifiers),
                "glyphs": value.glyphs,
            ],
            forKey: Keys.edgeToggleShortcut
        )
    }

    func setAppearanceMode(_ value: AppearanceMode) {
        guard appearanceMode != value else { return }
        appearanceMode = value
        defaults.set(value.rawValue, forKey: Keys.appearance)
    }

    func setScrollReverserEnabled(_ value: Bool) {
        guard scrollReverserEnabled != value else { return }
        scrollReverserEnabled = value
        defaults.set(value, forKey: Keys.scrollReverserEnabled)
    }

    func setTaskbarScreenPlacement(_ value: TaskbarScreenPlacement) {
        consumeTaskbarPerDisplaySeedIfPresent()
        guard taskbarScreenPlacement != value else { return }
        taskbarScreenPlacement = value
        defaults.set(value.mode.rawValue, forKey: Keys.taskbarScreenMode)
        if let selection = value.pinnedSelection {
            defaults.set(
                ["uuid": selection.uuid, "name": selection.name],
                forKey: Keys.taskbarScreenPinned
            )
        }
        // Switching back to followMouse **keeps** the pinned dictionary rather than deleting it (the remembered convention,
        // in the spirit of lastEnabledEdgeAutoHideDelay: switching back to pinned still remembers the screen picked last time).
    }

    /// Only a genuinely fresh install may arm this; the store's own init never creates the key.
    func armTaskbarPerDisplaySeedForFreshInstall(lineage: InstallLineage) {
        guard lineage == .pristine,
              defaults.object(forKey: Keys.taskbarScreenPerDisplaySeedPending) == nil
        else { return }
        defaults.set(true, forKey: Keys.taskbarScreenPerDisplaySeedPending)
    }

    func applyTaskbarPerDisplaySeed() {
        setTaskbarScreenPlacement(.allScreensPerDisplay)
    }

    func consumeTaskbarPerDisplaySeedIfPresent() {
        guard defaults.object(forKey: Keys.taskbarScreenPerDisplaySeedPending) != nil,
              defaults.bool(forKey: Keys.taskbarScreenPerDisplaySeedPending)
        else { return }
        defaults.set(false, forKey: Keys.taskbarScreenPerDisplaySeedPending)
    }

    private static func storedPinnedScreenSelection(_ dict: [String: Any]?) -> PinnedScreenSelection? {
        guard let dict,
              let uuid = dict["uuid"] as? String, !uuid.isEmpty,
              let name = dict["name"] as? String
        else { return nil }
        return PinnedScreenSelection(uuid: uuid, name: name)
    }

    private static func storedHotKeyShortcut(_ dict: [String: Any]?) -> StoredHotKeyShortcut? {
        guard let dict,
              let keyCode = dict["keyCode"] as? Int, keyCode >= 0, keyCode <= 0xFFFF,
              let modifiers = dict["modifiers"] as? Int, modifiers >= 0,
              let glyphs = dict["glyphs"] as? String, !glyphs.isEmpty
        else { return nil }
        return StoredHotKeyShortcut(
            keyCode: UInt32(keyCode),
            carbonModifiers: UInt32(modifiers),
            glyphs: glyphs
        )
    }

    func setHoverStyle(_ value: HoverStyle) {
        guard hoverStyle != value else { return }
        hoverStyle = value
        defaults.set(value.rawValue, forKey: Keys.hoverStyle)
    }

    func setShowShelf(_ value: Bool) {
        guard showShelf != value else { return }
        showShelf = value
        defaults.set(value, forKey: Keys.showShelf)
    }

    func setShowTrash(_ value: Bool) {
        guard showTrash != value else { return }
        showTrash = value
        defaults.set(value, forKey: Keys.showTrash)
    }

    func setFrontWindowBar(_ value: Bool) {
        guard frontWindowBar != value else { return }
        frontWindowBar = value
        defaults.set(value, forKey: Keys.frontWindowBar)
    }

    /// Seeds "lift maximized windows clear of the taskbar" to on for a fresh install (owner 2026-09-01).
    ///
    /// **Only `AppDelegate` may call this, once.** The verdict is `InstallLineage`: a snapshot of the
    /// persistent domain taken at the very start of the process, where an empty domain means a fresh
    /// install. ⚠️ What is load-bearing is *where* that snapshot is taken — `AppDelegate.installLineage`
    /// must be that type's **first stored property**, because this store and its siblings write defaults
    /// inside their own inits, so a snapshot taken one step later is guaranteed to be non-empty. This has
    /// **nothing** to do with the ordering against `recordFirstLaunchIfNeeded()`; that was the old,
    /// now-retired verdict.
    ///
    /// Getting the order wrong fails in the safe direction: a non-empty domain reads as `.priorUse` and
    /// nothing is seeded, so the feature goes silently dead for fresh installs rather than flipping an
    /// existing user. That is why there is **no assertion** here — 71 tests construct this type directly,
    /// and a process-level assert would abort the whole test run on the first one.
    ///
    /// An existing key means the user chose, even if they chose off: always respected, never overwritten.
    func seedWindowLiftEnabledForFreshInstall(lineage: InstallLineage) {
        guard lineage == .pristine else { return }
        guard defaults.object(forKey: Keys.windowLiftEnabled) == nil else { return }
        setWindowLiftEnabled(true)
    }

    func setWindowLiftEnabled(_ value: Bool) {
        guard windowLiftEnabled != value else { return }
        windowLiftEnabled = value
        defaults.set(value, forKey: Keys.windowLiftEnabled)
    }

    func setHasSeenWelcome(_ value: Bool) {
        guard hasSeenWelcome != value else { return }
        hasSeenWelcome = value
        defaults.set(value, forKey: Keys.hasSeenWelcome)
    }

    func setFullscreenIntentEnabled(_ value: Bool) {
        guard fullscreenIntentEnabled != value else { return }
        fullscreenIntentEnabled = value
        defaults.set(value, forKey: Keys.fullscreenIntentEnabled)
    }

    func setLaunchAtLogin(_ value: Bool) {
        guard launchAtLogin != value else { return }
        launchAtLogin = value
        defaults.set(value, forKey: Keys.launchAtLogin)
    }

    func setNativeDockAutoHideDelay(_ value: Double) {
        guard value.isFinite else { return }
        let snapped = Self.snapDelay(value, fallbackForNonFinite: Self.defaultNativeDockAutoHideDelay)
        // The remembered sync comes before the active dedupe: remembered must be corrected even when active is unchanged.
        if snapped != Self.neverHideDelay, lastEnabledNativeDockAutoHideDelay != snapped {
            lastEnabledNativeDockAutoHideDelay = snapped
            defaults.set(snapped, forKey: Keys.nativeDockAutoHideLastEnabledDelay)
        }
        guard nativeDockAutoHideDelay != snapped else { return }
        nativeDockAutoHideDelay = snapped
        defaults.set(snapped, forKey: Keys.nativeDockAutoHideDelay)
    }

    // The system Dock group deliberately provides no blind-flip toggle method: the system state can be changed externally (⌥⌘D / System Settings),
    // and blindly flipping the locally stored value flips the wrong way when the two drift apart. The menu's show/hide command was deleted on 2026-08-01,
    // and the whole group is now expressed by the slider + confirm row, leaving the flipping to the system's own ⌥⌘D.
    //
    // So `lastEnabledNativeDockAutoHideDelay` currently has **no reader** (only that command used it to
    // restore "the last tier"): the slider carries its own position and needs no memory. The field and its persistence are kept -- it is user data,
    // deleting the key would be a lossy migration, and it is needed again if the command ever returns. This is not a missed read.

    func setEdgeAutoHideDelay(_ value: Double) {
        guard value.isFinite else { return }
        let snapped = Self.snapDelay(value, fallbackForNonFinite: Self.defaultEnabledEdgeAutoHideDelay)
        // The remembered sync comes before the active dedupe: remembered must be corrected even when active is unchanged.
        if snapped != Self.neverHideDelay, lastEnabledEdgeAutoHideDelay != snapped {
            lastEnabledEdgeAutoHideDelay = snapped
            defaults.set(snapped, forKey: Keys.edgeAutoHideLastEnabledDelay)
        }
        guard edgeAutoHideDelay != snapped else { return }
        edgeAutoHideDelay = snapped
        defaults.set(snapped, forKey: Keys.edgeAutoHideDelay)
    }

    /// NeoBar's "auto-hide" toggle: always shown <-> the last delay (including no-wake 999).
    /// The name avoids "Now" -- switching to the auto-hide side doesn't hide immediately; it still follows the original idle timer and mouse checks.
    func toggleEdgeAutoHideMode() {
        if edgeAutoHideDelay == Self.neverHideDelay {
            setEdgeAutoHideDelay(lastEnabledEdgeAutoHideDelay)
        } else {
            setEdgeAutoHideDelay(Self.neverHideDelay)
        }
    }

    static func delayFromSliderIndex(_ index: Int) -> Double {
        let clamped = min(max(index, 0), sliderIndexMax)
        switch clamped {
        case 0:
            return neverHideDelay
        case sliderIndexMax:
            return neverWakeDelay
        case sliderIndexMax - 1:
            return finiteDelayMax
        default:
            return ((finiteDelayMin + Double(clamped - 1) * delayStep) * 10).rounded() / 10
        }
    }

    static func sliderIndexFromDelay(_ value: Double) -> Int {
        guard value > neverHideDelay else { return 0 }
        guard value < neverWakeDelay else { return sliderIndexMax }
        let clamped = min(max(value, finiteDelayMin), finiteDelayMax)
        return Int(((clamped - finiteDelayMin) / delayStep).rounded()) + 1
    }

    static func snapDelay(_ value: Double, fallbackForNonFinite fallback: Double = AppSettingsStore.defaultEnabledEdgeAutoHideDelay) -> Double {
        // NaN/±inf leaking into the Int(...) conversion below would crash directly (all NaN comparisons are false, so clamp has no effect).
        guard value.isFinite else { return fallback }
        if value <= neverHideDelay { return neverHideDelay }
        if value >= neverWakeDelay { return neverWakeDelay }
        let clamped = min(max(value, finiteDelayMin), finiteDelayMax)
        return delayFromSliderIndex(Int(((clamped - finiteDelayMin) / delayStep).rounded()) + 1)
    }

    /// Entry point for reading UserDefaults' active delay. Accepts only real numeric objects; strings, booleans and non-finite values
    /// all fall back to the group's default tier, so that `double(forKey:)` doesn't silently turn a bad type into 0.0.
    static func sanitizedStoredDelay(_ value: Any?, fallback: Double) -> Double {
        guard let value = storedNumericValue(value) else { return fallback }
        return snapDelay(value, fallbackForNonFinite: fallback)
    }

    /// Defensive funnel for remembered values: missing, wrong type, non-finite, or snapping to always-shown all fall back to the default tier
    /// (edge group 0.1, system Dock group 1.0).
    static func sanitizedLastEnabledDelay(_ value: Double?, fallback: Double = AppSettingsStore.defaultEnabledEdgeAutoHideDelay) -> Double {
        guard let value, value.isFinite else { return fallback }
        let snapped = snapDelay(value, fallbackForNonFinite: fallback)
        return snapped == neverHideDelay ? fallback : snapped
    }

    private static func storedNumericValue(_ value: Any?) -> Double? {
        DefaultsValueParsing.finiteNumericValue(value)
    }

    private static func storedDockPanelHeight(defaults: UserDefaults) -> DockPanelHeight {
        if let stored = storedNumericValue(defaults.object(forKey: Keys.dockPanelHeight)) {
            return DockPanelHeight(clamping: CGFloat(stored))
        }
        if let legacy = defaults.string(forKey: Keys.dockSize),
           let migrated = DockPanelHeight.migratingLegacyTier(rawValue: legacy) {
            return migrated
        }
        return .default
    }

    private static func migrateLegacyEnabledKey(defaults: UserDefaults, enabledKey: String, delayKey: String) {
        if let storedEnabled = defaults.object(forKey: enabledKey) as? Bool, storedEnabled == false {
            defaults.set(neverHideDelay, forKey: delayKey)
        }
        defaults.removeObject(forKey: enabledKey)
    }
}

private enum Keys {
    static let launchAtLogin = "app.neobar.launchAtLogin"
    static let showShelf = "app.neobar.showShelf"
    // Never read the retired app.neobar.trash.visible key.
    static let showTrash = "app.neobar.showTrash"
    static let frontWindowBar = "app.neobar.frontWindowBar"
    /// Continuous bar height in points (since the drag-to-resize release).
    static let dockPanelHeight = "app.neobar.dockPanelHeight"
    /// Legacy four-tier raw string. **Read once for migration, never written or removed.**
    static let dockSize = "app.neobar.dockSize"
    static let hoverStyle = "app.neobar.hoverStyle"
    /// system / light / dark. Missing key = system.
    /// The pre-glass `app.neobar.appearanceMode` is an orphan and stays one: never read,
    /// written or removed — a choice made for that older look is not carried over.
    static let appearance = "app.neobar.appearance"
    static let windowLiftEnabled = "app.neobar.windowLiftEnabled"
    static let fullscreenIntentEnabled = "app.neobar.fullscreenIntentEnabled"
    /// Custom show/hide shortcut (dictionary: keyCode / modifiers / glyphs). Missing key = default ⌥⇧⌘D.
    static let edgeToggleShortcut = "app.neobar.hotKey.edgeAutoHideMode"
    static let scrollReverserEnabled = "app.neobar.scrollReverserEnabled"
    /// Task strip display position (followMouse / pinned / allScreens / allScreensPerDisplay). Missing key = followMouse.
    /// ⚠️ The old `app.neobar.displayMode` (the early "single/multi screen" tier, removed along with the feature) is an orphan key,
    /// **never read again** (`Docs/05`) -- the new feature recognizes only the two keys below.
    static let taskbarScreenMode = "app.neobar.taskbarScreen.mode"
    /// Pinned screen identity (dictionary: uuid / name). Kept, not deleted, when switching back to followMouse.
    static let taskbarScreenPinned = "app.neobar.taskbarScreen.pinned"
    /// A fresh install waiting to first see multiple displays. Missing key = existing user,
    /// false = already consumed.
    static let taskbarScreenPerDisplaySeedPending = "app.neobar.taskbarScreen.perDisplaySeedPending"
    /// ⚠️ This key name is on users' disks. Renaming = everyone already subscribed sees the subscription block again.
    /// ⚠️ Same as above: renaming = every existing user is intercepted by the welcome guide once more on next launch.
    static let hasSeenWelcome = "app.neobar.hasSeenWelcome"
    static let nativeDockAutoHideEnabled = "app.neobar.autoHide.nativeDock.enabled"
    static let nativeDockAutoHideDelay = "app.neobar.autoHide.nativeDock.delay"
    static let nativeDockAutoHideLastEnabledDelay = "app.neobar.autoHide.nativeDock.lastEnabledDelay"
    static let edgeAutoHideEnabled = "app.neobar.autoHide.edge.enabled"
    static let edgeAutoHideDelay = "app.neobar.autoHide.edge.delay"
    static let edgeAutoHideLastEnabledDelay = "app.neobar.autoHide.edge.lastEnabledDelay"
}
