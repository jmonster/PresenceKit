import Foundation
@testable import PresenceKit

/// Synchronization is locked; continuations always resume outside that lock.
/// Advancing virtual time, rather than elapsed wall time, decides test outcomes.
final class VirtualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock.now
    private var sleepers: [UUID: (ContinuousClock.Instant, CallbackLatch<Void>)] = [:]
    var now: ContinuousClock.Instant { lock.withLock { instant } }
    var pendingSleeps: Int { lock.withLock { sleepers.count } }
    var clock: PresenceClock {
        PresenceClock(now: { self.now }, sleep: { deadline, _ in try await self.sleep(until: deadline) })
    }
    func advance(by duration: Duration) {
        let ready: [CallbackLatch<Void>] = lock.withLock {
            instant = instant.advanced(by: duration)
            let ready = sleepers.filter { $0.value.0 <= instant }
            for id in ready.keys { sleepers.removeValue(forKey: id) }
            return ready.values.map { $0.1 }
        }
        for latch in ready { latch.resolve(.success(())) }
    }
    private func sleep(until deadline: ContinuousClock.Instant) async throws {
        let id = UUID(), latch = CallbackLatch<Void>()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard latch.install(continuation) else { return }
                let immediate = lock.withLock {
                    if deadline <= instant { return true }
                    if !latch.isResolved { sleepers[id] = (deadline, latch) }
                    return false
                }
                if immediate { latch.resolve(.success(())) }
            }
        } onCancel: {
            latch.resolve(.failure(CancellationError()))
            _ = self.lock.withLock { self.sleepers.removeValue(forKey: id) }
        }
    }
}
