import AppKit
import Carbon.HIToolbox

/// Global hotkey definition. keyCode + Carbon modifier bits are used for registration; `displayGlyphs` is for display only,
/// frozen at the moment of recording with no reverse lookup from keyCode (reason in `HotKeyGlyphs`).
struct GlobalHotKeyShortcut: Equatable {
    let keyCode: UInt32
    let carbonModifiers: UInt32
    /// Display glyphs (e.g. "⌥⇧⌘D"), shared by the menu group title and the settings window.
    let displayGlyphs: String
    let signature: OSType
    let id: UInt32

    var hotKeyID: EventHotKeyID { EventHotKeyID(signature: signature, id: id) }

    /// Default ⌥⇧⌘D: the system Dock's ⌥⌘D plus Shift, freeing the original ⌥⌘E for Safari / Finder.
    /// Four keys is slightly heavy, but this is a low-frequency mode switch; the combination still avoids VoiceOver's Control+Option,
    /// and also avoids plain Option / Option+Shift, which are known to be broken on macOS 15 (FB15168205).
    /// Since 2026-08-24 the user can change the key, and the same pitfalls are blocked at the recording entry by `HotKeyShortcutValidation`.
    static let edgeAutoHideMode = GlobalHotKeyShortcut(
        keyCode: UInt32(kVK_ANSI_D),
        carbonModifiers: UInt32(optionKey | shiftKey | cmdKey),
        displayGlyphs: "⌥⇧⌘D",
        signature: 0x5467_4567, // 'TgEg'
        id: 1
    )

    // ⌥⌘D (the system Dock's own auto-hide shortcut) is **deliberately not defined here**: macOS itself holds it,
    // and registering it would be stealing. An exact definition used to be kept for menu display and key dedup; after the system Dock's
    // show/hide command was removed on 2026-08-01 both consumers were gone; the menu now mentions ⌥⌘D only as plain text in the group title.
    // The custom rebinding path also rejects this combination via `HotKeyShortcutValidation`.
}

extension GlobalHotKeyShortcut {
    /// User-customized combination -> definition for registration. The signature/id **do not change**: the hotkey's identity is "NeoBar's resident toggle key",
    /// and the key binding is merely its parameter. Callback matching and press dedup both go by signature/id, so changing the key does not change the identity.
    init(stored: StoredHotKeyShortcut) {
        self.init(
            keyCode: stored.keyCode,
            carbonModifiers: stored.carbonModifiers,
            displayGlyphs: stored.glyphs,
            signature: Self.edgeAutoHideMode.signature,
            id: Self.edgeAutoHideMode.id
        )
    }
}

/// Hotkey event, already unwrapped to plain values by the backend, convenient for constructing in unit tests.
enum HotKeyEvent: Equatable {
    case pressed(signature: OSType, id: UInt32)
    case released(signature: OSType, id: UInt32)
}

/// Injectable abstraction over Carbon calls: unit tests use a fake to simulate install/register failures and event sequences.
/// Convention: all methods are called on the main thread only; onEvent returning true means the event has been handled.
protocol HotKeyBackend: AnyObject {
    func installHandler(onEvent: @escaping (HotKeyEvent) -> Bool) -> OSStatus
    /// exclusive goes through the interface explicitly: exclusive registration (deterministic failure when the combination is held by someone else) is behavior locked by tests, not an implementation detail.
    func register(keyCode: UInt32, modifiers: UInt32, hotKeyID: EventHotKeyID, exclusive: Bool) -> OSStatus
    func unregister()
    func removeHandler()
}

/// Lifecycle management for one global hotkey. Carbon RegisterEventHotKey was chosen over an NSEvent global keyboard monitor:
/// it is notified only when a registered combination hits and does not touch other keys; dispatch is system-level and does not depend on this app being frontmost.
/// Hard constraint: onPressed may only do lightweight state toggling and must not synchronously read cross-app AX/CG inventories or export snapshots.
@MainActor
final class GlobalHotKeyMonitor {
    enum RegistrationStatus: Equatable {
        case registered
        case handlerInstallFailed(OSStatus)
        case registrationFailed(OSStatus)

        /// Fallback failure value handed to `SettingsCoordinator` when "this instance has no hotkey monitor at all" (a temporary DMG copy).
        static let monitorUnavailable = RegistrationStatus.registrationFailed(OSStatus(paramErr))
    }

    private(set) var shortcut: GlobalHotKeyShortcut
    private let backend: HotKeyBackend
    private let onPressed: () -> Void
    private(set) var isRegistered = false
    /// Press-release gate: swallows the consecutive pressed events the system produces from key repeat while the key is held down.
    private var isPressedDown = false
    /// Every successful registration advances the generation, so a callback queued on the main queue by the previous round cannot fire wrongly after stop/start.
    private var registrationGeneration: UInt64 = 0
    /// Attempted only once per instance; repeated start() returns the previous result, and this launch does not retry automatically.
    private var attemptedStatus: RegistrationStatus?

    init(shortcut: GlobalHotKeyShortcut,
         backend: HotKeyBackend = CarbonHotKeyBackend(),
         onPressed: @escaping () -> Void) {
        self.shortcut = shortcut
        self.backend = backend
        self.onPressed = onPressed
    }

    deinit {
        MainActor.assumeIsolated { stop() }
    }

    @discardableResult
    func start() -> RegistrationStatus {
        if let attemptedStatus { return attemptedStatus }

        let installStatus = backend.installHandler { [weak self] event in
            self?.handle(event) ?? false
        }
        guard installStatus == noErr else {
            let status = RegistrationStatus.handlerInstallFailed(installStatus)
            attemptedStatus = status
            return status
        }

        let registerStatus = backend.register(
            keyCode: shortcut.keyCode,
            modifiers: shortcut.carbonModifiers,
            hotKeyID: shortcut.hotKeyID,
            exclusive: true
        )
        guard registerStatus == noErr else {
            // On registration failure roll back the handler already installed, leaving no half-finished state.
            backend.removeHandler()
            let status = RegistrationStatus.registrationFailed(registerStatus)
            attemptedStatus = status
            return status
        }

        isRegistered = true
        registrationGeneration &+= 1
        attemptedStatus = .registered
        return .registered
    }

    func stop() {
        // First mark inactive and clear the press gate, then unregister the hotkey and remove the handler; safe to call repeatedly.
        let wasRegistered = isRegistered
        isRegistered = false
        isPressedDown = false
        guard wasRegistered else { return }
        backend.unregister()
        backend.removeHandler()
        // An instance that was stopped deliberately may start again (a real re-registration), otherwise the cached .registered would misreport.
        // A failure result is still cached: "this launch does not retry automatically" applies only to failures.
        attemptedStatus = nil
    }

    /// Change the key: stop the old one, register the new one; if registering the new key fails, switch back to the old key as-is and register it again. Returns the registration result of the **new key**.
    ///
    /// `stop()` clears the attempt cache only when "it had registered successfully", so both places must clear it explicitly once more:
    /// if the cache from a previously failed round were left, `start()` here would misreport using the stale result.
    /// When `start()` succeeds it advances `registrationGeneration`, so callbacks queued by the old registration are naturally voided.
    @discardableResult
    func update(shortcut next: GlobalHotKeyShortcut) -> RegistrationStatus {
        let previous = shortcut
        stop()
        attemptedStatus = nil
        shortcut = next
        let status = start()
        guard status != .registered else { return status }
        stop()
        attemptedStatus = nil
        shortcut = previous
        _ = start()
        return status
    }

    fileprivate func handle(_ event: HotKeyEvent) -> Bool {
        guard isRegistered else { return false }
        switch event {
        case .pressed(let signature, let id):
            guard signature == shortcut.signature, id == shortcut.id else { return false }
            // A repeated pressed while already in the pressed state: it belongs to our key; swallow it without calling back again.
            guard !isPressedDown else { return true }
            isPressedDown = true
            let queuedGeneration = registrationGeneration
            DispatchQueue.main.async { [weak self] in
                // A queued callback belongs only to the registration lifecycle that captured it; stop/start changes the generation.
                guard let self,
                      self.isRegistered,
                      self.registrationGeneration == queuedGeneration else { return }
                self.onPressed()
            }
            return true
        case .released(let signature, let id):
            guard signature == shortcut.signature, id == shortcut.id else { return false }
            isPressedDown = false
            return true
        }
    }
}

/// Production implementation: real Carbon calls. Hotkey events are delivered by the system to the application event target (main-thread run loop).
final class CarbonHotKeyBackend: HotKeyBackend {
    private var handlerRef: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?
    fileprivate var onEvent: ((HotKeyEvent) -> Bool)?

    func installHandler(onEvent: @escaping (HotKeyEvent) -> Bool) -> OSStatus {
        guard handlerRef == nil else { return OSStatus(paramErr) }
        self.onEvent = onEvent
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        var installed: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            carbonHotKeyEventCallback,
            eventTypes.count,
            &eventTypes,
            Unmanaged.passUnretained(self).toOpaque(),
            &installed
        )
        if status == noErr {
            handlerRef = installed
        } else {
            self.onEvent = nil
        }
        return status
    }

    func register(keyCode: UInt32, modifiers: UInt32, hotKeyID: EventHotKeyID, exclusive: Bool) -> OSStatus {
        guard hotKeyRef == nil else { return OSStatus(paramErr) }
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            exclusive ? OptionBits(kEventHotKeyExclusive) : 0,
            &ref
        )
        if status == noErr { hotKeyRef = ref }
        return status
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }

    func removeHandler() {
        if let handlerRef { RemoveEventHandler(handlerRef) }
        handlerRef = nil
        onEvent = nil
    }
}

/// Carbon C callback: unwrap the event kind and EventHotKeyID and forward to backend.onEvent;
/// when unwrapping fails, the event is unknown, or onEvent decides it is not ours, hand it back to the system (eventNotHandledErr).
private let carbonHotKeyEventCallback: EventHandlerUPP = { _, eventRef, userData in
    guard let eventRef, let userData else { return OSStatus(eventNotHandledErr) }

    var hotKeyID = EventHotKeyID()
    let paramStatus = GetEventParameter(
        eventRef,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard paramStatus == noErr else { return OSStatus(eventNotHandledErr) }

    let event: HotKeyEvent
    switch Int(GetEventKind(eventRef)) {
    case kEventHotKeyPressed:
        event = .pressed(signature: hotKeyID.signature, id: hotKeyID.id)
    case kEventHotKeyReleased:
        event = .released(signature: hotKeyID.signature, id: hotKeyID.id)
    default:
        return OSStatus(eventNotHandledErr)
    }

    let backend = Unmanaged<CarbonHotKeyBackend>.fromOpaque(userData).takeUnretainedValue()
    let handled = backend.onEvent?(event) ?? false
    return handled ? noErr : OSStatus(eventNotHandledErr)
}
