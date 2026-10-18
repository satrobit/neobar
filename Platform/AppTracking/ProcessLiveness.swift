import Darwin
import Foundation

/// The sole contract for process-liveness checks (POSIX `kill(pid, 0)`).
///
/// The bulk-delete path of `AppTracker.reconcile()` used to use `NSRunningApplication(processIdentifier:) == nil`
/// to decide death. That API resolves through LaunchServices and transiently returns `nil` for **live** processes (observed with Feishu, Obsidian, etc.),
/// causing the whole `AppEntry` and all its seats to be deleted at once by the bulk path of `reconcile()`, bypassing the per-seat grace and
/// phantom protection. After that `scanNonAdmittedApps()` re-admitted the same pid with a brand-new seat token, and combined with
/// `StripOrderStore`'s 5s absence grace -> one window showing two cards.
///
/// Only POSIX is used here: `kill` returning 0 means alive; dead only when it returns -1 and `errno == ESRCH`; `EPERM` (the process exists
/// but we have no permission to signal it) and all other errnos are conservatively treated as alive. **Never** fall back to `NSRunningApplication` /
/// `NSWorkspace` / any other LaunchServices state. The same-named file in the old dirty worktree fell back to
/// LaunchServices on unknown errno, which is a wrong implementation and must not be carried over wholesale.
///
/// Depends only on Darwin, without importing AppKit / ApplicationServices, to make errno-matrix unit tests easy.
enum ProcessLiveness {
    /// Use POSIX `kill(pid, 0)` to decide whether a process is alive.
    static func isAlive(pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        return interpret(result: kill(pid, 0), errorCode: errno)
    }

    /// Pure decision function, so errno-matrix unit tests can feed synthetic values directly without issuing a syscall:
    /// - `result == 0`: alive
    /// - `result != 0` and `errorCode == ESRCH`: dead (no such process)
    /// - `EPERM` and all other errnos such as `EINTR` / `EINVAL` / `EAGAIN`: alive (conservatively treated as alive)
    static func interpret(result: Int32, errorCode: Int32) -> Bool {
        if result == 0 { return true }
        return errorCode != ESRCH
    }

    /// The process **start time** (`KERN_PROC_PID` sysctl reading `kinfo_proc.kp_proc.p_starttime`).
    ///
    /// Purpose: pids get reused. During an async probe, process A may exit and its pid be taken over by B, and then
    /// `isTerminated` / `activationPolicy` can't detect "the instance changed hands" -- `pid + start time` is the stable
    /// process-generation identity. **Do not use `NSRunningApplication.launchDate`**: it can be nil, and when missing you either let it through
    ///(preloading the old process's AX element into the new process) or reject it (some apps could never enter the supplementary scan) -- pitfalls both ways;
    /// sysctl always has a value for a live process.
    ///
    /// Returns nil = the process no longer exists (when the pid doesn't exist sysctl returns 0 but sets size to 0, so size must be checked).
    static func startTime(pid: pid_t) -> timeval? {
        guard pid > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let result = sysctl(&mib, u_int(mib.count), &info, &size, nil, 0)
        guard result == 0, size > 0 else { return nil }
        return info.kp_proc.p_starttime
    }
}

/// Values valid for one process generation (`pid` + start time), remembered across LaunchServices
/// hiccups: a pid lookup such as `GetProcessForPID` fails transiently for a live process (the same
/// instant `NSRunningApplication(processIdentifier:)` returns nil), and a value seen earlier stays
/// correct as long as the pid still belongs to the same process. Thread-safe; readers sit on the
/// concurrent action queue. `startTime` is injectable for tests only.
final class ProcessGenerationCache<Value> {
    private struct Entry {
        let startTime: timeval
        let value: Value
    }

    private var entries: [pid_t: Entry] = [:]
    private let lock = NSLock()
    private let startTime: (pid_t) -> timeval?

    init(startTime: @escaping (pid_t) -> timeval? = ProcessLiveness.startTime(pid:)) {
        self.startTime = startTime
    }

    func remember(_ value: Value, for pid: pid_t) {
        guard let start = startTime(pid) else { return }
        lock.lock(); defer { lock.unlock() }
        entries[pid] = Entry(startTime: start, value: value)
    }

    /// nil when nothing was remembered, the process is gone, or the pid now belongs to a new process.
    func value(for pid: pid_t) -> Value? {
        guard let start = startTime(pid) else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[pid],
              entry.startTime.tv_sec == start.tv_sec, entry.startTime.tv_usec == start.tv_usec else {
            entries[pid] = nil
            return nil
        }
        return entry.value
    }
}
