import AppKit
@preconcurrency import ApplicationServices
import Foundation

/// Observes geometry changes for only the active app's focused window.
/// AX reads used to retarget the focused element stay off the main thread.
@MainActor
final class FrontmostWindowGeometryObserver {
    enum Event {
        case focusedWindowChanged
        case windowCreated
        case geometryChanged
        case windowDestroyed
    }

    var onEvent: ((Event) -> Void)?

    private var observer: AXObserver?
    private var appElement: AXUIElement?
    private var focusedElement: AXUIElement?
    private var activePID: pid_t?
    private var observationGeneration: UInt64 = 0
    private var refreshTask: Task<Void, Never>?
    private var needsTrailingRefresh = false

    /// AXObserverAddNotification / RemoveNotification are cross-process mach round-trips: they block
    /// the caller until the *observed* app answers. Registration used to run on the main thread, and
    /// on an app switch (restoring a minimized window activates its app) it hit the app while it was
    /// still busy finishing the un-minimize — parking the main thread ~300–400ms, so a chip's
    /// press-release could not paint until the window's flight ended (owner 2026-09-13). Only the
    /// blocking add/remove IPC moves here; observer creation, the run-loop source, and all `@MainActor`
    /// bookkeeping stay on main. Serial so per-observer registration order is preserved (a remove of
    /// the old focused element always precedes the add of the new one). Callbacks are unaffected — they
    /// still fire on the main run loop via the observer's run-loop source. A late registration is
    /// covered by window-lift's activation scan + 1s idle fallback.
    nonisolated private static let registrationQueue = DispatchQueue(
        label: "app.neobar.NeoBar.frontmost-ax-registration"
    )

    deinit {
        MainActor.assumeIsolated { stop() }
    }

    func start(pid: pid_t?) {
        activate(pid: pid)
    }

    func activate(pid: pid_t?) {
        if activePID == pid, observer != nil {
            requestFocusedRefresh()
            return
        }

        stopObservation()
        activePID = pid
        observationGeneration &+= 1
        guard let pid else { return }

        var newObserver: AXObserver?
        guard AXObserverCreate(pid, Self.callback, &newObserver) == .success,
              let newObserver else { return }

        let app = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetMessagingTimeout(app, 0.1)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        // App-level registration IPC off the main thread (see `registrationQueue`). The run-loop
        // source is added on main *first* so callbacks are wired before the notifications land.
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(newObserver),
            .commonModes
        )
        Self.registrationQueue.async {
            AXObserverAddNotification(
                newObserver,
                app,
                kAXFocusedWindowChangedNotification as CFString,
                refcon
            )
            AXObserverAddNotification(
                newObserver,
                app,
                kAXWindowCreatedNotification as CFString,
                refcon
            )
        }
        observer = newObserver
        appElement = app
        requestFocusedRefresh()
    }

    func stop() {
        activePID = nil
        observationGeneration &+= 1
        refreshTask?.cancel()
        refreshTask = nil
        needsTrailingRefresh = false
        stopObservation()
        onEvent = nil
    }

    private func stopObservation() {
        // Dropping the AXObserver removes *every* notification registered on it — the
        // app-level ones (focused-window-changed / window-created) and the focused-element
        // ones (moved / resized / destroyed) alike — so there is no need to first call the
        // synchronous per-element AXObserverRemoveNotification here.
        //
        // That explicit teardown is a cross-process mach_msg to the element of the *previous*
        // frontmost app. During an app switch — exactly what restoring a minimized window
        // triggers (NSWorkspace.didActivateApplication → activate(pid:) → stopObservation) —
        // the previous app is busy and the call parks the main thread ~300–400ms. Long enough
        // that a chip's press-release animation cannot paint until the un-minimize flight ends,
        // which reads as "the button only springs back once the window has flown out"
        // (owner 2026-09-13, only on restore-from-minimized, never on minimize). The app-level
        // notifications were already relying on observer-drop cleanup; the focused element now
        // does the same. Callers that keep the observer alive still use unregisterFocusedElement.
        if let observer {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(observer),
                .commonModes
            )
        }
        observer = nil
        appElement = nil
        focusedElement = nil
    }

    private func requestFocusedRefresh() {
        guard let pid = activePID else { return }
        guard refreshTask == nil else {
            needsTrailingRefresh = true
            return
        }

        let generation = observationGeneration
        refreshTask = Task.detached { [weak self] in
            let element = Self.readFocusedWindow(pid: pid)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                self?.finishFocusedRefresh(
                    element,
                    pid: pid,
                    generation: generation
                )
            }
        }
    }

    private func finishFocusedRefresh(
        _ element: AXUIElement?,
        pid: pid_t,
        generation: UInt64
    ) {
        refreshTask = nil
        guard activePID == pid, observationGeneration == generation else {
            if needsTrailingRefresh {
                needsTrailingRefresh = false
                requestFocusedRefresh()
            }
            return
        }

        if let element {
            registerFocusedElement(element)
            // Activation/window-created can arrive before the new window finishes settling.
            // Once the focused element is readable and bound, request one final coalesced scan.
            onEvent?(.focusedWindowChanged)
        } else {
            unregisterFocusedElement(observer: observer)
        }

        if needsTrailingRefresh {
            needsTrailingRefresh = false
            requestFocusedRefresh()
        }
    }

    private func registerFocusedElement(_ element: AXUIElement) {
        guard let observer else { return }
        if let focusedElement, CFEqual(focusedElement, element) { return }

        unregisterFocusedElement(observer: observer)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        // Element-level registration IPC off the main thread (see `registrationQueue`).
        Self.registrationQueue.async {
            AXObserverAddNotification(
                observer,
                element,
                kAXWindowMovedNotification as CFString,
                refcon
            )
            AXObserverAddNotification(
                observer,
                element,
                kAXWindowResizedNotification as CFString,
                refcon
            )
            AXObserverAddNotification(
                observer,
                element,
                kAXUIElementDestroyedNotification as CFString,
                refcon
            )
        }
        focusedElement = element
    }

    private func unregisterFocusedElement(observer: AXObserver?) {
        guard let observer, let focusedElement else {
            self.focusedElement = nil
            return
        }
        // De-registration IPC off the main thread (see `registrationQueue`); capture the element by
        // value so the queued work removes the right one even after `focusedElement` is reassigned.
        let element = focusedElement
        Self.registrationQueue.async {
            AXObserverRemoveNotification(
                observer,
                element,
                kAXWindowMovedNotification as CFString
            )
            AXObserverRemoveNotification(
                observer,
                element,
                kAXWindowResizedNotification as CFString
            )
            AXObserverRemoveNotification(
                observer,
                element,
                kAXUIElementDestroyedNotification as CFString
            )
        }
        self.focusedElement = nil
    }

    private func handleNotification(_ notification: CFString) {
        let name = notification as String
        if name == (kAXFocusedWindowChangedNotification as String) {
            onEvent?(.focusedWindowChanged)
            requestFocusedRefresh()
        } else if name == (kAXWindowCreatedNotification as String) {
            onEvent?(.windowCreated)
            requestFocusedRefresh()
        } else if name == (kAXWindowMovedNotification as String)
            || name == (kAXWindowResizedNotification as String) {
            onEvent?(.geometryChanged)
        } else if name == (kAXUIElementDestroyedNotification as String) {
            onEvent?(.windowDestroyed)
            unregisterFocusedElement(observer: observer)
            requestFocusedRefresh()
        }
    }

    nonisolated private static func readFocusedWindow(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetMessagingTimeout(app, 0.1)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            app,
            kAXFocusedWindowAttribute as CFString,
            &value
        ) == .success,
        let value,
        // The type of a cross-process AX return value is decided by the other process; a buggy app may return a different CF type.
        // A forced cast there would trap and crash the whole taskbar, so check the type first, then cast.
        CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static let callback: AXObserverCallback = { _, _, notification, refcon in
        guard let refcon else { return }
        let monitor = Unmanaged<FrontmostWindowGeometryObserver>
            .fromOpaque(refcon)
            .takeUnretainedValue()
        MainActor.assumeIsolated {
            monitor.handleNotification(notification)
        }
    }
}
