import Foundation

/// Bounded exponential backoff. Only transport failures are retried. A session
/// that stays running for resetAfter resets the failure streak; startup alone does not.
public struct PresenceRetryPolicy: Sendable {
    public var initialDelay: Duration = .seconds(2)
    public var maximumDelay: Duration = .seconds(60)
    public var resetAfter: Duration = .seconds(120)
    /// Nil keeps retrying transient failures until cancellation; delays remain capped.
    public var maximumRetries: Int? = nil
    public init() {}

    public func validate() throws {
        guard initialDelay >= .milliseconds(100), maximumDelay >= initialDelay,
              maximumDelay <= .seconds(3600), resetAfter >= .seconds(1),
              resetAfter <= .seconds(86_400), maximumRetries.map({ (0...100_000).contains($0) }) ?? true else {
            throw PresenceError.invalidConfiguration("Invalid retry bounds")
        }
    }
    public func delay(forRetry retry: Int) -> Duration {
        var result = initialDelay
        for _ in 0..<(retry <= 1 ? 0 : min(retry - 1, 20)) { result = min(maximumDelay, result * 2) }
        return min(result, maximumDelay)
    }
}

public enum RecognitionFallbackPolicy: Sendable, Equatable {
    /// Continue using motion; add this grace only when changing from present to
    /// absent while requested recognition is degraded. Unknown is never delayed.
    case motionOnly(additionalAbsenceDelay: Duration)
    /// Pause and release the display hold until the recognizer reports active again.
    /// This is an availability policy, NOT a human-only detection mode.
    case pauseUntilRecovered
}

public enum PresenceRecoveryStatus: Sendable, Equatable {
    case monitoring
    case retryScheduled(attempt: Int, delay: Duration, cause: PresenceError)
    case failed(PresenceError)
    case stopped
}

public enum PresenceAutomationEvent: Sendable, Equatable {
    /// Apply playback/display actions to THIS event, not to the raw sensing event.
    case activityChanged(PresenceState)
    case sensing(PresenceEvent)
    case recovery(PresenceRecoveryStatus)
}

extension PresenceError {
    /// Unknown custom errors are not retried by PresenceAutomation. Source authors
    /// should wrap transient transport faults in cameraUnavailable.
    public var isRetryable: Bool {
        switch self {
        case .cameraUnavailable, .sensorStalled, .sourceEnded: true
        case .invalidConfiguration, .cameraConfigurationUnsupported, .alreadyRunning,
             .cameraPermissionDenied, .startupTimedOut, .slowConsumer: false
        }
    }
}

/// Deterministic host policy; timestamps come only from the caller.
struct ActivityPolicy {
    let recognitionRequested: Bool
    let fallback: RecognitionFallbackPolicy
    private(set) var state: PresenceState = .unknown
    private var sensed: PresenceState = .unknown
    private var recognition: RecognitionStatus = .disabled
    private var absenceDeadline: ContinuousClock.Instant?
    init(recognitionRequested: Bool, fallback: RecognitionFallbackPolicy) {
        self.recognitionRequested = recognitionRequested; self.fallback = fallback
    }
    private var degraded: Bool { recognitionRequested && recognition != .active }

    mutating func accept(_ event: PresenceEvent, at now: ContinuousClock.Instant) -> PresenceState? {
        switch event {
        case .statusChanged(.starting):
            sensed = .unknown; recognition = .disabled; absenceDeadline = nil
        case .statusChanged(.recognition(let status)):
            recognition = status
            if !degraded { absenceDeadline = nil }
        case .presenceChanged(let change):
            sensed = change.current
            if sensed != .absent { absenceDeadline = nil }
            else if state == .present, absenceDeadline == nil, degraded,
                    case .motionOnly(let delay) = fallback, delay > .zero {
                absenceDeadline = now.advanced(by: delay)
            }
        default: break
        }
        return tick(at: now)
    }
    mutating func tick(at now: ContinuousClock.Instant) -> PresenceState? {
        let next: PresenceState
        if sensed == .unknown { next = .unknown }
        else if degraded, case .pauseUntilRecovered = fallback { next = .unknown }
        else if sensed == .absent, let deadline = absenceDeadline, now < deadline { next = .present }
        else { next = sensed }
        guard next != state else { return nil }
        state = next
        return next
    }
    mutating func invalidate() {
        sensed = .unknown; state = .unknown; absenceDeadline = nil
    }
}

/// Optional unattended-use layer. One run owns monitor attempts, a tolerant policy
/// timer and one serialized consumer. No overlapping sessions, retry task leaks,
/// or per-frame callback tasks. The raw PresenceMonitor API remains available.
public actor PresenceAutomation {
    private let monitor: PresenceMonitor
    private let configuration: PresenceConfiguration
    private let retry: PresenceRetryPolicy
    private let fallback: RecognitionFallbackPolicy
    private let clock: PresenceClock
    private var policy: ActivityPolicy
    private var running = false
    private var accepting = false
    private var output: AsyncThrowingStream<PresenceAutomationEvent, Error>.Continuation?
    private var delivered: PresenceState = .unknown
    private var terminalError: PresenceError?
    private var healthySince: ContinuousClock.Instant?

    public init(source: any PresenceSource, configuration: PresenceConfiguration = .lowPower,
                retry: PresenceRetryPolicy = .init(),
                fallback: RecognitionFallbackPolicy = .motionOnly(additionalAbsenceDelay: .seconds(120)),
                clock: PresenceClock = .continuous) throws {
        try retry.validate()
        if case .motionOnly(let delay) = fallback, delay < .zero || delay > .seconds(3600) {
            throw PresenceError.invalidConfiguration("Fallback grace must be 0...3600 seconds")
        }
        monitor = try PresenceMonitor(source: source, configuration: configuration, clock: clock)
        self.configuration = configuration; self.retry = retry; self.fallback = fallback; self.clock = clock
        policy = ActivityPolicy(recognitionRequested: configuration.vision.mode != .disabled, fallback: fallback)
    }
    public var currentActivity: PresenceState { policy.state }

    public func run(onEvent: @escaping @Sendable (PresenceAutomationEvent) async -> Void) async throws {
        guard !running else { throw PresenceError.alreadyRunning }
        running = true; accepting = true; delivered = .unknown; terminalError = nil
        policy = ActivityPolicy(recognitionRequested: configuration.vision.mode != .disabled, fallback: fallback)
        let pair = AsyncThrowingStream<PresenceAutomationEvent, Error>.makeStream(
            bufferingPolicy: .bufferingOldest(configuration.eventBufferCapacity))
        output = pair.continuation
        var failure: (any Error)?
        do {
            try Task.checkCancellation()
            await onEvent(.activityChanged(.unknown))
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await self.attempts() }
                group.addTask { try await self.timer() }
                group.addTask {
                    for try await event in pair.stream {
                        try Task.checkCancellation()
                        await self.deliver(event, to: onEvent)
                    }
                }
                do {
                    _ = try await group.next()
                    try Task.checkCancellation()
                    throw terminalError ?? PresenceError.sourceEnded
                }
                catch {
                    accepting = false; policy.invalidate()
                    group.cancelAll()
                    throw error
                }
            }
        } catch { failure = error }
        accepting = false; output?.finish(); output = nil; policy.invalidate()
        if delivered != .unknown { await onEvent(.activityChanged(.unknown)) }
        let cancelled = Task.isCancelled || failure is CancellationError
        if cancelled { await onEvent(.recovery(.stopped)) }
        else if let failure { await onEvent(.recovery(.failed(report(failure)))) }
        running = false
        if cancelled { throw CancellationError() }
        if let failure { throw failure }
    }
    private func attempts() async throws {
        var streak = 0
        while true {
            try Task.checkCancellation()
            healthySince = nil
            do {
                try await monitor.run { [self] event in await accept(event) }
                throw PresenceError.sourceEnded
            } catch {
                try Task.checkCancellation()
                guard let typed = error as? PresenceError, typed.isRetryable else { throw error }
                if let since = healthySince, since.duration(to: clock.now) >= retry.resetAfter { streak = 0 }
                if let maximum = retry.maximumRetries, streak >= maximum { throw typed }
                streak = min(streak + 1, 100_001)
                let delay = retry.delay(forRetry: streak)
                let deadline = clock.now.advanced(by: delay)
                try emit(.recovery(.retryScheduled(attempt: streak, delay: delay, cause: typed)))
                try await clock.sleep(until: deadline)
            }
        }
    }
    private func accept(_ event: PresenceEvent) {
        guard accepting else { return }
        do {
            // Apply output policy before delivering raw evidence to the application.
            if let state = policy.accept(event, at: clock.now) { try emit(.activityChanged(state)) }
            try emit(.sensing(event))
            if case .statusChanged(.running) = event {
                healthySince = clock.now
                try emit(.recovery(.monitoring))
            }
        } catch {
            terminalError = error as? PresenceError ?? .slowConsumer
            accepting = false; policy.invalidate()
            output?.finish(throwing: error)
        }
    }
    private func timer() async throws {
        while true {
            try await clock.sleep(until: clock.now.advanced(by: configuration.watchdogInterval))
            guard accepting else { return }
            if let state = policy.tick(at: clock.now) { try emit(.activityChanged(state)) }
        }
    }
    private func deliver(_ event: PresenceAutomationEvent, to handler: @Sendable (PresenceAutomationEvent) async -> Void) async {
        guard accepting else { return }
        if case .activityChanged(let state) = event { delivered = state }
        await handler(event)
    }
    private func emit(_ event: PresenceAutomationEvent) throws {
        guard let output, accepting else { return }
        if case .dropped = output.yield(event) { throw PresenceError.slowConsumer }
    }
    private func report(_ error: any Error) -> PresenceError {
        error as? PresenceError ?? .cameraUnavailable(String(describing: error))
    }
}
