import Foundation

/// Races an async operation against a deadline and returns `nil` when the
/// deadline wins. Used to bound the on-device FoundationModels calls (quiz
/// generation, briefing summary, meeting extraction): a slow model must
/// never hold a screen, the caller falls back silently instead.
///
/// The operation runs in a detached task and is cancelled when the deadline
/// fires, but the result is delivered without waiting for it to wind down
/// (a structured task group would block until a non-cooperative child
/// returns, which defeats the timeout).
enum AsyncTimeout {
    static func run<T: Sendable>(
        _ timeout: Duration,
        operation: @escaping @Sendable () async -> T?
    ) async -> T? {
        let race = Race<T>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
                race.install(continuation)
                let work = Task.detached {
                    let value = await operation()
                    race.finish(value)
                }
                let timer = Task.detached {
                    try? await Task.sleep(for: timeout)
                    race.finish(nil)
                }
                race.attach(work, timer)
            }
        } onCancel: {
            race.finish(nil)
        }
    }

    /// Resumes the continuation exactly once, whichever side finishes first.
    private final class Race<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T?, Never>?
        private var tasks: [Task<Void, Never>] = []
        private var done = false

        func install(_ continuation: CheckedContinuation<T?, Never>) {
            lock.lock()
            if done {
                lock.unlock()
                continuation.resume(returning: nil)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }

        func attach(_ work: Task<Void, Never>, _ timer: Task<Void, Never>) {
            lock.lock()
            let alreadyDone = done
            if !alreadyDone { tasks = [work, timer] }
            lock.unlock()
            if alreadyDone {
                work.cancel()
                timer.cancel()
            }
        }

        func finish(_ value: T?) {
            lock.lock()
            guard !done else {
                lock.unlock()
                return
            }
            done = true
            let continuation = self.continuation
            self.continuation = nil
            let tasks = self.tasks
            self.tasks = []
            lock.unlock()
            // Cancel the loser: the model when the deadline won, the timer
            // when the model answered first (no-op on the finished one).
            tasks.forEach { $0.cancel() }
            continuation?.resume(returning: value)
        }
    }
}
