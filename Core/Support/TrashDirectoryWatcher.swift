import AppKit
import CoreServices

/// Reports that something changed in a Trash directory, so the chip can ask Finder for a count
/// without waiting for the next app activation. The handler runs on the main thread.
protocol TrashDirectoryObserving: AnyObject {
    func start(onChange: @escaping @MainActor () -> Void)
    func stop()
}

/// FSEvents on the home Trash and each local volume's `.Trashes/<uid>`. FSEvents is the only
/// route without Full Disk Access: `open(O_EVTONLY)` on `~/.Trash` fails (so a kqueue /
/// `DispatchSourceFileSystemObject` watcher cannot be built on it), while fseventsd still delivers
/// directory-level events for the path. A path that does not exist yet is accepted and starts
/// reporting once it is created. The stream is rebuilt on mount / unmount so new volumes join.
final class TrashDirectoryWatcher: TrashDirectoryObserving {
    /// Events within this window after the first one arrive together: a multi-file delete is one
    /// report, hence one count, instead of one per file.
    static let latency: TimeInterval = 0.5

    private let directories: @Sendable () -> [URL]
    private let notificationCenter: NotificationCenter
    private let workQueue: DispatchQueue
    private var onChange: (@MainActor () -> Void)?
    private var stream: FSEventStreamRef?
    private var mountObservers: [NSObjectProtocol] = []
    private var generation: UInt64 = 0

    /// `directories` is read off the main thread: enumerating volumes can stall on a dead mount.
    init(directories: @escaping @Sendable () -> [URL], notificationCenter: NotificationCenter,
         workQueue: DispatchQueue) {
        self.directories = directories
        self.notificationCenter = notificationCenter
        self.workQueue = workQueue
    }

    deinit {
        tearDownStream()
    }

    func start(onChange: @escaping @MainActor () -> Void) {
        guard self.onChange == nil else { return }
        self.onChange = onChange
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            mountObservers.append(notificationCenter.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in self?.rebuild()
            })
        }
        rebuild()
    }

    func stop() {
        onChange = nil
        generation &+= 1
        for observer in mountObservers { notificationCenter.removeObserver(observer) }
        mountObservers.removeAll()
        tearDownStream()
    }

    private func rebuild() {
        generation &+= 1
        let current = generation
        let directories = directories
        workQueue.async { [weak self] in
            let paths = directories().map(\.path)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == current, self.onChange != nil else { return }
                self.install(paths: paths)
            }
        }
    }

    private func install(paths: [String]) {
        tearDownStream()
        guard !paths.isEmpty else { return }
        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<TrashDirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
            watcher.report()
        }
        // No `kFSEventStreamCreateFlagNoDefer`: the first event waits out `latency` too, so a burst
        // of deletes collapses into one report.
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagUseCFTypes)
        guard let stream = FSEventStreamCreate(nil, callback, &context, paths as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                               Self.latency, flags) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return
        }
        self.stream = stream
    }

    private func report() {
        guard let onChange else { return }
        MainActor.assumeIsolated { onChange() }
    }

    private func tearDownStream() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
