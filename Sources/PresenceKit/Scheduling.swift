import Foundation

/// A monotonic clock dependency. Inject a virtual implementation in tests; all
/// source timestamps and monitor deadlines must use the same clock domain.
public struct PresenceClock: Sendable {
    private let read: @Sendable () -> ContinuousClock.Instant
    private let suspend: @Sendable (ContinuousClock.Instant, Duration) async throws -> Void

    public init(now: @escaping @Sendable () -> ContinuousClock.Instant,
                sleep: @escaping @Sendable (ContinuousClock.Instant, Duration) async throws -> Void) {
        read = now
        suspend = sleep
    }

    public var now: ContinuousClock.Instant { read() }
    public func sleep(until deadline: ContinuousClock.Instant,
                      tolerance: Duration = .milliseconds(100)) async throws {
        try Task.checkCancellation()
        try await suspend(deadline, tolerance)
        try Task.checkCancellation()
    }

    public static let continuous = PresenceClock(
        now: { ContinuousClock.now },
        sleep: { try await ContinuousClock().sleep(until: $0, tolerance: $1) }
    )
}

/// Bridges callback APIs that cannot cancel the underlying prompt/operation.
/// Cancellation releases the Swift waiter; late and duplicate callbacks are ignored.
/// Never hold this lock while resuming a continuation or invoking external code.
final class CallbackLatch<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, any Error>?
    private var waiter: CheckedContinuation<Value, any Error>?

    var isResolved: Bool {
        lock.lock(); defer { lock.unlock() }
        return result != nil
    }

    func install(_ continuation: CheckedContinuation<Value, any Error>) -> Bool {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
            return false
        }
        precondition(waiter == nil, "A callback latch has exactly one waiter")
        waiter = continuation
        lock.unlock()
        return true
    }

    func resolve(_ value: Result<Value, any Error>) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = value
        let continuation = waiter
        waiter = nil
        lock.unlock()
        continuation?.resume(with: value)
    }

    static func wait(
        register: @Sendable (@escaping @Sendable (Value) -> Void) -> Void
    ) async throws -> Value {
        let latch = CallbackLatch<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if latch.install(continuation) {
                    register { latch.resolve(.success($0)) }
                }
            }
        } onCancel: {
            latch.resolve(.failure(CancellationError()))
        }
    }
}
