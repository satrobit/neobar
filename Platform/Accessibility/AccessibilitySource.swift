import AppKit
import ApplicationServices
import Foundation
import OSLog

final class AccessibilitySource {
    private static let logger = Logger(
        subsystem: DockWindowEligibilityPolicy.selfBundleIdentifier,
        category: "WindowFiltering"
    )

    private let reader = AXWindowReader()
    private let eligibilityPolicy = DockWindowEligibilityPolicy()
    private var previousWindowKindsBySignature: [String: SystemObservation.ObservationKind] = [:]
    private var previousObservationsBySignature: [String: SystemObservation] = [:]
    private var previousHiddenSignatures: Set<String> = []

    func observe() -> [SystemObservation] {
        guard AXIsProcessTrusted() else { return [] }
        let now = Date()

        let apps = Array(NSWorkspace.shared.runningApplications.filter {
            !$0.isTerminated
                && $0.activationPolicy != .prohibited
                && FinderWindowRules.isFinder(bundleIdentifier: $0.bundleIdentifier) == false
        })
        let scannedPIDs = Set(apps.map(\.processIdentifier))

        var observations: [SystemObservation] = []
        var currentHiddenSignatures: Set<String> = []

        for app in apps {
            let appObservations = observeWindows(for: app, now: now)
            observations.append(contentsOf: appObservations)

            for observation in appObservations {
                if observation.kind == .hidden {
                    currentHiddenSignatures.insert(observationSignature(observation))
                }
            }
        }

        var nextKindsBySignature: [String: SystemObservation.ObservationKind] = [:]
        var nextObservationsBySignature: [String: SystemObservation] = [:]
        for observation in observations {
            let signature = observationSignature(observation)
            nextKindsBySignature[signature] = ObservationKindMergeRule.preferred(
                nextKindsBySignature[signature],
                observation.kind
            )
            nextObservationsBySignature[signature] = observation
        }

        for (signature, previous) in previousObservationsBySignature
            where nextObservationsBySignature[signature] == nil && scannedPIDs.contains(previous.pid) {
            observations.append(
                SystemObservation(
                    timestamp: now,
                    kind: .disappeared,
                    source: previous.source,
                    pid: previous.pid,
                    bundleIdentifier: previous.bundleIdentifier,
                    cgWindowID: previous.cgWindowID,
                    title: previous.title,
                    appName: previous.appName,
                    bounds: previous.bounds,
                    isMinimized: previous.isMinimized,
                    isFocusedWindow: false
                )
            )
        }

        previousWindowKindsBySignature = nextKindsBySignature
        previousObservationsBySignature = nextObservationsBySignature
        previousHiddenSignatures = currentHiddenSignatures
        return observations
    }

    private func observeWindows(for app: NSRunningApplication, now: Date) -> [SystemObservation] {
        let isAppHidden = app.isHidden

        return reader.windows(for: app).compactMap { window in
            let title = window.title
            guard title != nil else { return nil }
            let axDecision = AXTaskbarWindowRules.decision(
                role: window.role,
                subrole: window.subrole,
                bounds: window.bounds
            )
            guard axDecision.isAccepted else { return nil }
            logUnconfirmedWindowIfNeeded(axDecision, window: window, app: app)

            let decision = eligibilityPolicy.evaluate(
                DockWindowEligibilityPolicy.Candidate(
                    bundleIdentifier: app.bundleIdentifier,
                    appName: app.localizedName ?? "",
                    title: title,
                    subrole: window.subrole,
                    bounds: window.bounds,
                    alpha: nil,
                    activationPolicy: app.activationPolicy,
                    executablePath: app.executableURL?.path
                )
            )
            guard decision == .keep else { return nil }

            let baseObservation = SystemObservation(
                timestamp: now,
                kind: .unchanged,
                source: .accessibility,
                pid: app.processIdentifier,
                bundleIdentifier: app.bundleIdentifier,
                cgWindowID: window.cgWindowID,
                title: title,
                appName: app.localizedName,
                bounds: window.bounds,
                isMinimized: window.isMinimized,
                isFocusedWindow: window.isFocusedWindow
            )
            let signature = observationSignature(baseObservation)
            let previousKind = previousWindowKindsBySignature[signature]
            let wasHidden = previousHiddenSignatures.contains(signature)
            let kind: SystemObservation.ObservationKind

            if window.isMinimized {
                kind = .minimized
            } else if isAppHidden {
                kind = .hidden
            } else if wasHidden || previousKind == .hidden {
                kind = .unhidden
            } else {
                kind = .unchanged
            }

            return SystemObservation(
                timestamp: now,
                kind: kind,
                source: .accessibility,
                pid: app.processIdentifier,
                bundleIdentifier: app.bundleIdentifier,
                cgWindowID: window.cgWindowID,
                title: title,
                appName: app.localizedName,
                bounds: window.bounds,
                isMinimized: window.isMinimized,
                isFocusedWindow: window.isFocusedWindow
            )
        }
    }

    private func logUnconfirmedWindowIfNeeded(
        _ decision: AXTaskbarWindowRules.Decision,
        window: AXWindowSnapshot,
        app: NSRunningApplication
    ) {
        guard decision == .unconfirmedMainWindow else { return }
        Self.logger.debug(
            "Admitting AXWindow with missing subrole app=\(app.localizedName ?? "", privacy: .public) bundle=\(app.bundleIdentifier ?? "", privacy: .public) title=\(window.title ?? "", privacy: .public)"
        )
    }

    private func observationSignature(_ observation: SystemObservation) -> String {
        let title = observation.title?.lowercased() ?? "<untitled>"
        let frame = observation.bounds.map {
            "\($0.origin.x.rounded()):\($0.origin.y.rounded()):\($0.width.rounded()):\($0.height.rounded())"
        } ?? "<unknown>"
        return "\(observation.pid)|\(title)|\(frame)"
    }
}

struct AccessibilityWindowActionExecutor {
    private let reader: AXWindowReader
    private let chipProbeEnabled: Bool
    private static let chipProbeLogger = Logger(subsystem: "app.neobar.NeoBar", category: "ChipProbe")

    init(reader: AXWindowReader = AXWindowReader(), chipProbeEnabled: Bool = false) {
        self.reader = reader
        self.chipProbeEnabled = chipProbeEnabled
    }

    struct ActionExecution {
        let success: Bool
        let mechanism: String
        let verifiedMinimized: Bool?
    }

    struct WindowTarget {
        let pid: Int32
        let title: String?
        let bounds: CGRect?
    }

    struct WindowHandle {
        let pid: Int32
        let title: String?
        let bounds: CGRect?
        fileprivate let element: AXUIElement
    }

    /// The fastest tier: use the AX element that `AppTracker` stored during inventory (`AXElementCache`), spending only one
    /// `_AXUIElementGetWindow` to verify it still points at the expected window, with a 50ms budget.
    ///
    /// Why it deserves its own tier: the existing fast path asks `AXFocusedWindow` -> `AXMainWindow` -> the full
    /// `AXWindows` in turn, and **a minimized window is neither focused nor main**, so it inevitably reaches the last step; and apps with
    /// minimized windows are often napping, so this whole sequence can eat the 100ms budget before falling to the 500ms slow path. The cache tier brings it down to <=50ms.
    func captureHandleFromCache(
        _ cgWindowID: CGWindowID,
        pid: Int32,
        title: String?,
        bounds: CGRect?
    ) -> WindowHandle? {
        guard let element = AXElementCache.shared.element(pid: pid, cgWindowID: cgWindowID) else {
            return nil
        }
        switch reader.matchesCGWindowID(cgWindowID, element: element, messagingTimeout: 0.05) {
        case .some(true):
            // Fill title / bounds from snapshot values, same as `fastHandle`; never pass nil through (passing nil makes the later
            // recapture's bestMatch necessarily return nil for any app with >=2 windows, silently disabling the rescue path).
            return WindowHandle(pid: pid, title: title, bounds: bounds, element: element)
        case .some(false):
            // Read succeeded but the window has changed (cgWindowID reuse): this cache entry must be invalidated.
            AXElementCache.shared.remove(pid: pid, cgWindowID: cgWindowID)
            return nil
        case .none:
            // Unreadable != stale. Keep the cache; this time fall back to the existing capture chain.
            return nil
        }
    }

    func captureHandleByCGWindowID(
        _ cgWindowID: CGWindowID,
        pid: Int32,
        title: String?,
        bounds: CGRect?
    ) -> WindowHandle? {
        guard let handle = reader.captureHandle(
            forPID: pid,
            cgWindowID: cgWindowID,
            messagingTimeout: 0.1
        ) else { return nil }
        return Self.fastHandle(
            from: handle,
            target: WindowTarget(pid: pid, title: title, bounds: bounds)
        )
    }

    static func fastHandle(from handle: AXWindowHandle, target: WindowTarget) -> WindowHandle {
        return WindowHandle(
            pid: target.pid,
            title: target.title,
            bounds: target.bounds,
            element: handle.element
        )
    }

    func activateAppWithWindowRecovery(pid: Int32, runningApp: NSRunningApplication?) -> Bool {
        // Time-limited to 0.3s (2026-08-11). This used to go through `windows(forPID:)` with **no timeout**, which uses the system-default
        // AX timeout; on a napping app that is seconds, and this is the only path for an `app-*` card click while the user is waiting. If the read fails,
        // treat it as having no visible window and go straight to openApplication below to bring it up (behavior consistent with `.unread -> empty`).
        let liveWindows: [AXWindowSnapshot]
        switch reader.inventoryWindows(forPID: pid, messagingTimeout: 0.3) {
        case .success(let windows): liveWindows = windows
        case .unread: liveWindows = []
        }
        let visibleWindows = liveWindows.filter { !$0.isMinimized }

        if !visibleWindows.isEmpty {
            _ = AXUIElementPerformAction(visibleWindows[0].element, kAXRaiseAction as CFString)
            return runningApp?.activate(options: [.activateIgnoringOtherApps]) ?? false
        }

        guard let app = runningApp, let url = app.bundleURL else { return false }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config, completionHandler: nil)
        return true
    }

    func captureHandle(
        for target: WindowTarget,
        attempts: Int = 1,
        retryIntervalMicroseconds: useconds_t = 0
    ) -> WindowHandle? {
        guard let handle = reader.captureHandle(
            for: AXWindowTarget(pid: target.pid, title: target.title, bounds: target.bounds),
            attempts: attempts,
            retryIntervalMicroseconds: retryIntervalMicroseconds,
            messagingTimeout: 0.5
        ) else {
            return nil
        }
        return WindowHandle(
            pid: target.pid,
            title: handle.title,
            bounds: handle.bounds,
            element: handle.element
        )
    }

    func minimize(_ handle: WindowHandle) -> ActionExecution {
        if chipProbeEnabled {
            // Read-only survey, intentionally absent from the default click path.
            let role = reader.stringAttribute(kAXRoleAttribute as CFString, from: handle.element, maxAttempts: 1)
            let subrole = reader.stringAttribute(kAXSubroleAttribute as CFString, from: handle.element, maxAttempts: 1)
            let hasMinimizeButton = axElementAttribute(kAXMinimizeButtonAttribute as CFString, from: handle.element) != nil
            let currentMinimized = reader.boolAttribute(kAXMinimizedAttribute as CFString, from: handle.element, maxAttempts: 1)
            var minimizedSettable: DarwinBoolean = false
            _ = AXUIElementIsAttributeSettable(handle.element, kAXMinimizedAttribute as CFString, &minimizedSettable)
            let probeApp = NSRunningApplication(processIdentifier: handle.pid)
            let probePolicyStr: String
            switch probeApp?.activationPolicy {
            case .regular: probePolicyStr = "regular"
            case .accessory: probePolicyStr = "accessory"
            case .prohibited: probePolicyStr = "prohibited"
            default: probePolicyStr = "nil"
            }
            Self.chipProbeLogger.info("minimize-ax-probe app=\(probeApp?.localizedName ?? "(unknown)", privacy: .public) bundleID=\(probeApp?.bundleIdentifier ?? "(none)", privacy: .public) activationPolicy=\(probePolicyStr, privacy: .public) role=\(role ?? "nil", privacy: .public) subrole=\(subrole ?? "nil", privacy: .public) hasMinimizeButton=\(hasMinimizeButton, privacy: .public) currentMinimized=\(String(describing: currentMinimized), privacy: .public) minimizedSettable=\(minimizedSettable.boolValue, privacy: .public)")
        }

        if setMinimized(true, for: handle) {
            let verified = reader.boolAttribute(kAXMinimizedAttribute as CFString, from: handle.element)
            if verified == true {
                return ActionExecution(
                    success: true,
                    mechanism: "set-minimized-attribute",
                    verifiedMinimized: verified
                )
            }
        }

        guard let button = axElementAttribute(kAXMinimizeButtonAttribute as CFString, from: handle.element) else {
            // No minimize button but the read-back is already collapsed (AXDialog-type windows, Release measurement 2026-08-26):
            // if the target state already holds it counts as success; reporting failure would make the optimistic state bounce back wrongly.
            let verified = reader.boolAttribute(kAXMinimizedAttribute as CFString, from: handle.element)
            return ActionExecution(
                success: verified == true,
                mechanism: "missing-minimize-button",
                verifiedMinimized: verified
            )
        }

        guard AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else {
            return ActionExecution(
                success: false,
                mechanism: "press-minimize-button-failed",
                verifiedMinimized: reader.boolAttribute(kAXMinimizedAttribute as CFString, from: handle.element)
            )
        }

        let verified = reader.boolAttribute(kAXMinimizedAttribute as CFString, from: handle.element)
        return ActionExecution(
            success: verified == true,
            mechanism: "press-minimize-button",
            verifiedMinimized: verified
        )
    }

    func restore(_ handle: WindowHandle) -> ActionExecution {
        if setMinimized(false, for: handle) {
            _ = AXUIElementPerformAction(handle.element, kAXRaiseAction as CFString)
            let verified = reader.boolAttribute(kAXMinimizedAttribute as CFString, from: handle.element)
            return ActionExecution(
                success: verified == false,
                mechanism: "clear-minimized-attribute",
                verifiedMinimized: verified
            )
        }

        guard let rebound = recapture(from: handle) else {
            return ActionExecution(
                success: false,
                mechanism: "recapture-for-restore-failed",
                verifiedMinimized: nil
            )
        }
        guard setMinimized(false, for: rebound) else {
            return ActionExecution(
                success: false,
                mechanism: "clear-minimized-after-recapture-failed",
                verifiedMinimized: reader.boolAttribute(kAXMinimizedAttribute as CFString, from: rebound.element)
            )
        }
        _ = AXUIElementPerformAction(rebound.element, kAXRaiseAction as CFString)
        let verified = reader.boolAttribute(kAXMinimizedAttribute as CFString, from: rebound.element)
        return ActionExecution(
            success: verified == false,
            mechanism: "clear-minimized-after-recapture",
            verifiedMinimized: verified
        )
    }

    func activate(_ handle: WindowHandle) -> Bool {
        activate(handle, requiresFocusedConfirmation: false)
    }

    func activate(
        _ handle: WindowHandle,
        requiresFocusedConfirmation: Bool,
        confirmationTimeout: TimeInterval = 0.6,
        pollIntervalMicroseconds: useconds_t = 100_000,
        knownCGWindowID: CGWindowID? = nil,
        knownMinimized: Bool = false,
        preActivateForRestore: Bool = false,
        awaitOnScreenBeforeFocus: Bool = false
    ) -> Bool {
        let runningApp = NSRunningApplication(processIdentifier: handle.pid)
        // `knownMinimized` comes from the snapshot and is used only as an **affirmative** fast path (2026-08-11): if the snapshot says it is minimized, restore
        // directly, saving one AX round-trip to a napping app, which was the last wait in "clicking a minimized window is slowest".
        // The reverse **cannot** be used: when the snapshot says "not minimized" we must still read live, otherwise one stale snapshot would keep the window from coming back.
        // A wrong guess in that direction is harmless too: writing `minimized = false` to a window that is not actually minimized is a no-op.
        if knownMinimized || reader.boolAttribute(kAXMinimizedAttribute as CFString, from: handle.element) == true {
            // R2 order (2026-08-22 matrix): when there are no non-minimized siblings, switch frontmost first and follow within microseconds with the restore.
            // AppKit makes the restored window key in-process, and the traffic lights are colored during the restore animation,
            // eliminating the "focus after the window appears" step (external events cannot enter the app's event queue during the animation;
            // matrix R0/R1/R3 proved re-sending ineffective; the only native-equivalent path is to let the app do it itself).
            // See MinimizedRestorePreActivation for the decision; with siblings, the original order below is used.
            if preActivateForRestore, let wid = knownCGWindowID {
                postSkyLightFrontSwitchOnly(pid: handle.pid, windowID: wid)
            }
            _ = setMinimized(false, for: handle)
            // Wait for return on screen (2026-08-25 midMin/midMinWait probe, prior-click path only): when unminimize lands in the
            // tail of the genie, the window has a ~40-100ms off-screen gap; if focus (including the frontmost switch) is handled inside that gap,
            // AppKit **persistently** promotes a visible sibling (Finder gap300 measured 1/3 hit: +381ms B2 over A1,
            // the damage persists after the target returns on screen); sending focus only after wid is back in the CG on-screen list, the dirty-config retest was clean 2/2,
            // usually waiting <=50ms (the wait length can be read from `total` in DOCK_CLICK_TRACE). The R2 pre-switch path and
            // ordinary restore (the target is stably off-screen, focus queues behind the restore animation tail, v3 measured 5/5) keep their original order untouched.
            if awaitOnScreenBeforeFocus, !preActivateForRestore, let wid = knownCGWindowID {
                waitForWindowOnScreen(wid)
            }
            // Restore -> switch must be back to back with zero AX queries in between (2026-07-05 probe v3): minimized restore does no early
            // focus; while B1 is still ordering out, any frontmost switch (including kCPSNoWindows, a bare psn switch
            // that sends no make-key) makes the app automatically promote the visible sibling B2 above the old frontmost A1 (a persistent z-order change).
            // The only clean path: right after unminimize, send a full SkyLight focus with the snapshot wid, so make-key
            // lands correctly on the just-restored B1; the gap is microseconds, the re-asserter sources (Ghostty/Chromium family
            // bounce back after ~450ms) cannot grab it in time, and the activation flash does not regress (500ms worst-case gap measured with no flash).
            if let wid = knownCGWindowID {
                postSkyLightWindowFocus(pid: handle.pid, windowID: wid)
            }
            // Right after restoring, key the app's internal focus back to this window (kAXMain = the standard AX channel for switching windows within an app).
            // A make-key sent to a "still minimized window" gets landed by the app on a visible sibling window; without correction,
            // keyboard input and the focused-window protection of "minimize back to the previous app" would both go wrong onto the sibling window
            // (2026-07-03 Chrome/Finder B1B2 measurement).
            AXUIElementSetAttributeValue(handle.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        }

        // Trial focus patch: target the concrete window first so standard app activation
        // does not briefly restore a sibling/previous key window over the requested one.
        // The order is fixed as "SkyLight first (raise + make-key down), then kAXRaiseAction", same order as AltTab,
        // verified by consecutive CLI switches (2026-08-22); raise is the piece that lets consecutive switches keep working, not optional.
        let focusedViaSkyLight = focusWindowViaSkyLight(pid: handle.pid, element: handle.element)
        let raised = AXUIElementPerformAction(handle.element, kAXRaiseAction as CFString) == .success
        if !focusedViaSkyLight, runningApp?.isActive != true {
            _ = runningApp?.activate(options: [.activateIgnoringOtherApps])
        }

        if requiresFocusedConfirmation {
            return confirmFocused(
                handle,
                timeout: confirmationTimeout,
                pollIntervalMicroseconds: pollIntervalMicroseconds
            )
        }

        return focusedViaSkyLight || raised || runningApp?.isActive == true
    }

    /// Wait for the window to return to the CG on-screen list (layer-0 onscreen). The first CG polling in Platform; semantics match
    /// the midMinWait variant of `scratch/minrestore_probe.swift` (the probe used a full-table contains; here a
    /// single-window query decides onscreen+layer0). 2ms step and 0.9s cap match the probe; on timeout it proceeds without blocking (repo-wide convention);
    /// runs only on the actionQueue background thread.
    @discardableResult
    private func waitForWindowOnScreen(_ windowID: CGWindowID, cap: TimeInterval = 0.9) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + cap
        repeat {
            if let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
               let info = list.first,
               (info[kCGWindowIsOnscreen as String] as? Bool) == true,
               (info[kCGWindowLayer as String] as? Int) == 0 {
                return true
            }
            usleep(2_000)
        } while ProcessInfo.processInfo.systemUptime < deadline
        return false
    }

    /// Finder answers every AX call with `cannotComplete` while its main thread sits in file
    /// coordination (a Trash count on a dead network mount: up to ~1s, `Docs/05`), and the handle's
    /// 100ms messaging timeout turns that into a silent no-op:
    /// the front was already handed off, the window stayed open. Only that error is retried, within
    /// a bounded budget; any other answer is final.
    func close(_ handle: WindowHandle) -> Bool {
        let deadline = Date().addingTimeInterval(0.6)
        var attempts = 0
        repeat {
            attempts += 1
            var raw: CFTypeRef?
            let readError = AXUIElementCopyAttributeValue(handle.element, kAXCloseButtonAttribute as CFString, &raw)
            if readError == .success, let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() {
                let pressError = AXUIElementPerformAction(raw as! AXUIElement, kAXPressAction as CFString)
                Self.chipProbeLogger.info("close-press pid=\(handle.pid, privacy: .public) error=\(pressError.rawValue, privacy: .public) attempt=\(attempts, privacy: .public)")
                if pressError == .success { return true }
                if pressError != .cannotComplete { return false }
            } else if readError != .cannotComplete {
                Self.chipProbeLogger.info("close-button-read failed pid=\(handle.pid, privacy: .public) error=\(readError.rawValue, privacy: .public)")
                return false
            }
            usleep(50_000)
        } while Date() < deadline
        Self.chipProbeLogger.info("close gave up pid=\(handle.pid, privacy: .public) attempts=\(attempts, privacy: .public)")
        return false
    }

    private func recapture(from handle: WindowHandle) -> WindowHandle? {
        captureHandle(
            for: WindowTarget(
                pid: handle.pid,
                title: handle.title,
                bounds: handle.bounds
            )
        )
    }

    private func confirmFocused(
        _ handle: WindowHandle,
        timeout: TimeInterval,
        pollIntervalMicroseconds: useconds_t
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if isFocused(handle) {
                return true
            }
            if let rebound = recapture(from: handle),
               isFocused(rebound) {
                return true
            }
            usleep(pollIntervalMicroseconds)
        } while Date() < deadline

        return false
    }

    private func isFocused(_ handle: WindowHandle) -> Bool {
        guard let focusedWindow = reader.focusedWindow(forPID: handle.pid) else {
            return false
        }
        return CFEqual(focusedWindow, handle.element)
    }

    /// Frontmost handoff before minimizing: decide who gets the frontmost (rules and reasons in `MinimizeHandoffTarget`).
    /// Two gates are kept: the target app must be frontmost and this window must be its focused window, so right-click minimizing a background sibling does not steal focus.
    /// The CG list takes only pid / wid / layer and **does not read `kCGWindowName`** (it needs the screen-recording permission, which the installed build lacks;
    /// a 2026-08-23 measurement showed the original title guard meant the handoff never took effect); candidate eligibility is decided by snapshot membership instead.
    func findBackgroundActivationTarget(
        for handle: WindowHandle,
        record: WindowRecord,
        snapshot: DockSnapshot,
        focusedReadBudget: TimeInterval = 0
    ) -> MinimizeHandoffTarget.Verdict {
        // isActive (live read) rather than NSWorkspace.frontmostApplication (lagging cache): within ~1.5s after SkyLight activation
        // reading the cache misjudges "app not frontmost", silently skipping the pre-switch -> macOS promotes a sibling window of the same app.
        guard NSRunningApplication(processIdentifier: handle.pid)?.isActive == true else { return .none }

        let appElement = AXUIElementCreateApplication(handle.pid)
        AXUIElementSetMessagingTimeout(appElement, 0.2)
        // Only `cannotComplete` (a busy app) is retried within the budget — a "no focused window"
        // answer is final, so a background sibling never waits here.
        let deadline = Date().addingTimeInterval(focusedReadBudget)
        var focused: AXUIElement?
        var readError = AXError.success
        repeat {
            var raw: CFTypeRef?
            readError = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &raw)
            if readError == .success, let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() {
                focused = (raw as! AXUIElement)
            }
            guard readError == .cannotComplete, Date() < deadline else { break }
            usleep(20_000)
        } while true
        guard let focused, CFEqual(focused, handle.element) else {
            Self.chipProbeLogger.info("postactivate-target focused-gate failed pid=\(handle.pid, privacy: .public) readError=\(readError.rawValue, privacy: .public)")
            return .none
        }

        let ourPID = pid_t(ProcessInfo.processInfo.processIdentifier)
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return .none }

        var zOrder: [MinimizeHandoffTarget.ZOrderedWindow] = []
        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t, ownerPID != ourPID else { continue }
            guard let wid = info[kCGWindowNumber as String] as? UInt32 else { continue }
            zOrder.append(.init(pid: ownerPID, cgWindowID: CGWindowID(wid)))
        }

        let verdict = MinimizeHandoffTarget.select(zOrder: zOrder, target: record, snapshot: snapshot)
        switch verdict {
        case .switchTo(let pid, let wid, let windowID):
            Self.chipProbeLogger.info(
                "postactivate-target candidate=\(NSRunningApplication(processIdentifier: pid)?.localizedName ?? "(unknown)", privacy: .public) pid=\(pid, privacy: .public) wid=\(wid, privacy: .public) windowID=\(windowID.rawValue, privacy: .public)"
            )
        case .siblingTakesOver(let windowID):
            Self.chipProbeLogger.info("postactivate-target sibling-takes-over pid=\(handle.pid, privacy: .public) windowID=\(windowID.rawValue, privacy: .public)")
        case .none:
            Self.chipProbeLogger.info("postactivate-target no-eligible-candidate pid=\(handle.pid, privacy: .public)")
        }
        return verdict
    }

    // MARK: - Front process and window-targeted focus helpers

    private typealias GetProcessForPIDFunc =
        @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

    private static let getProcessForPID: GetProcessForPIDFunc? = {
        let paths = [
            "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices",
            "/System/Library/Frameworks/CoreServices.framework/CoreServices"
        ]
        for path in paths {
            guard let handle = dlopen(path, RTLD_LAZY) else { continue }
            guard let get = dlsym(handle, "GetProcessForPID") else { continue }
            return unsafeBitCast(get, to: GetProcessForPIDFunc.self)
        }
        return nil
    }()

    /// Frontmost handoff before minimizing (M4, 2026-08-23 matrix 0/20 promotions): `_SLPSSetFrontProcessWithOptions`
    /// switches frontmost with `kCPSNoWindows`, **raising none of the handoff app's windows**, so the window being collapsed folds away normally from the top layer and the one
    /// beneath ends up frontmost naturally; then **wait for the target app itself to answer "not frontmost" via AX** (typically 9-13ms,
    /// cap 100ms) before minimizing. `NSRunningApplication.isActive` flips instantly and cannot serve as this gate:
    /// after it flips the target app may still not have finished deactivating, and minimizing then still lets AppKit promote a sibling (matrix M1/M2/M3
    /// each 1-3/10; with the AX gate, M4/M5 both 0/20). The old public API `SetFrontProcessWithOptions(FrontWindowOnly)`
    /// first raises the handoff window above the collapsing window, so the animation starts from behind someone else; deprecated.
    func switchFrontmostForHandoff(toPID pid: pid_t, windowID: CGWindowID, awaitingDeactivationOf targetPID: pid_t,
                                   deactivationCap: TimeInterval = 0.1) -> Bool {
        let route: String
        if postSkyLightFrontSwitchOnly(pid: pid, windowID: windowID, mode: Self.kCPSNoWindows) {
            route = "skylight"
        } else if activateApplicationViaAccessibility(pid: pid) {
            route = "ax-frontmost"
        } else {
            Self.chipProbeLogger.info("switch-frontmost-handoff unavailable pid=\(pid, privacy: .public)")
            return false
        }
        let targetApp = AXUIElementCreateApplication(targetPID)
        AXUIElementSetMessagingTimeout(targetApp, 0.05)
        let deadline = Date().addingTimeInterval(deactivationCap)
        var stillFrontmost: Bool? = true
        var lastAXError: Int32 = 0
        let waitStart = Date()
        repeat {
            var raw: CFTypeRef?
            let axError = AXUIElementCopyAttributeValue(targetApp, kAXFrontmostAttribute as CFString, &raw)
            if axError == .success {
                stillFrontmost = (raw as? NSNumber)?.boolValue
            } else {
                stillFrontmost = nil
                lastAXError = axError.rawValue
            }
            if stillFrontmost == false { break }
            usleep(2_000)
        } while Date() < deadline
        Self.chipProbeLogger.info("switch-frontmost-handoff pid=\(pid, privacy: .public) route=\(route, privacy: .public) targetStillFrontmost=\(String(describing: stillFrontmost), privacy: .public) axError=\(lastAXError, privacy: .public) waitMs=\(Int(Date().timeIntervalSince(waitStart) * 1000), privacy: .public)")
        return true
    }

    /// LaunchServices-free activation for the hand-off: `kAXFrontmostAttribute = true` on the
    /// target's application element still activates on macOS 26 (~110ms), unlike the window-level
    /// AX focus writes. It raises the target's key window before the switch lands, which is why it
    /// runs only when no process serial number can be resolved for the SkyLight route.
    private func activateApplicationViaAccessibility(pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        return AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue) == .success
    }

    private typealias SLPSSetFrontWindowFunc =
        @convention(c) (UnsafePointer<ProcessSerialNumber>, UInt32, UInt32) -> Int32
    private typealias SLPSPostEventFunc =
        @convention(c) (UnsafePointer<ProcessSerialNumber>, UnsafePointer<UInt8>) -> Int32

    private static let skyLightFocus: (slps: SLPSSetFrontWindowFunc, post: SLPSPostEventFunc)? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let slps = dlsym(handle, "_SLPSSetFrontProcessWithOptions"),
              let post = dlsym(handle, "SLPSPostEventRecordTo") else { return nil }
        return (
            unsafeBitCast(slps, to: SLPSSetFrontWindowFunc.self),
            unsafeBitCast(post, to: SLPSPostEventFunc.self)
        )
    }()

    private static let skyLightFocusEnabled =
        DebugSwitch.skylightFocus.isEnabled(in: ProcessInfo.processInfo.environment)

    /// pid → PSN, remembered per process generation: `GetProcessForPID` resolves through
    /// LaunchServices and fails transiently for live processes (it and
    /// `NSRunningApplication(processIdentifier:)` failed for the same pid at the same instant on
    /// 2026-09-15, which skipped the hand-off pre-switch and let Finder promote a sibling). A PSN
    /// seen earlier for the same process generation is served when the lookup fails.
    private static let serialNumbers = ProcessGenerationCache<ProcessSerialNumber>()

    private static func processSerialNumber(for pid: pid_t) -> ProcessSerialNumber? {
        guard let getPSN = getProcessForPID else { return nil }
        var psn = ProcessSerialNumber()
        if getPSN(pid, &psn) == noErr {
            serialNumbers.remember(psn, for: pid)
            return psn
        }
        return serialNumbers.value(for: pid)
    }

    /// Only does the `_SLPSSetFrontProcessWithOptions` pre-switch and sends no make-key down (for restore pre-activation:
    /// the down must be sent after unminimize; see the R2 order comment in the activate() restore branch).
    fileprivate static let kCPSUserGenerated: UInt32 = 0x200
    /// Switch frontmost without raising any of the app's windows (for the minimize handoff; see `switchFrontmostForHandoff`).
    fileprivate static let kCPSNoWindows: UInt32 = 0x400

    @discardableResult
    fileprivate func postSkyLightFrontSwitchOnly(
        pid: pid_t,
        windowID: CGWindowID,
        mode: UInt32 = AccessibilityWindowActionExecutor.kCPSUserGenerated
    ) -> Bool {
        guard Self.skyLightFocusEnabled else { return false }
        guard let focus = Self.skyLightFocus, var psn = Self.processSerialNumber(for: pid) else { return false }
        _ = withUnsafePointer(to: &psn) { focus.slps($0, windowID, mode) }
        return true
    }

    /// Shared SkyLight focus core: front-process switch + one synthetic make-key mouse-down for a
    /// known cgWindowID. Pure event posts — no AX round-trips, so it never blocks on a
    /// napping target app. Byte layout is load-bearing (see AGENTS.md); do not vary it.
    ///
    /// 2026-08-22 layout change: the old paired 0x0d make-key events were silently ignored by WindowServer on macOS 26 (Tahoe)
    /// (every call returned success while focus did not move at all, verified by a CLI probe); after clicking a tab kAXFocusedWindow
    /// stayed on the old window -> the snapshot never saw .active -> same-app window switching broke + toggle wrongly minimized. The current layout is
    /// ported from AltTab (verified working on macOS 26.5, src/macos/api-wrappers/SkyLight.framework.swift):
    /// post one synthetic kCGEventLeftMouseDown (0x08=0x01) by windowID, down only and no up:
    /// the down alone delivers key, and a half click can never activate any control; the landing point (300_000, 300_000) is far beyond
    /// the bottom-right of any window (NaN gets sanitized to (0,0) by some apps, mis-clicking the top-left control; a point hugging the frame would land in the
    /// resize grab area). The buffer is 0x100 while the record's declared length stays 0xf8: on macOS 14.7.4+
    /// CGSEncodeEventRecord reads out of bounds past 0xf8, and a short buffer SIGABRTs.
    /// The event must be immediately followed by kAXRaiseAction for consecutive switches to work (this file's focusWindowViaSkyLight /
    /// activate() both keep this order; verified by 4 consecutive CLI switches).
    @discardableResult
    fileprivate func postSkyLightWindowFocus(pid: pid_t, windowID: CGWindowID) -> Bool {
        guard Self.skyLightFocusEnabled else { return false }
        guard Self.skyLightFocus != nil, Self.getProcessForPID != nil else {
            Self.chipProbeLogger.info("skylight-focus unavailable pid=\(pid, privacy: .public)")
            return false
        }
        guard postSkyLightFrontSwitchOnly(pid: pid, windowID: windowID, mode: Self.kCPSUserGenerated) else {
            Self.chipProbeLogger.info("skylight-focus GetProcessForPID failed pid=\(pid, privacy: .public)")
            return false
        }
        return postSkyLightMakeKeyDown(pid: pid, windowID: windowID)
    }

    /// A synthetic mouse-down that sends only make-key and does not switch frontmost (byte layout above). Used after the minimize handoff to give the taking-over app's
    /// window key: the `kCPSNoWindows` pre-switch left the app frontmost with no key window (owner 2026-08-23
    /// "focus is empty"); after the target collapses, sending this one down makes the taking-over window key immediately (matrix M6 5/5).
    @discardableResult
    fileprivate func postSkyLightMakeKeyDown(pid: pid_t, windowID: CGWindowID) -> Bool {
        guard Self.skyLightFocusEnabled else { return false }
        guard let focus = Self.skyLightFocus, var psn = Self.processSerialNumber(for: pid) else { return false }

        var event = [UInt8](repeating: 0, count: 0x100)
        event[0x04] = 0xf8            // declared record length (does not change with the buffer)
        event[0x08] = 0x01            // kCGEventLeftMouseDown; only down, no up
        event[0x3a] = 0x10            // purpose unknown; yabai / Hammerspoon / AltTab all set 0x10
        var wid = windowID
        withUnsafeBytes(of: &wid) { bytes in
            for index in 0..<4 {
                event[0x3c + index] = bytes[index]
            }
        }
        var offContentPoint = CGPoint(x: 300_000, y: 300_000)
        withUnsafeBytes(of: &offContentPoint) { bytes in
            for index in 0..<16 {
                event[0x20 + index] = bytes[index]
            }
        }
        withUnsafePointer(to: &psn) { pointer in
            event.withUnsafeBufferPointer { _ = focus.post(pointer, $0.baseAddress!) }
        }
        return true
    }

    /// Tail of the minimize handoff: the target has collapsed; give the taking-over app's window key (see `postSkyLightMakeKeyDown`).
    func makeKeyAfterHandoff(pid: pid_t, windowID: CGWindowID) {
        postSkyLightMakeKeyDown(pid: pid, windowID: windowID)
    }

    /// Early focus (activation-flash root fix 2026-07-03): at click time, use the cgWindowID already known from the snapshot to switch frontmost directly,
    /// ahead of any AX query that may block 400-900ms (handle capture / minimized read / cgID read).
    /// That gap is exactly the window in which a Ghostty / Chromium-family frontmost app grabs its window back to the top and causes the activation flash.
    /// Visible windows only: minimized windows cannot be switched early (the app promotes a visible sibling window, 2026-07-05 probe);
    /// they take the "switch immediately after unminimize" path in activate() (knownCGWindowID).
    @discardableResult
    func focusWindowEarly(pid: pid_t, cgWindowID: CGWindowID) -> Bool {
        postSkyLightWindowFocus(pid: pid, windowID: cgWindowID)
    }

    /// Best-effort windowID-targeted focus. Return false only when we cannot even
    /// attempt the route; SkyLight return codes are not a fallback signal.
    @discardableResult
    func focusWindowViaSkyLight(pid: pid_t, element: AXUIElement) -> Bool {
        guard Self.skyLightFocusEnabled else { return false }
        guard let windowID = reader.cgWindowID(for: element) else {
            Self.chipProbeLogger.info("skylight-focus unavailable pid=\(pid, privacy: .public)")
            return false
        }

        guard postSkyLightWindowFocus(pid: pid, windowID: windowID) else {
            return false
        }
        _ = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        return true
    }

    private func setMinimized(_ minimized: Bool, for handle: WindowHandle) -> Bool {
        reader.setMinimized(
            minimized,
            for: AXWindowHandle(pid: handle.pid, title: handle.title, bounds: handle.bounds, element: handle.element)
        )
    }

    private func bestMatch(for target: WindowTarget, from elements: [AXUIElement]) -> AXUIElement? {
        let scored = elements.compactMap { element -> (AXUIElement, Int)? in
            let title = axStringAttribute(kAXTitleAttribute as CFString, from: element)
            let bounds = axFrame(of: element)
            let score = AXWindowMatchPolicy.matchScore(
                targetTitle: target.title,
                targetBounds: target.bounds,
                candidateTitle: title,
                candidateBounds: bounds
            )
            return score.map { (element, $0) }
        }

        return scored.min(by: { $0.1 < $1.1 })?.0
    }

    private func normalizedTitle(_ title: String) -> String {
        title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

struct ActionExecutionSwitches: Equatable {
    let fastWindowHandleEnabled: Bool
    /// `DOCK_AX_ELEMENT_CACHE=0` turns off the "cached element" tier, returning to the two tiers fast / fallback.
    let axElementCacheEnabled: Bool
    let chipProbeEnabled: Bool
    let minimizeAppFallbackEnabled: Bool

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        fastWindowHandleEnabled = DebugSwitch.fastWindowHandle.isEnabled(in: environment)
        axElementCacheEnabled = DebugSwitch.axElementCache.isEnabled(in: environment)
        chipProbeEnabled = DebugSwitch.chipProbe.isEnabled(in: environment)
        minimizeAppFallbackEnabled = DebugSwitch.minimizeAppFallback.isEnabled(in: environment)
    }
}

enum WindowHandleCapturePlan {
    /// Three tiers, fast to slow: **cached element (zero enumeration) -> query by cgWindowID (100ms) -> full title/geometry chain (500ms)**.
    ///
    /// `justUnhid` disables the **first two tiers** unconditionally: for an app that was just unhidden, its AX elements may still be in a transitional state,
    /// and the one in the cache was stored before the minimize/hide, so neither is trustworthy and the slow path with retries must be used (existing rule, unchanged).
    static func capture<Handle>(
        cachedEnabled: Bool,
        fastEnabled: Bool,
        cgWindowID: CGWindowID?,
        justUnhid: Bool,
        cached: (CGWindowID) -> Handle?,
        fast: (CGWindowID) -> Handle?,
        fallback: () -> Handle?
    ) -> Handle? {
        if let cgWindowID, !justUnhid {
            if cachedEnabled, let handle = cached(cgWindowID) { return handle }
            if fastEnabled, let handle = fast(cgWindowID) { return handle }
        }
        return fallback()
    }

    /// Activate with `knownMinimized` forbids the app-level fallback (2026-08-25, unconditional, not behind the settle-gate switch):
    /// `activateAppWithWindowRecovery` raises `visibleWindows[0]`, which can never restore a minimized
    /// target and only brings a sibling window to the front (the exact origin of the owner's rapid-click measurement). If all captures fail, return failure so the optimistic state
    /// bounces back; isomorphic to the 2026-08-11 "a failed minimize capture never hides the whole app", so likewise not behind a switch.
    static func usesAppFallbackAfterCaptureFailure(
        requestKind: PlatformActionRequest.ActionKind,
        isFinderWindow: Bool,
        minimizeAppFallbackEnabled: Bool,
        knownMinimized: Bool
    ) -> Bool {
        guard !isFinderWindow else { return false }
        if requestKind == .minimizeWindow { return minimizeAppFallbackEnabled }
        if requestKind == .activateWindow && knownMinimized { return false }
        return true
    }
}

/// Pre-restore pre-activation decision (2026-08-22 restore-timing matrix): only when the target app has
/// **no non-minimized windows** besides the target window is "switch frontmost first, restore immediately after" (R2 order) allowed; then AppKit
/// has nothing to promote, and in-process deminiaturize-as-key makes the traffic lights colored during the restore animation (native look).
/// Disabled when any non-minimized sibling exists (visible / hidden / disappeared all conservatively counted): the matrix showed
/// that even with the switch and restore microseconds apart, AppKit still persistently lifts a visible sibling above the old frontmost (the 07-05 guardrail
/// still holds under the new event mechanism). A pure function; FinderP0Tests locks the behavior.
enum MinimizedRestorePreActivation {
    static func canPreActivate(snapshot: DockSnapshot, target: WindowRecord) -> Bool {
        !snapshot.windows.values.contains {
            $0.pid == target.pid && $0.id != target.id && $0.status != .minimized
        }
    }
}

struct PlatformActionExecutor {
    private let windowExecutor: AccessibilityWindowActionExecutor
    private let switches: ActionExecutionSwitches
    private static let chipProbeLogger = Logger(subsystem: "app.neobar.NeoBar", category: "ChipProbe")
    private static let postMinimizeActivateDelayMicroseconds: useconds_t = 50_000

    init(switches: ActionExecutionSwitches = ActionExecutionSwitches()) {
        self.switches = switches
        windowExecutor = AccessibilityWindowActionExecutor(chipProbeEnabled: switches.chipProbeEnabled)
    }

    @discardableResult
    func execute(
        _ request: PlatformActionRequest,
        snapshot: DockSnapshot,
        forcedMinimizedPrior: Bool,
        onHandoffActivePrediction: ((WindowID) -> Void)?
    ) -> Bool {
        guard let windowID = request.windowID,
              let record = snapshot.windows[windowID] else {
            return false
        }
        // Settle-gate prior (v2, 2026-08-25): the gate layer has just dispatched a minimize for this window (within priorWindow).
        // Used only as an **affirmative** signal synthesized into knownMinimized: truly minimized goes through the measured, locked v3 restore order; if it was actually not
        // minimized, unminimize is a harmless no-op + normal focus. Never used in reverse (affirmative-only).
        let effectiveKnownMinimized = forcedMinimizedPrior || record.status == .minimized

        if record.id.rawValue.hasPrefix("app-") {
            return executeAppFallback(request: request, record: record)
        }

        // New window needs no window handle — just activate the app and send Cmd+N.
        if request.kind == .newWindow {
            return performNewWindow(record: record)
        }

        if request.kind == .hideApp || request.kind == .quitApp {
            return executeAppFallback(request: request, record: record)
        }

        let isFinderWindow = FinderWindowRules.isFinder(bundleIdentifier: record.bundleIdentifier)

        // Early focus (activation-flash root fix 2026-07-03): only activate + cross-app + visible window,
        // Finder included (the confirmFocused protection path still runs afterward as usual; Finder's multiple capture retries leave a longer gap,
        // which was the reason "only Finder still flashes"). It must happen before the handle capture below: capture/restore AX queries to the target app
        // can block for hundreds of milliseconds, and that gap is exactly the window in which the still-focused old frontmost app (Ghostty / Chromium family)
        // grabs its window back to the top. Windows of hidden apps are not focused early (the unhide flow is handled separately).
        // Minimized windows are [not] focused early (2026-07-05 probes v0-v3): while B1 is still ordering out, any frontmost switch
        // makes the app promote the visible sibling B2 above the old frontmost (a persistent z-order bug); instead the switch happens
        // right after unminimize in activate() (see the knownCGWindowID path), measured to be equally flash-free.
        // Skip early focus while a settle-gate prior is in flight (2026-08-25): during a rapid-click storm the snapshot may still stale-ly say
        // inactive while the window is actually mid-genie / off-screen; the early focus's frontmost switch then is the bare switch that promoted a sibling
        // 3/3 in the 07-05 matrix (the owner's click log confirmed this path fired during a storm).
        if request.kind == .activateWindow,
           !forcedMinimizedPrior,
           let cgWindowID = record.cgWindowID,
           record.status == .active || record.status == .inactive,
           NSRunningApplication(processIdentifier: record.pid)?.isActive != true {
            windowExecutor.focusWindowEarly(pid: record.pid, cgWindowID: cgWindowID)
            ClickLatencyTrace.mark(windowID: request.windowID?.rawValue, "earlyFocus")
        }

        // If Finder is hidden, unhide it first so its AX windows become accessible.
        // Then fall through to the normal window-level capture path — avoids regressing
        // to app-level activate, which can raise the wrong window (guardrail in AGENTS.md).
        var justUnhid = false
        if isFinderWindow {
            let finderApp = NSRunningApplication(processIdentifier: record.pid)
            if finderApp?.isHidden == true {
                finderApp?.unhide()
                // Poll until the app transitions out of hidden (max ~200ms) so the AX
                // element is accessible before the handle-capture below runs.
                let deadline = Date().addingTimeInterval(0.2)
                while finderApp?.isHidden == true, Date() < deadline {
                    usleep(20_000)
                }
                justUnhid = true
            }
        }

        let target = AccessibilityWindowActionExecutor.WindowTarget(
            pid: record.pid, title: record.title, bounds: record.bounds)
        // After unhide, skip the fast cgWindowID path — it may return a handle whose AX
        // element is still transitioning. Use the retry-capable captureHandle instead.
        // Which tier hit is the key classification info for proving whether this change works (cache / fast path / full chain).
        var captureTier = "none"
        let handle = WindowHandleCapturePlan.capture(
            cachedEnabled: switches.axElementCacheEnabled,
            fastEnabled: switches.fastWindowHandleEnabled,
            cgWindowID: record.cgWindowID,
            justUnhid: justUnhid,
            cached: {
                let h = windowExecutor.captureHandleFromCache(
                    $0,
                    pid: record.pid,
                    title: record.title,
                    bounds: record.bounds
                )
                if h != nil { captureTier = "cached" }
                return h
            },
            fast: {
                let h = windowExecutor.captureHandleByCGWindowID(
                    $0,
                    pid: record.pid,
                    title: record.title,
                    bounds: record.bounds
                )
                if h != nil { captureTier = "fast" }
                return h
            },
            fallback: {
                let h = windowExecutor.captureHandle(
                    for: target,
                    attempts: isFinderWindow ? 3 : 1,
                    retryIntervalMicroseconds: isFinderWindow ? 150_000 : 0
                )
                if h != nil { captureTier = "fallback" }
                return h
            }
        )
        ClickLatencyTrace.mark(windowID: request.windowID?.rawValue, "handle", detail: captureTier)

        guard let handle else {
            guard WindowHandleCapturePlan.usesAppFallbackAfterCaptureFailure(
                requestKind: request.kind,
                isFinderWindow: isFinderWindow,
                minimizeAppFallbackEnabled: switches.minimizeAppFallbackEnabled,
                knownMinimized: effectiveKnownMinimized
            ) else {
                return false
            }
            return executeAppFallback(request: request, record: record)
        }

        switch request.kind {
        case .activateWindow:
            return windowExecutor.activate(
                handle,
                requiresFocusedConfirmation: isFinderWindow,
                knownCGWindowID: record.cgWindowID,
                knownMinimized: effectiveKnownMinimized,
                preActivateForRestore: effectiveKnownMinimized
                    && MinimizedRestorePreActivation.canPreActivate(snapshot: snapshot, target: record),
                awaitOnScreenBeforeFocus: forcedMinimizedPrior
            )
        case .minimizeWindow:
            let handoff = beginHandoff(handle: handle, record: record, snapshot: snapshot,
                                       onHandoffActivePrediction: onHandoffActivePrediction, patience: .minimize)
            let preSwitched = handoff.preSwitched

            func finishSuccessfulMinimize(_ exec: AccessibilityWindowActionExecutor.ActionExecution) -> Bool {
                finishHandoff(handoff)
                if switches.chipProbeEnabled {
                    Self.chipProbeLogger.info("minimize-exec-result windowID=\(request.windowID?.rawValue ?? "nil", privacy: .public) success=\(exec.success, privacy: .public) preSwitched=\(preSwitched, privacy: .public) mechanism=\(exec.mechanism, privacy: .public) verifiedMinimized=\(String(describing: exec.verifiedMinimized), privacy: .public)")
                }
                return true
            }

            let minExec = windowExecutor.minimize(handle)
            if minExec.success {
                return finishSuccessfulMinimize(minExec)
            }
            if justUnhid {
                usleep(100_000)
                if let h = windowExecutor.captureHandle(for: target, attempts: 2, retryIntervalMicroseconds: 100_000) {
                    let retryExec = windowExecutor.minimize(h)
                    if switches.chipProbeEnabled {
                        Self.chipProbeLogger.info("minimize-exec-result windowID=\(request.windowID?.rawValue ?? "nil", privacy: .public) success=\(retryExec.success, privacy: .public) preSwitched=\(preSwitched, privacy: .public) mechanism=\(retryExec.mechanism, privacy: .public) verifiedMinimized=\(String(describing: retryExec.verifiedMinimized), privacy: .public)")
                    }
                    return retryExec.success
                }
            }
            // Writes dropped during the restore animation (2026-08-26 Release measurement): before the restore genie ends,
            // both the kAXMinimized write and the minimize-button click are dropped by the app (fast failure in 11-16ms, read-back false).
            // Reversing mid-flight is not feasible (scratch/minrestore_probe 2026-08-25), so a bounded retry waits for the window to recover and
            // accept writes, then immediately adds this hit, the earliest collapse point attainable. 8x120ms covers ~1s in total
            //(Finder's animation is 887ms; the same day's Release measurement had 27/27 first tries succeed at +250ms, so the interval was tightened to
            // 120ms to grind off the landing remainder); only the failure path runs it, normal collapse costs nothing. If all fail, return failure as before
            // and the optimistic state bounces back.
            if minExec.verifiedMinimized != true {
                for attempt in 1...8 {
                    usleep(120_000)
                    let retryExec = windowExecutor.minimize(handle)
                    if switches.chipProbeEnabled {
                        Self.chipProbeLogger.info("minimize-retry attempt=\(attempt, privacy: .public) windowID=\(request.windowID?.rawValue ?? "nil", privacy: .public) success=\(retryExec.success, privacy: .public) mechanism=\(retryExec.mechanism, privacy: .public) verifiedMinimized=\(String(describing: retryExec.verifiedMinimized), privacy: .public)")
                    }
                    if retryExec.success {
                        return finishSuccessfulMinimize(retryExec)
                    }
                }
            }
            if switches.chipProbeEnabled {
                Self.chipProbeLogger.info("minimize-exec-result windowID=\(request.windowID?.rawValue ?? "nil", privacy: .public) success=\(minExec.success, privacy: .public) preSwitched=\(preSwitched, privacy: .public) mechanism=\(minExec.mechanism, privacy: .public) verifiedMinimized=\(String(describing: minExec.verifiedMinimized), privacy: .public)")
            }
            return false
        case .closeWindow:
            // Same hand-off as minimize: closing the active app's key window otherwise makes AppKit
            // raise that app's next window over whatever was directly beneath.
            let handoff = beginHandoff(handle: handle, record: record, snapshot: snapshot,
                                       onHandoffActivePrediction: onHandoffActivePrediction, patience: .close)
            if windowExecutor.close(handle) {
                finishHandoff(handoff)
                return true
            }
            if justUnhid {
                usleep(100_000)
                if let h = windowExecutor.captureHandle(for: target, attempts: 2, retryIntervalMicroseconds: 100_000) {
                    return windowExecutor.close(h)
                }
            }
            return false
        case .hideApp, .quitApp:
            return executeAppFallback(request: request, record: record)
        case .newWindow:
            return performNewWindow(record: record)
        }
    }

    private struct Handoff {
        var targetPID: pid_t?
        var windowID: CGWindowID?
        var preSwitched = false
    }

    /// How long the hand-off may wait on the target app's AX before acting anyway. Minimize keeps
    /// the 100ms cap (the click must not lag behind the genie); close has no animation to protect,
    /// and a loaded Finder answers AX in 100–400ms right after a front switch — closing before it
    /// has processed the deactivation is exactly what promotes a sibling.
    struct HandoffPatience {
        let focusedReadBudget: TimeInterval
        let deactivationCap: TimeInterval
        static let minimize = HandoffPatience(focusedReadBudget: 0, deactivationCap: 0.1)
        static let close = HandoffPatience(focusedReadBudget: 0.5, deactivationCap: 0.5)
    }

    /// Front hand-off before the frontmost focused window leaves the screen (minimize or close):
    /// whoever is directly beneath takes the front (`MinimizeHandoffTarget`).
    private func beginHandoff(
        handle: AccessibilityWindowActionExecutor.WindowHandle,
        record: WindowRecord,
        snapshot: DockSnapshot,
        onHandoffActivePrediction: ((WindowID) -> Void)?,
        patience: HandoffPatience
    ) -> Handoff {
        let verdict = windowExecutor.findBackgroundActivationTarget(
            for: handle, record: record, snapshot: snapshot, focusedReadBudget: patience.focusedReadBudget
        )
        // The successor's prediction is sent back as early as possible (the action has not run yet): the earlier the optimistic .active is written, the better it covers the very fast
        // second hit of "collapse window 1 -> click window 2". If the action fails, the prediction self-heals by being cleared via supersession (the target remains .active, which honors it).
        switch verdict {
        case .switchTo(_, _, let windowID), .siblingTakesOver(let windowID):
            onHandoffActivePrediction?(windowID)
        case .none:
            break
        }
        var handoff = Handoff()
        if case .switchTo(let pid, let wid, _) = verdict {
            handoff.targetPID = pid
            handoff.windowID = wid
            handoff.preSwitched = windowExecutor.switchFrontmostForHandoff(
                toPID: pid, windowID: wid, awaitingDeactivationOf: handle.pid,
                deactivationCap: patience.deactivationCap
            )
        }
        return handoff
    }

    /// After the window is gone: key the hand-off window, or activate its app if the pre-switch was unavailable.
    private func finishHandoff(_ handoff: Handoff) {
        if handoff.preSwitched, let targetPID = handoff.targetPID, let handoffWindowID = handoff.windowID {
            windowExecutor.makeKeyAfterHandoff(pid: targetPID, windowID: handoffWindowID)
        }
        if !handoff.preSwitched, let targetPID = handoff.targetPID {
            usleep(Self.postMinimizeActivateDelayMicroseconds)
            let activated = NSRunningApplication(processIdentifier: targetPID)?
                .activate(options: [.activateIgnoringOtherApps]) ?? false
            if switches.chipProbeEnabled {
                Self.chipProbeLogger.info("postactivate-background-fallback pid=\(targetPID, privacy: .public) activated=\(activated, privacy: .public)")
            }
        }
    }

    private func executeAppFallback(request: PlatformActionRequest, record: WindowRecord) -> Bool {
        let runningApp = NSRunningApplication(processIdentifier: record.pid)

        switch request.kind {
        case .activateWindow:
            // Finder persistent chip (no open windows): open a new Finder window where Finder's own
            // "New Finder windows show" setting points, as the system Dock does.
            if record.id.rawValue.hasPrefix("app-"),
               FinderWindowRules.isFinder(bundleIdentifier: record.bundleIdentifier) {
                FinderNewWindowOpener.openNewWindow()
                return true
            }
            return windowExecutor.activateAppWithWindowRecovery(pid: record.pid, runningApp: runningApp)
        case .minimizeWindow, .hideApp:
            return runningApp?.hide() ?? false
        case .closeWindow:
            return false
        case .quitApp:
            return runningApp?.terminate() ?? false
        case .newWindow:
            return performNewWindow(record: record)
        }
    }

    /// Opens a new window for a window-backed app by activating it and synthesizing
    /// the standard Cmd+N key equivalent.
    ///
    /// v1 limitations (accepted, documented in README/Backlog): apps where Cmd+N means
    /// "new document" (Pages/TextEdit) yield a new document; apps not bound to Cmd+N
    /// do nothing. Covers ~90% of common apps. v2 upgrade path is AX menu traversal
    /// for a "New Window" item.
    private func performNewWindow(record: WindowRecord) -> Bool {
        guard let runningApp = NSRunningApplication(processIdentifier: record.pid) else { return false }
        runningApp.activate(options: [.activateIgnoringOtherApps])
        // Short tick so activation settles before the key equivalent is delivered.
        usleep(80_000)
        return postCommandN(toPID: record.pid)
    }

    private func postCommandN(toPID pid: pid_t) -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return false }
        let keyN: CGKeyCode = 45 // kVK_ANSI_N
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyN, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyN, keyDown: false) else {
            return false
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.postToPid(pid)
        keyUp.postToPid(pid)
        return true
    }
}

private func windows(for pid: pid_t) -> [AXUIElement] {
    let appElement = AXUIElementCreateApplication(pid)
    guard let value = axCopyAttributeValue(kAXWindowsAttribute as CFString, from: appElement),
          let elements = value as? [AXUIElement] else {
        return []
    }
    return elements
}

private func axStringAttribute(_ attribute: CFString, from element: AXUIElement) -> String? {
    guard let value = axCopyAttributeValue(attribute, from: element),
          let text = value as? String else {
        return nil
    }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

private func axBoolAttribute(_ attribute: CFString, from element: AXUIElement) -> Bool? {
    guard let value = axCopyAttributeValue(attribute, from: element),
          let number = value as? NSNumber else {
        return nil
    }
    return number.boolValue
}

private func axElementAttribute(_ attribute: CFString, from element: AXUIElement) -> AXUIElement? {
    // The type of a cross-process AX return value is decided by the other process; an app with a bug may return another CF type.
    // Bitcasting without checking the type is undefined behavior, and a forced cast traps outright; either way the whole taskbar crashes, so check the type first, then convert.
    guard let value = axCopyAttributeValue(attribute, from: element),
          CFGetTypeID(value) == AXUIElementGetTypeID() else {
        return nil
    }
    return (value as! AXUIElement)
}

private func axFrame(of element: AXUIElement) -> CGRect? {
    guard let positionAX = axCopyAttributeValue(kAXPositionAttribute as CFString, from: element),
          let sizeAX = axCopyAttributeValue(kAXSizeAttribute as CFString, from: element) else {
        return nil
    }

    // Same as above: position / size may also not be an AXValue; check the CF type before converting (the same rule as in `FrontmostWindowGeometryObserver`).
    guard CFGetTypeID(positionAX) == AXValueGetTypeID(),
          CFGetTypeID(sizeAX) == AXValueGetTypeID() else {
        return nil
    }
    let position = positionAX as! AXValue
    let sizeValueRef = sizeAX as! AXValue

    var point = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetType(position) == .cgPoint,
          AXValueGetType(sizeValueRef) == .cgSize,
          AXValueGetValue(position, .cgPoint, &point),
          AXValueGetValue(sizeValueRef, .cgSize, &size) else {
        return nil
    }

    return CGRect(origin: point, size: size)
}

private func axCopyAttributeValue(
    _ attribute: CFString,
    from element: AXUIElement,
    maxAttempts: Int = 2
) -> CFTypeRef? {
    var attempt = 0
    while attempt < maxAttempts {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        if result == .success {
            return value
        }

        if result != .cannotComplete {
            return nil
        }

        attempt += 1
        usleep(20_000)
    }

    return nil
}
