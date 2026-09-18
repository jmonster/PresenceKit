import Foundation

/// Own the lifetime with a task: cancellation stops capture, drains in-flight
/// work, and publishes unknown. A single monitor allows one run at a time.
public actor PresenceMonitor {
    private let source: any PresenceSource
    private let configuration: PresenceConfiguration
    private var reducer: PresenceReducer
    private var running = false
    private var deliveredPresence: PresenceState = .unknown
    private var deliveredLighting: LightingState = .unknown
    private var began: ContinuousClock.Instant?
    private var output: AsyncThrowingStream<PresenceEvent, Error>.Continuation?
    private let clock = ContinuousClock()

    public init(source: any PresenceSource, configuration: PresenceConfiguration = .lowPower) throws {
        try configuration.validate()
        self.source = source; self.configuration = configuration
        reducer = PresenceReducer(config: configuration)
    }

    public var currentState: PresenceState { reducer.presence }

    /// Callbacks are awaited in order by ONE consumer task, independent of the
    /// acquisition task. They are not implicitly MainActor-isolated. Keep them
    /// short and cancellation-cooperative. Overflow fails rather than dropping edges.
    public func run(onEvent: @escaping @Sendable (PresenceEvent) async -> Void) async throws {
        guard !running else { throw PresenceError.alreadyRunning }
        running = true
        reducer = PresenceReducer(config: configuration)
        deliveredPresence = .unknown; deliveredLighting = .unknown
        let pair = AsyncThrowingStream<PresenceEvent, Error>.makeStream(
            bufferingPolicy: .bufferingOldest(configuration.eventBufferCapacity))
        output = pair.continuation
        var failure: (any Error)?
        do {
            try Task.checkCancellation()
            let samples = try await source.start()
            try Task.checkCancellation()
            began = clock.now
            try emit(.presenceChanged(.init(previous: .unknown, current: .unknown, reason: .initial, at: clock.now)))
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { [self] in
                    for try await sample in samples {
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
                defer { group.cancelAll() }
                _ = try await group.next()
            }
        } catch { failure = error }
        // No other event consumer remains. stop() also handles partial startup.
        await source.stop()
        output?.finish(); output = nil
        _ = reducer.invalidate(at: clock.now, reason: .sensorUnavailable)
        let reason: PresenceReason = failure is CancellationError ? .stopped : .sensorUnavailable
        if deliveredPresence != .unknown {
            await onEvent(.presenceChanged(.init(previous: deliveredPresence, current: .unknown, reason: reason, at: clock.now)))
        }
        if deliveredLighting != .unknown {
            await onEvent(.lightingChanged(previous: deliveredLighting, current: .unknown))
        }
        began = nil; running = false
        if let failure { throw failure }
        try Task.checkCancellation()
    }

    private func accept(_ sample: PresenceSample) throws {
        for event in reducer.ingest(sample, now: clock.now) { try emit(event) }
    }
    private func deliver(_ event: PresenceEvent, to callback: @Sendable (PresenceEvent) async -> Void) async {
        switch event {
        case .presenceChanged(let change): deliveredPresence = change.current
        case .lightingChanged(_, let state): deliveredLighting = state
        }
        await callback(event)
    }
    private func emit(_ event: PresenceEvent) throws {
        guard let output else { return }
        if case .dropped = output.yield(event) { throw PresenceError.slowConsumer }
    }
    private func watchdog() async throws {
        while true {
            // Monotonic, cancellable, tolerant sleep; no catch-up bursts after a stall.
            try await clock.sleep(until: clock.now.advanced(by: configuration.watchdogInterval),
                                  tolerance: .milliseconds(100))
            try Task.checkCancellation()
            let now = clock.now
            if let reference = reducer.lastFrame ?? began,
               reference.duration(to: now) >= configuration.sensorTimeout {
                throw PresenceError.sensorStalled
            }
            for event in reducer.tick(at: now) { try emit(event) }
        }
    }
}
