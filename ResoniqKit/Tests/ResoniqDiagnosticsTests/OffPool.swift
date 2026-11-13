import Foundation
import Synchronization

/// Runs blocking work (Create ML training, a `say` process) on a thread of its own, never on the Swift concurrency
/// pool, and waits for it with a deadline.
///
/// Why: Create ML's training blocks its thread on a semaphore while it waits for work it has queued on the same
/// pool. Called from an async test, that blocks a pool thread; on a runner with three cores a few such waits starve
/// the pool, and every test in the process stops (CI run 43504323796 hung for 26 minutes). On a thread of its own it
/// blocks only that thread.
///
/// Resumes exactly once: with the work's result, with `TimedOut` after `timeout`, or with `CancellationError` when
/// the task is cancelled. Work still running after that finishes on its thread and its result is dropped.
enum OffPool {
    struct TimedOut: Error, CustomStringConvertible {
        let timeout: Duration
        var description: String { "blocking work did not finish within \(timeout)" }
    }

    static func run<T: Sendable>(timeout: Duration, _ work: @escaping @Sendable () throws -> T) async throws -> T {
        let gate = Gate<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard gate.install(continuation) else { return }
                Thread.detachNewThread { gate.resume(Result { try work() }) }
                let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
                DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { gate.resume(.failure(TimedOut(timeout: timeout))) }
            }
        } onCancel: {
            gate.resume(.failure(CancellationError()))
        }
    }
}

/// A one-shot continuation: the first result wins, later ones are dropped.
private final class Gate<T: Sendable>: Sendable {
    private struct State {
        var continuation: CheckedContinuation<T, any Error>?
        var early: Result<T, any Error>?
        var done = false
    }

    private let state = Mutex(State())

    /// Stores the continuation; false (having resumed it) when a result, a cancellation say, came first.
    func install(_ continuation: CheckedContinuation<T, any Error>) -> Bool {
        let early = state.withLock { state -> Result<T, any Error>? in
            if let early = state.early { state.done = true; return early }
            state.continuation = continuation
            return nil
        }
        guard let early else { return true }
        continuation.resume(with: early)
        return false
    }

    func resume(_ result: Result<T, any Error>) {
        let continuation = state.withLock { state -> CheckedContinuation<T, any Error>? in
            guard !state.done else { return nil }
            guard let continuation = state.continuation else {
                if state.early == nil { state.early = result }
                return nil
            }
            state.done = true
            state.continuation = nil
            return continuation
        }
        continuation?.resume(with: result)
    }
}
