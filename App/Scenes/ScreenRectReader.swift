import AppKit
import SwiftUI

protocol ScreenRectDeliveryTask: AnyObject {
    func cancel()
}

protocol ScreenRectDeliveryScheduling: AnyObject {
    @discardableResult
    func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) -> ScreenRectDeliveryTask
}

private final class MainQueueScreenRectDeliveryScheduler: ScreenRectDeliveryScheduling {
    static let shared = MainQueueScreenRectDeliveryScheduler()

    @discardableResult
    func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) -> ScreenRectDeliveryTask {
        let work = DispatchWorkItem(block: action)
        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        } else {
            DispatchQueue.main.async(execute: work)
        }
        return work
    }
}

extension DispatchWorkItem: ScreenRectDeliveryTask {}

/// Reads a SwiftUI host's frame in AppKit screen coordinates. Delivery is asynchronous because
/// writing SwiftUI state synchronously from `layout()` is undefined.
///
/// **There is only one delivery mode: every distinct rect is delivered in order, and duplicates are dropped.** There used to be a 50ms trailing debounce tier,
/// made for the hover bubble: back then each card measured its own anchor, and on hover the card rect changed every frame, so without debouncing the chip
/// would be recomputed repeatedly. After hover became a single whole-strip tracking region on 2026-08-18, the anchor is computed directly from the hit frames on the strip,
/// cards no longer measure themselves, and that tier had no call sites left, so it was deleted together with its `pendingRect` / debounce branch.
struct ScreenRectReader: NSViewRepresentable {
    var scheduler: ScreenRectDeliveryScheduling = MainQueueScreenRectDeliveryScheduler.shared
    let onChange: (CGRect) -> Void

    func makeNSView(context: Context) -> NSView {
        TrackingView(scheduler: scheduler, onChange: onChange)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? TrackingView else { return }
        view.update(onChange: onChange)
        view.report()
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        (nsView as? TrackingView)?.cancelPendingDelivery()
    }

    final class TrackingView: NSView {
        private let scheduler: ScreenRectDeliveryScheduling
        private var onChange: (CGRect) -> Void
        private var lastQueuedImmediateRect: CGRect?
        private var lastReported: CGRect?
        private var pendingTasks: [UUID: ScreenRectDeliveryTask] = [:]
        private var deliveryGeneration: UInt64 = 0
        /// Observer for the host window moving / changing screens, see `observeWindowMovement`.
        private var windowObservers: [NSObjectProtocol] = []

        init(
            scheduler: ScreenRectDeliveryScheduling = MainQueueScreenRectDeliveryScheduler.shared,
            onChange: @escaping (CGRect) -> Void
        ) {
            self.scheduler = scheduler
            self.onChange = onChange
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError() }

        deinit {
            pendingTasks.values.forEach { $0.cancel() }
            windowObservers.forEach(NotificationCenter.default.removeObserver)
        }

        func update(onChange: @escaping (CGRect) -> Void) {
            self.onChange = onChange
        }

        override func viewDidMoveToWindow() {
            observeWindowMovement()
            guard window != nil else {
                cancelPendingDelivery()
                return
            }
            report()
        }

        /// **Also re-report when the window moves.**
        ///
        /// `layout()` fires only when the **view tree** layout changes; moving the whole panel to another screen (hover screen switch)
        /// or up and down (collapse / reveal of edge auto-hide) changes nothing in the view tree, so it never fires here,
        /// and each card's cached screen rect stays at the old position. Actual consequence: the owner reported on 2026-08-17 "sweeping over an
        /// icon on one screen, the bubble sometimes pops up on another screen that has no task strip" -- the anchor was still in the coordinates of the screen before the switch.
        ///
        /// The observer is bound to **its own host window** (`object: window`) and is installed/removed along with `viewDidMoveToWindow`,
        /// the same lifecycle as the existing "cancel all queued deliveries on detach".
        private func observeWindowMovement() {
            windowObservers.forEach(NotificationCenter.default.removeObserver)
            windowObservers = []
            guard let window else { return }
            let center = NotificationCenter.default
            for name in [NSWindow.didMoveNotification, NSWindow.didChangeScreenNotification] {
                windowObservers.append(
                    center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                        self?.report()
                    }
                )
            }
        }

        override func layout() {
            super.layout()
            report()
        }

        func report() {
            guard let window else { return }
            enqueue(window.convertToScreen(convert(bounds, to: nil)))
        }

        func enqueue(_ rect: CGRect) {
            guard rect != lastQueuedImmediateRect else { return }
            lastQueuedImmediateRect = rect
            schedule(after: 0) { [weak self] in self?.deliverIfChanged(rect) }
        }

        func cancelPendingDelivery() {
            cancelScheduledTasks(incrementGeneration: true)
            lastQueuedImmediateRect = nil
        }

        private func schedule(after delay: TimeInterval, action: @escaping () -> Void) {
            let id = UUID()
            let generation = deliveryGeneration
            let task = scheduler.schedule(after: delay) { [weak self] in
                guard let self else { return }
                self.pendingTasks.removeValue(forKey: id)
                guard self.deliveryGeneration == generation else { return }
                action()
            }
            pendingTasks[id] = task
        }

        private func cancelScheduledTasks(incrementGeneration: Bool) {
            pendingTasks.values.forEach { $0.cancel() }
            pendingTasks.removeAll()
            if incrementGeneration { deliveryGeneration &+= 1 }
        }

        private func deliverIfChanged(_ rect: CGRect) {
            guard rect != lastReported else { return }
            lastReported = rect
            onChange(rect)
        }
    }
}
