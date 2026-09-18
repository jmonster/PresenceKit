import Foundation

/// One lifecycle-owned run at a time. Failure invalidates logical state before
/// callbacks/driver cleanup are drained; run() returns only after owned cleanup.
public actor PresenceMonitor {
    private let source: any PresenceSource
    private let configuration: PresenceConfiguration
    private let clock: PresenceClock
    private var reducer: PresenceReducer
    private var running = false
    private var accepting = false
    private var deliveredPresence: PresenceState = .unknown
    private var deliveredLighting: LightingState = .unknown
    private var began: ContinuousClock.Instant?
    private var output: AsyncThrowingStream<PresenceEvent, Error>.Continuation?

    public init(source: any PresenceSource, configuration: PresenceConfiguration = .lowPower,
                clock: PresenceClock = .continuous) throws {
        try configuration.validate()
        self.source = source; self.configuration = configuration; self.clock = clock
        reducer = PresenceReducer(config: configuration)
    }

    public var currentState: PresenceState { reducer.presence }
    // Internal diagnostic for deterministic scheduling tests.
    var lastFrameTime: ContinuousClock.Instant? { reducer.lastFrame }

    /// One ordered consumer awaits callbacks independently of capture. Callbacks
    /// are Sendable, not implicitly MainActor-isolated, and must cooperate with
    /// cancellation. Buffer overflow fails instead of silently losing transitions.
    public func run(onEvent: @escaping @Sendable (PresenceEvent) async -> Void) async throws {
        guard !running else { throw PresenceError.alreadyRunning }
        running = true
        reducer = PresenceReducer(config: configuration)
        deliveredPresence = .unknown; deliveredLighting = .unknown
        let pair = AsyncThrowingStream<PresenceEvent, Error>.makeStream(
            bufferingPolicy: .bufferingOldest(configuration.eventBufferCapacity))
        output = pair.continuation
        var session: PresenceSession?
        var failure: (any Error)?
        do {
            try Task.checkCancellation()
            await onEvent(.presenceChanged(.init(previous: .unknown, current: .unknown,
                                                reason: .initial, at: clock.now)))
            await onEvent(.statusChanged(.starting))
            try Task.checkCancellation()
            let acquired = try await acquireSession()
            session = acquired
            try Task.checkCancellation()
            began = clock.now; accepting = true
            try emit(.statusChanged(.running))
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { [self] in
                    for try await sample in acquired.samples {
                        try Task.checkCancellation()
                        try await accept(sample)
                    }
                    try Task.checkCancellation()
                    throw PresenceError.sourceEnded
                }
                group.addTask { [self] in try await watchdog() }
                group.addTask {
                    for try await event in pair.stream {
                        try Task.checkCancellation()
                        await self.deliver(event, to: onEvent)
                    }
                }
                do {
                    _ = try await group.next()
                    try Task.checkCancellation()
                    throw PresenceError.sourceEnded
                } catch {
                    // This happens BEFORE the structured group waits for a slow
                    // callback. No late sample may restore presence during drain.
                    accepting = false
                    _ = reducer.invalidate(at: clock.now, reason: .sensorUnavailable)
                    group.cancelAll()
                    throw error
                }
            }
        } catch { failure = error }

        accepting = false
        output?.finish(); output = nil
        _ = reducer.invalidate(at: clock.now, reason: .sensorUnavailable)
        let cancelled = failure is CancellationError || Task.isCancelled
        let reason: PresenceReason = cancelled ? .stopped : .sensorUnavailable
        // The consumer has finished. Deliver terminal state BEFORE awaiting any
        // potentially slow camera/inference cleanup; callbacks remain serialized.
        if deliveredPresence != .unknown {
            await onEvent(.presenceChanged(.init(previous: deliveredPresence, current: .unknown,
                                                reason: reason, at: clock.now)))
        }
        if deliveredLighting != .unknown {
            await onEvent(.lightingChanged(previous: deliveredLighting, current: .unknown))
        }
        if cancelled {
            await onEvent(.statusChanged(.stopped))
        } else if let failure {
            let reported = failure as? PresenceError ?? .cameraUnavailable(String(describing: failure))
            await onEvent(.statusChanged(.failed(reported)))
        }
        // No global source.stop(): a failed start owns nothing. Only the lease
        // acquired by this run is eligible for cleanup.
        await session?.stop()
        began = nil; running = false
        if cancelled { throw CancellationError() }
        if let failure { throw failure }
    }

    private func acquireSession() async throws -> PresenceSession {
        let source = self.source, clock = self.clock
        let deadline = clock.now.advanced(by: configuration.startupTimeout)
        return try await withThrowingTaskGroup(of: PresenceSession.self) { group in
            group.addTask { try await source.start() }
            group.addTask {
                try await clock.sleep(until: deadline)
                throw PresenceError.startupTimedOut
            }
            var acquired: PresenceSession?
            var failure: (any Error)?
            do { acquired = try await group.next() }
            catch { failure = error }
            group.cancelAll()
            // Drain EVERY outcome: start may win at the same instant as timeout
            // or cancellation. A losing successful start still owns a lease.
            while !group.isEmpty {
                do {
                    if let late = try await group.next() { acquired = late }
                } catch { /* The losing timeout/start child has been cancelled. */ }
            }
            if Task.isCancelled {
                await acquired?.stop()
                throw CancellationError()
            }
            if let failure {
                await acquired?.stop()
                throw failure
            }
            guard let acquired else { throw PresenceError.sourceEnded }
            return acquired
        }
    }

    private func accept(_ sample: PresenceSample) throws {
        guard accepting else { return }
        for event in reducer.ingest(sample, now: clock.now) { try emit(event) }
    }

    private func deliver(_ event: PresenceEvent, to callback: @Sendable (PresenceEvent) async -> Void) async {
        guard accepting else { return }
        switch event {
        case .presenceChanged(let change): deliveredPresence = change.current
        case .lightingChanged(_, let state): deliveredLighting = state
        case .statusChanged: break
        }
        await callback(event)
    }

    private func emit(_ event: PresenceEvent) throws {
        guard let output else { return }
        if case .dropped = output.yield(event) { throw PresenceError.slowConsumer }
    }

    private func watchdog() async throws {
        while true {
            try await clock.sleep(until: clock.now.advanced(by: configuration.watchdogInterval))
            try Task.checkCancellation()
            let now = clock.now
            // Delivery health is separate from analysis freshness. A heartbeat
            // keeps a throttled camera alive without fabricating occupancy evidence.
            if let reference = reducer.lastFrame ?? began,
               reference.duration(to: now) >= configuration.sensorTimeout {
                throw PresenceError.sensorStalled
            }
            guard accepting else { return }
            for event in reducer.tick(at: now) { try emit(event) }
        }
    }
}
