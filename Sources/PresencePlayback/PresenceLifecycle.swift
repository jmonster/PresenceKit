import Foundation
import PresenceKit

public enum PresenceSuspensionReason: String, Sendable, Hashable {
    case systemSleep, inactiveSession, host
}

/// Shared lifecycle ownership for UI hosts. Suspension cancels an attempt; resume
/// waits for its complete teardown before starting another. Independent reasons
/// are combined, so a wake cannot restart capture in an inactive user session.
@MainActor
public final class PresenceLifecycle {
    public private(set) var suspensionReasons: Set<PresenceSuspensionReason> = []
    private var running = false
    private var revision: UInt64 = 0
    private var generation: UUID?
    private var attempt: Task<Void, Error>?
    private var signal: AsyncStream<Void>.Continuation?
    public init() {}

    public func setSuspended(_ suspended: Bool, for reason: PresenceSuspensionReason) {
        let changed: Bool
        if suspended { changed = suspensionReasons.insert(reason).inserted }
        else { changed = suspensionReasons.remove(reason) != nil }
        guard changed else { return }
        revision &+= 1
        if !suspensionReasons.isEmpty { attempt?.cancel() }
        signal?.yield(())
    }

    public func run(operation: @escaping @MainActor @Sendable () async throws -> Void,
                    onSuspension: @escaping @MainActor @Sendable () async -> Void = {}) async throws {
        guard !running else { throw PresenceError.alreadyRunning }
        running = true
        let id = UUID(); generation = id
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        signal = pair.continuation
        defer { signal?.finish(); signal = nil; generation = nil; attempt = nil; running = false }
        try await withTaskCancellationHandler {
            var changes = pair.stream.makeAsyncIterator()
            while true {
                try Task.checkCancellation()
                if !suspensionReasons.isEmpty {
                    await onSuspension()
                    while !suspensionReasons.isEmpty {
                        guard await changes.next() != nil else { throw CancellationError() }
                        try Task.checkCancellation()
                    }
                }
                try Task.checkCancellation()
                let began = revision
                let current = Task { try await operation() }
                attempt = current
                let result = await current.result // owns and drains teardown even after cancellation
                attempt = nil
                try Task.checkCancellation()
                if began != revision {
                    switch result {
                    case .success: continue
                    case .failure(let error) where error is CancellationError: continue
                    case .failure(let error): throw error
                    }
                }
                try result.get()
                return
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.generation == id else { return }
                self.attempt?.cancel(); self.signal?.finish()
            }
        }
    }
}
