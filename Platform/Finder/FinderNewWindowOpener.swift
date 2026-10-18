import AppKit
import Carbon
import OSLog

/// The one place that opens a new Finder window when Finder has none — shared by the taskbar's
/// persistent Finder chip (`PlatformActionExecutor.executeAppFallback`) and the drawer's Finder icon
/// (`LauncherChip.performDefaultTap`). The window goes where Finder's own "New Finder windows show"
/// setting points, as when clicking Finder in the system Dock:
/// 1. Where `FinderReopenEventGate` allows, send Finder the reopen event (`aevt/rapp`); Finder picks
///    the location itself for every option. Only a reported error falls through to step 2.
/// 2. Otherwise open the folder the setting names (`FinderNewWindowTarget`), else the home folder.
///
/// `NSWorkspace.openApplication` is no substitute for step 1: on a windowless Finder it only activates.
/// Blocks for up to `launchTimeout` + 2 × `reopenTimeout`; never call it on the main thread.
enum FinderNewWindowOpener {
    private static let logger = Logger(subsystem: "app.neobar.NeoBar", category: "FinderNewWindow")
    private static let finderBundleID = "com.apple.finder"
    private static let reopenTimeout: TimeInterval = 3
    private static let launchTimeout: TimeInterval = 5
    private static let procNotFound = -600
    /// `kAEDoNotPromptForUserConsent`. The reopen event needs no Automation consent (measured), but a
    /// click must never raise a consent dialog if some macOS version starts asking — it falls back instead.
    private static let noConsentPrompt: UInt = 0x00020000
    private static let directoryProbe = BoundedDirectoryProbe(timeout: 0.5)

    static func openNewWindow() {
        dispatchPrecondition(condition: .notOnQueue(.main))
        let reopenEnabled = FinderReopenEventGate.isEnabled(
            osMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
            killSwitchOn: DebugSwitch.finderReopenEvent.isEnabled()
        )
        if reopenEnabled {
            let startedAt = Date()
            var outcome = sendReopenEvent()
            var launched = false
            if outcome == .failed(procNotFound) {
                launched = launchFinder()
                if launched { outcome = sendReopenEvent() }
            }
            logger.info("访达新窗口 重新打开事件 结果=\(String(describing: outcome), privacy: .public) 先启动访达=\(launched) 耗时ms=\(Int(Date().timeIntervalSince(startedAt) * 1000))")
            guard case .failed = outcome else { return }
        }
        openFromPreference()
    }

    /// Finder can be quit (the chip's own menu offers Quit), and the reopen event does not launch it
    /// (`-600`). Launched this way Finder comes up with no window and then takes the event like a
    /// running Finder, as with the Dock; falling straight back would lose non-folder settings.
    private static func launchFinder() -> Bool {
        guard let finderURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: finderBundleID) else { return false }
        let done = DispatchSemaphore(value: 0)
        let result = LaunchResult()
        NSWorkspace.shared.openApplication(at: finderURL, configuration: NSWorkspace.OpenConfiguration()) { app, error in
            result.succeeded = app != nil && error == nil
            done.signal()
        }
        return done.wait(timeout: .now() + launchTimeout) == .success && result.succeeded
    }

    private final class LaunchResult: @unchecked Sendable {
        var succeeded = false
    }

    private static func sendReopenEvent() -> FinderReopenOutcome {
        if let finder = NSRunningApplication.runningApplications(withBundleIdentifier: finderBundleID).first {
            finder.unhide()
            finder.activate(options: [.activateIgnoringOtherApps])
        }
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEReopenApplication),
            targetDescriptor: NSAppleEventDescriptor(bundleIdentifier: finderBundleID),
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        let options: NSAppleEventDescriptor.SendOptions = [.waitForReply, .neverInteract, .init(rawValue: noConsentPrompt)]
        do {
            let reply = try event.sendEvent(options: options, timeout: reopenTimeout)
            let replyError = reply.paramDescriptor(forKeyword: keyErrorNumber).map { Int($0.int32Value) }
            return FinderReopenOutcome.parse(sendError: nil, replyError: replyError)
        } catch {
            return FinderReopenOutcome.parse(sendError: (error as NSError).code, replyError: nil)
        }
    }

    private static func openFromPreference() {
        let domain = finderBundleID as CFString
        CFPreferencesAppSynchronize(domain)
        let target = CFPreferencesCopyAppValue("NewWindowTarget" as CFString, domain) as? String
        let path = CFPreferencesCopyAppValue("NewWindowTargetPath" as CFString, domain) as? String
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch FinderNewWindowTarget.resolve(target: target, path: path, home: home) {
        case .folder(let url):
            let answer = directoryProbe.check(url)
            logger.info("访达新窗口 按偏好开 设置=\(target ?? "无", privacy: .public) 目录检查=\(String(describing: answer), privacy: .public)")
            if answer == .directory {
                open(url, fallback: home)
            } else {
                open(home, fallback: nil)
            }
        case .home:
            logger.info("访达新窗口 按偏好开 设置=\(target ?? "无", privacy: .public) → 主目录")
            open(home, fallback: nil)
        }
    }

    /// Hands the folder to Finder explicitly, as `FinderTrashClient.openTrash` does; the default
    /// configuration activates Finder, like the plain `NSWorkspace.open` this replaced.
    private static func open(_ url: URL, fallback: URL?) {
        guard let finderURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: finderBundleID) else {
            NSWorkspace.shared.open(url)
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: finderURL, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            guard let error else { return }
            logger.error("访达新窗口 打开失败 error=\(String(describing: error), privacy: .public)")
            if let fallback { open(fallback, fallback: nil) }
        }
    }
}
