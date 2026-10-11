import Dispatch
import Foundation

/// A timer `Scheduler.schedule` started, which `cancel` stops if it has not run.
package final class Cancellable {
    private var onCancel: (() -> Void)?

    package init(_ onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
    }

    /// A timer that was never started, which there is nothing to stop of.
    package static var none: Cancellable { Cancellable {} }

    package func cancel() {
        let f = onCancel
        onCancel = nil
        f?()
    }
}

/// Where the core runs: one serial queue that owns every field, timer and file of the core, as the Flutter SDK's core
/// is owned by the app's isolate. The app's calls and the platform's signals are posted to it, so nothing of the core
/// is ever touched by two threads, and none of its disk I/O runs on the app's main thread.
package protocol Scheduler: AnyObject {
    /// Runs [task] on the core queue, after everything posted before it.
    func post(_ task: @escaping () -> Void)

    /// Runs [task] on the core queue [delayMicros] from now.
    func schedule(_ delayMicros: Int64, _ task: @escaping () -> Void) -> Cancellable

    /// Whether the caller is on the core queue.
    var onThread: Bool { get }
}

/// The production scheduler: a serial dispatch queue, `kontala`, at utility priority.
package final class QueueScheduler: Scheduler {
    private let queue: DispatchQueue
    private let key = DispatchSpecificKey<UInt8>()
    private let lock = NSLock()
    private var stopped = false

    package init(label: String = "kontala") {
        queue = DispatchQueue(label: label, qos: .utility)
        queue.setSpecific(key: key, value: 1)
    }

    package var onThread: Bool { DispatchQueue.getSpecific(key: key) != nil }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    package func post(_ task: @escaping () -> Void) {
        if isStopped { return }
        queue.async { [weak self] in
            // Stopped: nothing more runs.
            guard let self = self, !self.isStopped else { return }
            task()
        }
    }

    package func schedule(_ delayMicros: Int64, _ task: @escaping () -> Void) -> Cancellable {
        if isStopped { return .none }
        let item = DispatchWorkItem { [weak self] in
            guard let self = self, !self.isStopped else { return }
            task()
        }
        let delay = max(0, min(delayMicros, Int64(Int32.max) * 1_000_000))
        queue.asyncAfter(deadline: .now() + .microseconds(Int(delay)), execute: item)
        return Cancellable { item.cancel() }
    }

    /// Stops running anything posted or scheduled from now on.
    package func shutdown() {
        lock.lock()
        stopped = true
        lock.unlock()
    }
}
