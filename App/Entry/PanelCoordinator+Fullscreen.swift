import AppKit
import ApplicationServices
import Combine
import QuartzCore
import SwiftUI
import os

// PanelCoordinator · Fullscreen: observation, CG synchronous probing, AX asynchronous probing, and predictive hiding / rollback for the green-button / space-switch paths.
// Split out of PanelCoordinator.swift as an extension on 2026-09-05; moved only, not changed.
struct FullscreenIntentTransaction {
    let generation: UInt64
    let pid: pid_t
    let focusedWindowID: CGWindowID
    let screenCGFrame: CGRect
}
struct FullscreenSpaceHold {
    let generation: UInt64
    let pid: pid_t?
    let screenCGFrame: CGRect?
}

extension PanelCoordinator {
    // MARK: - Fullscreen Monitor

    func setupFullscreenMonitor() {
        let nc = NSWorkspace.shared.notificationCenter
        // Token-style observer (the repo-wide convention; the selector style is unowned-unsafe). queue nil = execute synchronously
        // on the delivering thread; these two notifications are delivered on the main thread anyway, so the timing is word-for-word identical to the original selector path; assumeIsolated merely
        // tells the compiler that fact without adding an extra hop (fullscreen predictive hiding is sensitive to that hop).
        workspaceObserverTokens.append(nc.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleSpaceChange() }
        })
        workspaceObserverTokens.append(nc.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil
        ) { [weak self] note in
            MainActor.assumeIsolated { self?.handleAppActivated(note) }
        })
        lastActiveApplicationPID = NSWorkspace.shared.runningApplications.first(where: { $0.isActive })?.processIdentifier
        fullscreenReconcileTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.fullscreenReconcileIfNeeded() }
        }
        fullscreenReconcileTimer?.tolerance = 0.5
    }

    /// The orchestration layer connects / disconnects fullscreen intent routing. On disconnect, cancel in-flight predictions (setting turned off, permission suspended, unit torn down).
    func setFullscreenIntentRouting(enabled: Bool) {
        fullscreenIntentRoutingEnabled = enabled && !isSuspendedForPermissionLoss
        guard !fullscreenIntentRoutingEnabled else { return }
        if let transaction = fullscreenIntentTransaction {
            cancelFullscreenIntent(generation: transaction.generation, reason: "disabled")
        }
        if let spaceGeneration = fullscreenSpaceIntentGeneration {
            cancelFullscreenSpaceArrowIntent(generation: spaceGeneration, reason: "disabled")
        }
    }

    private func handleSpaceChange() {
        let spaceHoldGeneration = beginFullscreenSpaceHold(
            pid: lastActiveApplicationPID,
            confirmationDelay: FullscreenSpaceHoldDecision.postSpaceConfirmationDelay
        )
        // Sync CG check: fires before the panel has a chance to appear, no AX = no main-thread risk
        let cgFullscreen = checkFullscreenViaCGSync()
        applyFullscreenVisibility(
            cgFullscreen,
            source: "space-cg",
            expectedIntentGeneration: fullscreenIntentTransaction?.generation,
            pid: lastActiveApplicationPID,
            screenCGFrame: currentPanelScreenCGFrame(),
            expectedSpaceHoldGeneration: spaceHoldGeneration
        )
        // Async AX secondary check: catches edge cases CG misses (e.g. games on a non-zero layer)
        if !cgFullscreen || fullscreenIntentTransaction == nil {
            triggerAsyncFullscreenCheck(
                expectedSpaceHoldGeneration: spaceHoldGeneration,
                source: "space-ax"
            )
        }
        // Fallback: membership can also be lost outside the show/hide paths (issue #19), and a desktop switch is the only moment the user would notice.
        repairAllSpacesMembershipIfNeeded()
    }

    private func handleAppActivated(_ note: Notification) {
        // Use the "just-activated app" carried by the notification and do not read the lagging frontmostApplication (AGENTS rule)
        let activated = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        lastActiveApplicationPID = activated?.processIdentifier
        let spaceHoldGeneration = beginFullscreenSpaceHold(
            pid: lastActiveApplicationPID,
            confirmationDelay: FullscreenSpaceHoldDecision.activationFallbackDelay
        )
        cancelFullscreenIntentIfContextChanged(activePID: activated?.processIdentifier)
        triggerAsyncFullscreenCheck(
            pid: lastActiveApplicationPID,
            expectedSpaceHoldGeneration: spaceHoldGeneration,
            source: "app-activation-ax"
        )
    }

    // MARK: - Sync CG fullscreen probe (main thread only, no AX)

    private func checkFullscreenViaCGSync() -> Bool {
        guard let panel = dockPanel else { return false }
        let screen = panelCurrentScreen(panel: panel)
        let screenCGFrame = Self.toCGRect(screen)
        let ourPID = pid_t(ProcessInfo.processInfo.processIdentifier)
        guard let candidate = WindowLiftCGWindowProbe.frontmostLargeWindow(
            on: screenCGFrame,
            excludingPID: ourPID
        ) else { return false }

        let cgBounds = candidate.quartzFrame
        let t: CGFloat = 8
        return abs(cgBounds.width  - screenCGFrame.width)  < t
            && abs(cgBounds.height - screenCGFrame.height) < t
            && abs(cgBounds.minX   - screenCGFrame.minX)   < t
            && abs(cgBounds.minY   - screenCGFrame.minY)   < t
    }

    // MARK: - Async AX fullscreen probe (secondary / fallback)

    private func triggerAsyncFullscreenCheck(
        pid explicitPID: pid_t? = nil,
        expectedSpaceHoldGeneration explicitSpaceHoldGeneration: UInt64? = nil,
        isFinalSpaceHoldWindowedConfirmation: Bool = false,
        isFinalSpaceIntentVerdict: Bool = false,
        source: String = "ax"
    ) {
        guard let panel = dockPanel else { return }
        // Convert to CG coords on main thread; AX kAXPositionAttribute also uses CG (top-left origin)
        let screenCGFrame = Self.toCGRect(panelCurrentScreen(panel: panel))
        let frontPID = explicitPID ?? lastActiveApplicationPID
        fullscreenProbeGeneration &+= 1
        let probeGeneration = fullscreenProbeGeneration
        let expectedIntentGeneration = fullscreenIntentTransaction?.generation
        let expectedSpaceHoldGeneration = explicitSpaceHoldGeneration ?? fullscreenSpaceHold?.generation
        Task.detached { [weak self] in
            let probe = Self.detectFullscreenViaAX(pid: frontPID, screenCGFrame: screenCGFrame)
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard probeGeneration == self.fullscreenProbeGeneration else {
                    return
                }
                let verdict = probe.verdict
                // Three states -> what is handed to the existing `applyFullscreenVisibility` is still one boolean; the hold / 120ms confirmation /
                // final-review sequence is all unchanged, and what changes is only where that boolean comes from when "the focused window is on another screen":
                // with multiple screens (cases 3 and 4, and when a pinned-tier strip is not on the focused screen) AX has nothing to say about this screen, so ask SkyLight for
                // this screen's current space; unreadable means no information, **not false**, otherwise screen B's strip would pop up over B's
                // fullscreen space. The final-review call must wrap up; with no information, fall back to this screen's synchronous CG probe.
                let fullscreen: Bool
                let resolvedSource: String
                switch verdict {
                case .fullscreen:
                    fullscreen = true
                    resolvedSource = source
                case .windowed:
                    fullscreen = false
                    resolvedSource = source
                case .notOnThisScreen:
                    guard Self.slsVerdictEnabled else {
                        fullscreen = false
                        resolvedSource = source
                        break
                    }
                    if let fromSpace = self.fullscreenVerdictFromSpaceLayout() {
                        fullscreen = fromSpace
                        resolvedSource = "\(source)-sls"
                    } else if isFinalSpaceHoldWindowedConfirmation || isFinalSpaceIntentVerdict {
                        fullscreen = self.checkFullscreenViaCGSync()
                        resolvedSource = "\(source)-cgfallback"
                    } else {
                        return
                    }
                }
                self.applyFullscreenVisibility(
                    fullscreen,
                    source: resolvedSource,
                    expectedIntentGeneration: expectedIntentGeneration,
                    pid: frontPID,
                    screenCGFrame: screenCGFrame,
                    expectedSpaceHoldGeneration: expectedSpaceHoldGeneration,
                    isFinalSpaceHoldWindowedConfirmation: isFinalSpaceHoldWindowedConfirmation,
                    isFinalSpaceIntentVerdict: isFinalSpaceIntentVerdict
                )
                self.reconcileOverlayWindowWatch(overlayWindowID: probe.overlayWindowID)
            }
        }
    }

    // MARK: - Overlay-hide watch (frame≈screen fallback has no ending event)

    /// Runs after every AX verdict has been applied. A fullscreen verdict that came from the frame
    /// fallback carries the window id and (re)arms the watch; any other outcome — revealed, held, or
    /// fullscreen by the native flag — disarms it. The watch is not evidence by itself: a tick only
    /// asks the AX path to judge again.
    private func reconcileOverlayWindowWatch(overlayWindowID: CGWindowID?) {
        guard let overlayWindowID, visibilityState.hideReasons.contains(.fullscreen) else {
            endOverlayWindowWatch()
            return
        }
        beginOverlayWindowWatch(windowID: overlayWindowID)
    }

    private func beginOverlayWindowWatch(windowID: CGWindowID) {
        guard Self.overlayWindowWatchEnabled else { return }
        if overlayWindowWatchID == windowID, overlayWindowWatchTimer != nil { return }
        endOverlayWindowWatch()
        overlayWindowWatchID = windowID
        let timer = Timer(timeInterval: OverlayWindowWatch.tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.overlayWindowWatchTick() }
        }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        overlayWindowWatchTimer = timer
    }

    func endOverlayWindowWatch() {
        overlayWindowWatchTimer?.invalidate()
        overlayWindowWatchTimer = nil
        overlayWindowWatchID = nil
    }

    private func overlayWindowWatchTick() {
        guard let windowID = overlayWindowWatchID,
              visibilityState.hideReasons.contains(.fullscreen),
              let screenCGFrame = currentPanelScreenCGFrame() else {
            endOverlayWindowWatch()
            return
        }
        let observation = Self.cgWindowObservation(of: windowID)
        guard OverlayWindowWatch.shouldRecheck(
            isOnscreen: observation?.isOnscreen,
            bounds: observation?.bounds,
            screenCGFrame: screenCGFrame
        ) else { return }
        endOverlayWindowWatch()
        triggerAsyncFullscreenCheck(source: "overlay-gone-ax")
    }

    /// nil = the window no longer exists in the window server.
    nonisolated private static func cgWindowObservation(of windowID: CGWindowID) -> (isOnscreen: Bool, bounds: CGRect?)? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
              let info = list.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID })
        else { return nil }
        let isOnscreen = (info[kCGWindowIsOnscreen as String] as? Bool) ?? false
        let bounds = (info[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }
        return (isOnscreen, bounds)
    }

    private func fullscreenReconcileIfNeeded() {
        guard visibilityState.hideReasons.contains(.fullscreen) else { return }
        triggerAsyncFullscreenCheck()
    }

    private func applyFullscreenVisibility(
        _ isFullscreen: Bool,
        source: String,
        expectedIntentGeneration: UInt64? = nil,
        pid: pid_t? = nil,
        screenCGFrame: CGRect? = nil,
        expectedSpaceHoldGeneration: UInt64? = nil,
        isFinalSpaceHoldWindowedConfirmation: Bool = false,
        isFinalSpaceIntentVerdict: Bool = false
    ) {
        // Arrow-key prediction in progress: this stretch is closed out by the prediction itself and skips the regular judgment below.
        if let spaceGeneration = fullscreenSpaceIntentGeneration {
            if isFullscreen {
                guard visibilityState.confirmFullscreenTransition(generation: spaceGeneration) else {
                    return
                }
                clearFullscreenSpaceArrowIntent()
                fullscreenIntentLogger.notice(
                    "space-confirmed source=\(source, privacy: .public) generation=\(spaceGeneration, privacy: .public)"
                )
                closeDrawer()
                closeFolderPopup()
                dismissWindowTitleTooltip(suppressCurrentUntilExit: true)
                reconcilePanelVisibility()
                logFullscreenVerdict(true, source: source)
                return
            }
            // **Cannot trust the false judgment at the instant of the space switch.** Measured 2026-08-09: on desktop -> fullscreen,
            // `space-cg` always returns false at the moment of the notification (a false judgment during the transition); revoking per that puts the just-hidden
            // task strip back onto the fullscreen picture, which is where both the flicker and "the strip sits on top of a fullscreen app" came from.
            // `FullscreenSpaceHold` waits 120ms before deciding precisely to dodge the same pitfall, and the same cadence is reused here.
            guard isFinalSpaceIntentVerdict else {
                if source == "space-cg" {
                    scheduleFullscreenSpaceIntentVerdict(generation: spaceGeneration)
                }
                return
            }
            cancelFullscreenSpaceArrowIntent(generation: spaceGeneration, reason: "space-windowed")
        }
        switch FullscreenSpaceHoldDecision.disposition(
            isFullscreenVerdict: isFullscreen,
            expectedGeneration: expectedSpaceHoldGeneration,
            activeGeneration: fullscreenSpaceHold?.generation,
            isFinalWindowedConfirmation: isFinalSpaceHoldWindowedConfirmation
        ) {
        case .stale:
            return
        case .hold:
            return
        case .apply:
            if let hold = fullscreenSpaceHold {
                finishFullscreenSpaceHold(generation: hold.generation)
            }
        }
        if isFullscreen {
            if let transaction = fullscreenIntentTransaction {
                guard expectedIntentGeneration == transaction.generation,
                      pid == transaction.pid,
                      screenCGFrame == transaction.screenCGFrame,
                      isFullscreenIntentContextCurrent(transaction),
                      visibilityState.confirmFullscreenTransition(generation: transaction.generation) else {
                    return
                }
                finishFullscreenIntentTransaction()
                fullscreenIntentLogger.notice(
                    "confirmed source=\(source, privacy: .public) generation=\(transaction.generation, privacy: .public)"
                )
            } else {
                visibilityState.setFullscreen(true)
            }
            closeDrawer()
            closeFolderPopup()
            dismissWindowTitleTooltip(suppressCurrentUntilExit: true)
        } else {
            if fullscreenIntentTransaction != nil { return }
            visibilityState.setFullscreen(false)
        }
        reconcilePanelVisibility()
        logFullscreenVerdict(isFullscreen, source: source)
    }

    /// The sole evidence line when the task strip is hidden / shown. **Must carry the source and the hiding reason**: when users report "the task strip disappeared",
    /// only these two items distinguish which judgment acted (issue #19 had nowhere to start because only active= was logged).
    private func logFullscreenVerdict(_ isFullscreen: Bool, source: String) {
        let reasons = visibilityState.hideReasons
        var parts: [String] = []
        if reasons.contains(.fullscreen) { parts.append("fullscreen") }
        if reasons.contains(.fullscreenTransitionPending) { parts.append("pending") }
        if reasons.contains(.edgeAutoHide) { parts.append("edge") }
        let reasonText = parts.isEmpty ? "none" : parts.joined(separator: "+")
        logger.info(
            "[fullscreen] active=\(isFullscreen, privacy: .public) source=\(source, privacy: .public) reasons=\(reasonText, privacy: .public) pid=\(self.lastActiveApplicationPID ?? -1, privacy: .public)"
        )
    }

    /// The orchestration layer **broadcasts** the tap's request to every unit; the `screenCGFrame` guard lets only the unit for that screen act
    ///(when one screen goes fullscreen, only that screen's strip is hidden).
    func beginFullscreenIntent(_ request: FullscreenIntentRequest) {
        guard fullscreenIntentRoutingEnabled,
              fullscreenIntentTransaction == nil,
              request.screenCGFrame == currentPanelScreenCGFrame(),
              lastActiveApplicationPID == request.pid else {
            return
        }
        fullscreenIntentGeneration &+= 1
        let generation = fullscreenIntentGeneration
        fullscreenProbeGeneration &+= 1
        fullscreenIntentTransaction = FullscreenIntentTransaction(
            generation: generation,
            pid: request.pid,
            focusedWindowID: request.focusedWindowID,
            screenCGFrame: request.screenCGFrame
        )
        fullscreenIntentTimeoutTimer?.invalidate()
        visibilityState.beginFullscreenTransition(generation: generation)

        edgeIdleHideTimer?.invalidate()
        edgeIdleHideTimer = nil
        cancelEdgeWake()

        orderOutPanelsForFullscreenPrediction()
        fullscreenIntentLogger.notice(
            "pending source=\(request.source.rawValue, privacy: .public) generation=\(generation, privacy: .public) pid=\(request.pid, privacy: .public)"
        )

        let timer = Timer(timeInterval: 1.2, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.cancelFullscreenIntent(generation: generation, reason: "timeout")
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        fullscreenIntentTimeoutTimer = timer

        DispatchQueue.main.async { [weak self] in
            guard let self, self.fullscreenIntentTransaction?.generation == generation else { return }
            self.reconcilePanelVisibility()
        }
    }

    func cancelFullscreenIntent(generation: UInt64, reason: String) {
        guard fullscreenIntentTransaction?.generation == generation,
              visibilityState.timeoutFullscreenTransition(generation: generation) else {
            return
        }
        finishFullscreenIntentTransaction()
        fullscreenProbeGeneration &+= 1
        fullscreenIntentLogger.notice(
            "cancelled reason=\(reason, privacy: .public) generation=\(generation, privacy: .public)"
        )
        reconcilePanelVisibility()
    }

    private func finishFullscreenIntentTransaction() {
        fullscreenIntentTransaction = nil
        fullscreenIntentTimeoutTimer?.invalidate()
        fullscreenIntentTimeoutTimer = nil
    }

    /// After a prediction hit, move every panel out of WindowServer. Drawers/popups must take the "immediate" path: input has already
    /// been held by the tap, so there is no time to wait for a fade-out animation.
    private func orderOutPanelsForFullscreenPrediction() {
        edgeIdleHideTimer?.invalidate()
        edgeIdleHideTimer = nil
        cancelEdgeWake()

        dragController.cancelDrag()
        closeDrawerImmediately()
        closeFolderPopup(immediately: true)
        dismissWindowTitleTooltip(suppressCurrentUntilExit: true)

        panelsAreVisible = false
        // The predictive path is also "hidden because of fullscreen": the later reveal likewise uses a fade-in.
        lastHideWasForFullscreen = true
        // The fast hide path of fullscreen prediction does not go through applyPanelVisibility, so the badge gating must be notified separately.
        onLogicalVisibilityChanged?(false)
        orderDockSurfaceOut()
        capsulePanel?.orderOut(nil)
        drawerPanel?.orderOut(nil)
        folderPopupPanels.forEach { $0.orderOut(nil) }
        windowTitleTooltipPanel?.orderOut(nil)
    }

    // MARK: - Predictive hiding for switching to a fullscreen space (Control+Left/Right and three-finger horizontal swipe)

    /// When switching from a normal desktop to a fullscreen space, the system's space-switch notification arrives later than WindowServer capturing the transition snapshot,
    /// so hiding afterward is always too late (measured in `Docs/05`). Here we hide **before the input is delivered**:
    /// arrow keys lead the space switch by about `550ms`, a three-finger swipe by about `950-1130ms`, and both are measured to be enough.
    ///
    /// The gate in the trigger condition, "the adjacent space in the target direction must be a fullscreen space", is already decided inside `FullscreenIntentMonitor`,
    /// so everything reaching here really is entering a fullscreen space.
    func beginFullscreenSpaceIntent(direction: SpaceSwitchDirection) {
        guard fullscreenIntentRoutingEnabled,
              fullscreenIntentTransaction == nil,
              fullscreenSpaceIntentGeneration == nil,
              !isSuspendedForPermissionLoss,
              // Already inside a fullscreen space (the strip is hidden anyway) -> nothing to flash, do not interfere.
              !visibilityState.hideReasons.contains(.fullscreen) else {
            return
        }
        fullscreenIntentGeneration &+= 1
        let generation = fullscreenIntentGeneration
        fullscreenSpaceIntentGeneration = generation
        fullscreenProbeGeneration &+= 1
        visibilityState.beginFullscreenTransition(generation: generation)

        // Fade out, then hide (owner's 2026-08-30 enter/exit animation request). **Only this space path may fade**:
        // arrow keys lead the space switch by ~550ms and three-finger swipes by ~950-1130ms (measured), so a 0.15s fade-out finishes with ample margin before
        // WindowServer captures the transition snapshot; the green-button path leads by only tens of ms and must keep a
        // synchronous instant orderOut. The handoff returns immediately after scheduling the fade-out, so input is not blocked.
        // The logical state is set to "hidden" right away: otherwise the asynchronous reconcile at the end of this function would see shouldShow=false and
        // panelsAreVisible=true and take the hard orderOut directly, bypassing the fade-out. The visual orderOut waits for the fade-out to finish.
        panelsAreVisible = false
        lastHideWasForFullscreen = true
        onLogicalVisibilityChanged?(false)
        let fadingPanels = [dockGlassBackgroundPanel, dockPanel, capsulePanel].compactMap { $0 }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            for panel in fadingPanels { panel.animator().alphaValue = 0 }
        }, completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // The prediction may already have been cancelled during the fade-out (timeout / final-review veto); then the strip should not be hidden, so just restore alpha.
                guard self.fullscreenSpaceIntentGeneration == generation else {
                    for panel in fadingPanels { panel.alphaValue = 1 }
                    return
                }
                self.orderOutPanelsForFullscreenPrediction()
                // After hiding, reset alpha: the next show (via whichever path) carries no residual value.
                for panel in fadingPanels { panel.alphaValue = 1 }
            }
        })
        fullscreenIntentLogger.notice(
            "space-pending generation=\(generation, privacy: .public) direction=\(direction.rawValue, privacy: .public)"
        )

        // 2s rather than 1.2s: measured, input to fullscreen confirmation takes 1.05s, leaving only 130ms of margin at 1.2s,
        // and a slightly slower system would time out and pop the task strip back onto the fullscreen picture, exactly the flaw this feature is meant to eliminate.
        let timer = Timer(timeInterval: 2.0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.cancelFullscreenSpaceArrowIntent(generation: generation, reason: "timeout")
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        fullscreenSpaceIntentTimer = timer

        DispatchQueue.main.async { [weak self] in
            guard let self, self.fullscreenSpaceIntentGeneration == generation else { return }
            self.reconcilePanelVisibility()
        }
    }

    private func cancelFullscreenSpaceArrowIntent(generation: UInt64, reason: String) {
        guard fullscreenSpaceIntentGeneration == generation,
              visibilityState.timeoutFullscreenTransition(generation: generation) else {
            return
        }
        clearFullscreenSpaceArrowIntent()
        fullscreenProbeGeneration &+= 1
        fullscreenIntentLogger.notice(
            "space-cancelled reason=\(reason, privacy: .public) generation=\(generation, privacy: .public)"
        )
        reconcilePanelVisibility()
    }

    func clearFullscreenSpaceArrowIntent() {
        fullscreenSpaceIntentGeneration = nil
        fullscreenSpaceIntentTimer?.invalidate()
        fullscreenSpaceIntentTimer = nil
        fullscreenSpaceIntentVerdictTimer?.invalidate()
        fullscreenSpaceIntentVerdictTimer = nil
    }

    /// The space switch is done, but the CG judgment at that moment is untrustworthy. Wait the same 120ms as `FullscreenSpaceHold`,
    /// then use CG (falling back to AX if that fails) for the final judgment; the prediction is revoked only if the final judgment says "not fullscreen".
    private func scheduleFullscreenSpaceIntentVerdict(generation: UInt64) {
        guard fullscreenSpaceIntentVerdictTimer == nil else { return }
        let timer = Timer(
            timeInterval: FullscreenSpaceHoldDecision.postSpaceConfirmationDelay,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.resolveFullscreenSpaceArrowIntent(generation: generation)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        fullscreenSpaceIntentVerdictTimer = timer
    }

    private func resolveFullscreenSpaceArrowIntent(generation: UInt64) {
        guard fullscreenSpaceIntentGeneration == generation else { return }
        fullscreenSpaceIntentVerdictTimer = nil
        if checkFullscreenViaCGSync() {
            applyFullscreenVisibility(true, source: "space-intent-delayed-cg")
            return
        }
        triggerAsyncFullscreenCheck(
            isFinalSpaceIntentVerdict: true,
            source: "space-intent-final-ax"
        )
    }

    @discardableResult
    private func beginFullscreenSpaceHold(
        pid: pid_t?,
        confirmationDelay: TimeInterval
    ) -> UInt64? {
        guard FullscreenSpaceHoldDecision.shouldBegin(
            isFullscreen: visibilityState.hideReasons.contains(.fullscreen),
            hasInputIntent: fullscreenIntentTransaction != nil || fullscreenSpaceIntentGeneration != nil
        ) else {
            return nil
        }

        let screenCGFrame = currentPanelScreenCGFrame()
        let hold: FullscreenSpaceHold
        if let current = fullscreenSpaceHold,
           current.pid == pid,
           current.screenCGFrame == screenCGFrame {
            hold = current
        } else {
            fullscreenSpaceHoldGeneration &+= 1
            fullscreenProbeGeneration &+= 1
            hold = FullscreenSpaceHold(
                generation: fullscreenSpaceHoldGeneration,
                pid: pid,
                screenCGFrame: screenCGFrame
            )
            fullscreenSpaceHold = hold
        }
        scheduleFullscreenSpaceHoldConfirmation(
            generation: hold.generation,
            after: confirmationDelay
        )
        return hold.generation
    }

    private func scheduleFullscreenSpaceHoldConfirmation(
        generation: UInt64,
        after delay: TimeInterval
    ) {
        fullscreenSpaceHoldTimer?.invalidate()
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.confirmFullscreenSpaceHoldWindowed(generation: generation)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        fullscreenSpaceHoldTimer = timer
    }

    private func confirmFullscreenSpaceHoldWindowed(generation: UInt64) {
        guard let hold = fullscreenSpaceHold,
              hold.generation == generation else {
            return
        }
        guard hold.pid == lastActiveApplicationPID,
              hold.screenCGFrame == currentPanelScreenCGFrame() else {
            finishFullscreenSpaceHold(generation: generation)
            triggerAsyncFullscreenCheck(pid: lastActiveApplicationPID)
            return
        }
        fullscreenSpaceHoldTimer = nil
        // A CG true at 120ms is no longer the end point: when exiting fullscreen CG lags by 0.4-0.8s (measured 2026-08-30,
        // `Docs/05`), so a true now is quite possibly still a transitional afterimage, and closing out on it would fall back to "wait 5 seconds for reconciliation".
        // Always let the final-review AX decide: AX has already flipped to false when the exit animation starts (measured the same day, earlier than CG),
        // making it the only trustworthy signal in this direction. The cost for fullscreen -> fullscreen switches is one extra AX read and a confirmation ~100ms later,
        // during which the strip is hidden anyway. The CG reading is kept in source so forensics can tell the two paths apart.
        let cgFullscreen = checkFullscreenViaCGSync()
        triggerAsyncFullscreenCheck(
            pid: hold.pid,
            expectedSpaceHoldGeneration: generation,
            isFinalSpaceHoldWindowedConfirmation: true,
            source: cgFullscreen ? "space-hold-final-ax-cgtrue" : "space-hold-final-ax"
        )
    }

    private func finishFullscreenSpaceHold(generation: UInt64) {
        guard fullscreenSpaceHold?.generation == generation else { return }
        fullscreenSpaceHoldTimer?.invalidate()
        fullscreenSpaceHoldTimer = nil
        fullscreenSpaceHold = nil
    }

    func cancelFullscreenIntentIfContextChanged(activePID: pid_t? = nil) {
        guard let transaction = fullscreenIntentTransaction else { return }
        let currentPID = activePID ?? lastActiveApplicationPID
        guard currentPID != transaction.pid || currentPanelScreenCGFrame() != transaction.screenCGFrame else {
            return
        }
        cancelFullscreenIntent(generation: transaction.generation, reason: "context-changed")
    }

    private func isFullscreenIntentContextCurrent(_ transaction: FullscreenIntentTransaction) -> Bool {
        NSRunningApplication(processIdentifier: transaction.pid)?.isActive == true
            && currentPanelScreenCGFrame() == transaction.screenCGFrame
    }

    func handleFullscreenIntentContextChange(
        _ change: FullscreenIntentMonitor.ContextChange
    ) {
        if case let .activeApplication(pid) = change {
            lastActiveApplicationPID = pid
        }
        guard let transaction = fullscreenIntentTransaction else { return }
        switch change {
        case let .activeApplication(pid):
            if pid != transaction.pid {
                cancelFullscreenIntent(generation: transaction.generation, reason: "app-changed")
            }
        case .focusedWindow:
            cancelFullscreenIntent(generation: transaction.generation, reason: "focus-changed")
        case let .windowDestroyed(windowID):
            if windowID == nil || windowID == transaction.focusedWindowID {
                cancelFullscreenIntent(generation: transaction.generation, reason: "window-destroyed")
            }
        }
    }

    func currentPanelScreenCGFrame() -> CGRect? {
        guard let panel = dockPanel else { return nil }
        return Self.toCGRect(panelCurrentScreen(panel: panel))
    }

    struct FullscreenAXProbe {
        let verdict: FullscreenAXVerdict
        /// Set only when `.fullscreen` came from the frame≈screen fallback (no AXFullScreen flag):
        /// the window the overlay-hide watch keeps an eye on. Native fullscreen never sets it.
        let overlayWindowID: CGWindowID?
    }

    /// If the focused window cannot be read (pid is nil / no focused window) it is still `.windowed`, word-for-word equivalent to the false before three states were introduced.
    nonisolated private static func detectFullscreenViaAX(pid: pid_t?, screenCGFrame: CGRect) -> FullscreenAXProbe {
        guard let pid else { return FullscreenAXProbe(verdict: .windowed, overlayWindowID: nil) }
        let reader = AXWindowReader()
        let appElement = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetMessagingTimeout(appElement, 0.5)

        guard let focused = reader.elementAttribute(kAXFocusedWindowAttribute as CFString, from: appElement) else {
            return FullscreenAXProbe(verdict: .windowed, overlayWindowID: nil)
        }
        _ = AXUIElementSetMessagingTimeout(focused, 0.5)

        let role = reader.stringAttribute(kAXRoleAttribute as CFString, from: focused, maxAttempts: 1)
        let isAXFullscreen = reader.boolAttribute("AXFullScreen" as CFString, from: focused, maxAttempts: 1) ?? false
        // AX kAXPositionAttribute uses CG coordinates (top-left origin) — matches screenCGFrame directly
        let windowFrame = reader.frame(of: focused, maxAttempts: 1)
        // Only the frame fallback consults the layer, so skip the CG round-trip for native fullscreen.
        let cgWindowID = isAXFullscreen ? nil : reader.cgWindowID(for: focused, maxAttempts: 1)
        let windowLayer = cgWindowID.flatMap(Self.cgWindowLayer(of:))

        let verdict = FullscreenWindowClassifier.classify(
            role: role,
            isAXFullscreen: isAXFullscreen,
            windowFrame: windowFrame,
            windowLayer: windowLayer,
            screenCGFrame: screenCGFrame
        )
        return FullscreenAXProbe(
            verdict: verdict,
            overlayWindowID: verdict == .fullscreen && !isAXFullscreen ? cgWindowID : nil
        )
    }

    nonisolated private static func cgWindowLayer(of windowID: CGWindowID) -> Int? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
              let info = list.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID })
        else { return nil }
        return (info[kCGWindowLayer as String] as? NSNumber)?.intValue
    }

    /// When the focused window is on another screen, this screen's strip asks SkyLight "is this screen's current space a native fullscreen space"
    ///(`type == 4`, isolated per display, 0.13ms per call, `Docs/05`). Unreadable -> nil = "no information".
    private func fullscreenVerdictFromSpaceLayout() -> Bool? {
        guard let panel = dockPanel,
              let uuid = DisplayIdentity.uuidString(for: panelCurrentScreen(panel: panel)),
              let layout = ManagedSpaceLayoutReader.layout(forDisplayUUID: uuid) else { return nil }
        return layout.fullscreenSpaceIDs.contains(layout.currentSpaceID)
    }
}
