import Carbon.HIToolbox
import XCTest

/// Scriptable Carbon stand-in: records the call order and simulates install/registration failures and event sequences.
private final class FakeHotKeyBackend: HotKeyBackend {
    var installStatus: OSStatus = noErr
    var registerStatus: OSStatus = noErr
    private(set) var onEvent: ((HotKeyEvent) -> Bool)?
    private(set) var calls: [String] = []
    private(set) var registeredKeyCode: UInt32?
    private(set) var registeredModifiers: UInt32?
    private(set) var registeredHotKeyID: EventHotKeyID?
    private(set) var registeredExclusive: Bool?

    func installHandler(onEvent: @escaping (HotKeyEvent) -> Bool) -> OSStatus {
        calls.append("install")
        if installStatus == noErr { self.onEvent = onEvent }
        return installStatus
    }

    /// One-shot result queue (update's "new key fails, rollback to old key succeeds" needs a separate result for each of two register calls);
    /// when the queue is empty it falls back to the standing registerStatus.
    var registerStatusQueue: [OSStatus] = []

    func register(keyCode: UInt32, modifiers: UInt32, hotKeyID: EventHotKeyID, exclusive: Bool) -> OSStatus {
        calls.append("register")
        registeredKeyCode = keyCode
        registeredModifiers = modifiers
        registeredHotKeyID = hotKeyID
        registeredExclusive = exclusive
        if !registerStatusQueue.isEmpty { return registerStatusQueue.removeFirst() }
        return registerStatus
    }

    func unregister() { calls.append("unregister") }

    func removeHandler() {
        calls.append("removeHandler")
        onEvent = nil
    }

    func send(_ event: HotKeyEvent) -> Bool { onEvent?(event) ?? false }
}

@MainActor
final class GlobalHotKeyMonitorTests: XCTestCase {
    private let shortcut = GlobalHotKeyShortcut.edgeAutoHideMode

    func testStartInstallsThenRegistersWithShortcutIdentity() {
        let backend = FakeHotKeyBackend()
        let monitor = GlobalHotKeyMonitor(shortcut: shortcut, backend: backend) {}

        XCTAssertEqual(monitor.start(), .registered)
        XCTAssertTrue(monitor.isRegistered)
        XCTAssertEqual(backend.calls, ["install", "register"])
        XCTAssertEqual(backend.registeredKeyCode, UInt32(kVK_ANSI_D))
        XCTAssertEqual(backend.registeredModifiers, UInt32(optionKey | shiftKey | cmdKey))
        XCTAssertEqual(backend.registeredHotKeyID?.signature, shortcut.signature)
        XCTAssertEqual(backend.registeredHotKeyID?.id, shortcut.id)
        XCTAssertEqual(backend.registeredExclusive, true, "独占注册是被锁住的行为：组合键被他人持有时必须确定性失败")
    }

    func testStartAfterDeliberateStopReRegistersForReal() {
        let backend = FakeHotKeyBackend()
        let monitor = GlobalHotKeyMonitor(shortcut: shortcut, backend: backend) {}

        XCTAssertEqual(monitor.start(), .registered)
        monitor.stop()
        XCTAssertFalse(monitor.isRegistered)

        // After an explicit stop, start must truly re-register; it cannot misreport using the cached .registered.
        XCTAssertEqual(monitor.start(), .registered)
        XCTAssertTrue(monitor.isRegistered)
        XCTAssertEqual(backend.calls, ["install", "register", "unregister", "removeHandler", "install", "register"])
    }

    func testHandlerInstallFailureDoesNotAttemptRegistration() {
        let backend = FakeHotKeyBackend()
        backend.installStatus = OSStatus(paramErr)
        let monitor = GlobalHotKeyMonitor(shortcut: shortcut, backend: backend) {}

        XCTAssertEqual(monitor.start(), .handlerInstallFailed(OSStatus(paramErr)))
        XCTAssertFalse(monitor.isRegistered)
        XCTAssertEqual(backend.calls, ["install"])
    }

    func testRegistrationFailureRollsBackInstalledHandler() {
        let backend = FakeHotKeyBackend()
        backend.registerStatus = OSStatus(eventHotKeyExistsErr)
        let monitor = GlobalHotKeyMonitor(shortcut: shortcut, backend: backend) {}

        XCTAssertEqual(monitor.start(), .registrationFailed(OSStatus(eventHotKeyExistsErr)))
        XCTAssertFalse(monitor.isRegistered)
        XCTAssertEqual(backend.calls, ["install", "register", "removeHandler"])
    }

    func testSecondStartReturnsCachedStatusWithoutRetry() {
        let backend = FakeHotKeyBackend()
        backend.registerStatus = OSStatus(eventHotKeyExistsErr)
        let monitor = GlobalHotKeyMonitor(shortcut: shortcut, backend: backend) {}

        _ = monitor.start()
        let callsAfterFirst = backend.calls

        XCTAssertEqual(monitor.start(), .registrationFailed(OSStatus(eventHotKeyExistsErr)))
        XCTAssertEqual(backend.calls, callsAfterFirst)
    }

    func testStopUnregistersBeforeRemovingHandlerAndIsIdempotent() {
        let backend = FakeHotKeyBackend()
        let monitor = GlobalHotKeyMonitor(shortcut: shortcut, backend: backend) {}
        _ = monitor.start()

        monitor.stop()

        XCTAssertFalse(monitor.isRegistered)
        XCTAssertEqual(backend.calls, ["install", "register", "unregister", "removeHandler"])

        monitor.stop()
        XCTAssertEqual(backend.calls, ["install", "register", "unregister", "removeHandler"])
    }

    func testStopWithoutSuccessfulStartTouchesNothing() {
        let backend = FakeHotKeyBackend()
        backend.installStatus = OSStatus(paramErr)
        let monitor = GlobalHotKeyMonitor(shortcut: shortcut, backend: backend) {}
        _ = monitor.start()

        monitor.stop()

        XCTAssertEqual(backend.calls, ["install"])
    }

    func testPressedFiresOnceUntilReleasedClearsGate() {
        let backend = FakeHotKeyBackend()
        var fired = 0
        let monitor = GlobalHotKeyMonitor(shortcut: shortcut, backend: backend) { fired += 1 }
        _ = monitor.start()

        XCTAssertTrue(backend.send(.pressed(signature: shortcut.signature, id: shortcut.id)))
        // System key repeat: a key that is ours must be swallowed (handled), but not call back again.
        XCTAssertTrue(backend.send(.pressed(signature: shortcut.signature, id: shortcut.id)))
        drainMainQueue()
        XCTAssertEqual(fired, 1)

        XCTAssertTrue(backend.send(.released(signature: shortcut.signature, id: shortcut.id)))
        XCTAssertTrue(backend.send(.pressed(signature: shortcut.signature, id: shortcut.id)))
        drainMainQueue()
        XCTAssertEqual(fired, 2)
        _ = monitor
    }

    func testEventsWithWrongIdentityAreNotHandled() {
        let backend = FakeHotKeyBackend()
        var fired = 0
        let monitor = GlobalHotKeyMonitor(shortcut: shortcut, backend: backend) { fired += 1 }
        _ = monitor.start()

        XCTAssertFalse(backend.send(.pressed(signature: 0x1111_1111, id: shortcut.id)))
        XCTAssertFalse(backend.send(.pressed(signature: shortcut.signature, id: shortcut.id &+ 7)))
        XCTAssertFalse(backend.send(.released(signature: 0x1111_1111, id: shortcut.id)))
        drainMainQueue()
        XCTAssertEqual(fired, 0)
        _ = monitor
    }

    func testCallbackQueuedBeforeStopIsDropped() {
        let backend = FakeHotKeyBackend()
        var fired = 0
        let monitor = GlobalHotKeyMonitor(shortcut: shortcut, backend: backend) { fired += 1 }
        _ = monitor.start()

        XCTAssertTrue(backend.send(.pressed(signature: shortcut.signature, id: shortcut.id)))
        monitor.stop()
        drainMainQueue()

        XCTAssertEqual(fired, 0)
    }

    func testCallbackFromPreviousRegistrationIsDroppedAfterStopAndRestart() {
        let backend = FakeHotKeyBackend()
        var fired = 0
        let monitor = GlobalHotKeyMonitor(shortcut: shortcut, backend: backend) { fired += 1 }
        XCTAssertEqual(monitor.start(), .registered)

        XCTAssertTrue(backend.send(.pressed(signature: shortcut.signature, id: shortcut.id)))
        monitor.stop()
        XCTAssertEqual(monitor.start(), .registered)
        drainMainQueue()

        XCTAssertEqual(fired, 0, "旧注册排队的 pressed 不能借新注册状态触发")

        XCTAssertTrue(backend.send(.pressed(signature: shortcut.signature, id: shortcut.id)))
        drainMainQueue()
        XCTAssertEqual(fired, 1)
        XCTAssertTrue(backend.send(.released(signature: shortcut.signature, id: shortcut.id)))
    }

    private var customShortcut: GlobalHotKeyShortcut {
        GlobalHotKeyShortcut(stored: StoredHotKeyShortcut(
            keyCode: 40, // kVK_ANSI_K
            carbonModifiers: UInt32(controlKey | cmdKey),
            glyphs: "⌃⌘K"
        ))
    }

    func testUpdateStopsOldThenRegistersNewShortcut() {
        let backend = FakeHotKeyBackend()
        let monitor = GlobalHotKeyMonitor(shortcut: shortcut, backend: backend) {}
        _ = monitor.start()

        let next = customShortcut
        XCTAssertEqual(monitor.update(shortcut: next), .registered)
        XCTAssertTrue(monitor.isRegistered)
        XCTAssertEqual(monitor.shortcut, next)
        XCTAssertEqual(backend.calls, ["install", "register", "unregister", "removeHandler", "install", "register"])
        XCTAssertEqual(backend.registeredKeyCode, 40)
        XCTAssertEqual(backend.registeredModifiers, UInt32(controlKey | cmdKey))
        XCTAssertEqual(backend.registeredHotKeyID?.signature, shortcut.signature, "换键不换身份：signature/id 不变")
        XCTAssertEqual(backend.registeredHotKeyID?.id, shortcut.id)
    }

    func testUpdateFailureRevertsToPreviousShortcut() {
        let backend = FakeHotKeyBackend()
        let monitor = GlobalHotKeyMonitor(shortcut: shortcut, backend: backend) {}
        _ = monitor.start()

        // The new key's registration fails (taken by someone else); on rollback the old key must be re-registered and succeed.
        backend.registerStatusQueue = [OSStatus(eventHotKeyExistsErr)]
        XCTAssertEqual(monitor.update(shortcut: customShortcut), .registrationFailed(OSStatus(eventHotKeyExistsErr)))
        XCTAssertTrue(monitor.isRegistered, "回退后旧键重新生效")
        XCTAssertEqual(monitor.shortcut, shortcut)
        XCTAssertEqual(backend.registeredKeyCode, shortcut.keyCode, "最后一次注册的是旧键")
    }

    func testUpdateDropsPressQueuedUnderOldRegistration() {
        let backend = FakeHotKeyBackend()
        var fired = 0
        let monitor = GlobalHotKeyMonitor(shortcut: shortcut, backend: backend) { fired += 1 }
        _ = monitor.start()

        XCTAssertTrue(backend.send(.pressed(signature: shortcut.signature, id: shortcut.id)))
        _ = monitor.update(shortcut: customShortcut)
        drainMainQueue()

        XCTAssertEqual(fired, 0, "旧注册排队的 pressed 不能借新注册状态触发")
    }

    private func drainMainQueue() {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1.0)
    }
}
