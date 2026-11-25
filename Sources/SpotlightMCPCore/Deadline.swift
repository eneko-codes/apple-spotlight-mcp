import Foundation
import Synchronization

/// Returns the first of two outcomes: the work finishing, or the limit passing.
///
/// The timer is a dispatch timer, not a `Task.sleep`, and the work is not a child of a task
/// group. A synchronous system call that never returns holds its thread and cannot be
/// cancelled, and a task group would wait for it forever; a timer on the cooperative pool
/// could be starved by the same stuck threads. The stuck work is abandoned, not stopped:
/// its late result is discarded.
enum Deadline {

    private final class Outcome<Value: Sendable>: Sendable {
        private let continuation: Mutex<CheckedContinuation<Value?, Never>?>

        init(_ continuation: CheckedContinuation<Value?, Never>) {
            self.continuation = Mutex(continuation)
        }

        /// Only the first caller resumes; the other finds it empty.
        func resume(returning value: Value?) {
            continuation.withLock { pending in
                pending?.resume(returning: value)
                pending = nil
            }
        }
    }

    /// `nil` when `limit` passed before `work` finished.
    static func run<Value: Sendable>(
        within limit: Duration, _ work: @escaping @Sendable () async -> Value
    ) async -> Value? {
        let seconds = Double(limit.components.seconds) + Double(limit.components.attoseconds) / 1e18
        return await withCheckedContinuation { continuation in
            let outcome = Outcome<Value>(continuation)
            let task = Task {
                outcome.resume(returning: await work())
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                outcome.resume(returning: nil)
                task.cancel()
            }
        }
    }
}
