import Foundation

/// Why a time-bounded step ended without a result.
public struct DeadlineExceeded: Error, Equatable, Sendable {
    public init() {}
}

/// Runs `operation` and gives up after `timeout`.
///
/// Unlike a task group, the caller gets control back at the deadline even
/// when the operation ignores cancellation for a while: the post-dictation
/// steps (final pass, cleanup) have to end inside the app's background time,
/// so the deadline must hold. The operation is cancelled at the deadline and
/// its late result is dropped.
public func withDeadline<T: Sendable>(
    _ timeout: Duration,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let work = Task { try await operation() }
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            let gate = ResumeOnce(continuation)
            Task {
                do {
                    gate.resume(with: .success(try await work.value))
                } catch {
                    gate.resume(with: .failure(error))
                }
            }
            Task {
                try? await Task.sleep(for: timeout)
                guard gate.resume(with: .failure(DeadlineExceeded())) else { return }
                work.cancel()
            }
        }
    } onCancel: {
        work.cancel()
    }
}

/// Resumes a continuation at most once.
private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, any Error>?

    init(_ continuation: CheckedContinuation<T, any Error>) {
        self.continuation = continuation
    }

    /// Returns whether this call was the one that resumed.
    @discardableResult
    func resume(with result: Result<T, any Error>) -> Bool {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        guard let pending else { return false }
        pending.resume(with: result)
        return true
    }
}
