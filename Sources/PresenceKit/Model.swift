import Foundation

public enum PresenceState: String, Sendable { case unknown, present, absent }
public enum LightingState: String, Sendable { case unknown, dark, bright }
public enum PresenceEvidence: String, Sendable { case motion, human, face }
public enum PresenceReason: String, Sendable {
    case initial, motion, human, face, inactivity, sensorUnavailable, analysisUnavailable, recognitionUnavailable, stopped
}

public struct PresenceChange: Sendable, Equatable {
    public let previous: PresenceState
    public let current: PresenceState
    public let reason: PresenceReason
    public let at: ContinuousClock.Instant
}

public enum PresenceEvent: Sendable, Equatable {
    /// One event on each state transition, plus an initial unknown snapshot.
    case presenceChanged(PresenceChange)
    case lightingChanged(previous: LightingState, current: LightingState)
    /// Operational changes are separate from evidence of presence or absence.
    case statusChanged(PresenceStatus)
}

/// Only these explicitly classified transport faults are automatically retried.
/// Unclassified driver/programming errors remain terminal, regardless of their text.
public enum CaptureFailureReason: String, Sendable, Equatable {
    case interrupted, disconnected, deviceInUse, mediaServicesReset
}

public enum PresenceError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidConfiguration(String)
    case alreadyRunning
    case cameraPermissionDenied
    case cameraUnavailable(String)
    case captureFailure(CaptureFailureReason)
    case cameraConfigurationUnsupported(String)
    case sensorStalled
    case startupTimedOut
    case sourceEnded
    case slowConsumer

    public var description: String {
        switch self {
        case .invalidConfiguration(let message): "Invalid configuration: \(message)"
        case .alreadyRunning: "This monitor/source already has a running session"
        case .cameraPermissionDenied: "Camera access denied; check the host app's camera permission and usage description"
        case .captureFailure(let reason): "Capture interrupted: \(reason.rawValue)"
        case .cameraUnavailable(let message): "Camera unavailable: \(message)"
        case .cameraConfigurationUnsupported(let message): "Unsupported camera configuration: \(message)"
        case .sensorStalled: "No fresh camera frames arrived within sensorTimeout"
        case .startupTimedOut: "Camera startup exceeded startupTimeout"
        case .sourceEnded: "The presence source ended unexpectedly"
        case .slowConsumer: "The event consumer exceeded its bounded buffer; monitoring stopped instead of silently losing transitions"
        }
    }
}

public struct SemanticEvidence: Sendable {
    public let kind: PresenceEvidence
    /// The original frame time, never inference completion time.
    public let capturedAt: ContinuousClock.Instant
    public init(kind: PresenceEvidence, capturedAt: ContinuousClock.Instant) {
        self.kind = kind; self.capturedAt = capturedAt
    }
}

public struct LightReading: Sendable {
    public enum Source: Sendable { case camera, legacyAmbient }
    public let value: Double
    public let source: Source
    public init(value: Double, source: Source = .camera) {
        self.value = value; self.source = source
    }
}

/// Typed, deduplicated operational notifications. Timing measurements remain in
/// camera statistics; tiny timing fluctuations do not spam status callbacks.
public enum AnalysisStatus: Sendable, Equatable {
    case warmingUp, active, throttled, stale
}
public enum RecognitionFailure: Sendable, Equatable {
    case frameCopyFailed, inferenceFailed(String), durationBudgetExceeded
}
public enum RecognitionStatus: Sendable, Equatable {
    case disabled, warmingUp, active, thermalPressure, cadenceExceeded
    case failed(RecognitionFailure)
}
public enum PresenceStatus: Sendable, Equatable {
    case starting, running, stopped
    case analysis(AnalysisStatus)
    case recognition(RecognitionStatus)
    case failed(PresenceError)
}

/// Immutable latest-value snapshot, never an image. `capturedAt` reports frame
/// delivery independently of analysis. Cached evidence keeps its ORIGINAL time,
/// so heartbeats neither fabricate new evidence nor advance lighting dwell.
public struct PresenceSample: Sendable {
    public let capturedAt: ContinuousClock.Instant
    public let analyzedAt: ContinuousClock.Instant?
    public let motionAt: ContinuousClock.Instant?
    public let semantic: SemanticEvidence?
    public let light: LightReading?
    public let lightMeasuredAt: ContinuousClock.Instant?
    public let analysisStatus: AnalysisStatus
    public let recognitionStatus: RecognitionStatus
    /// Deadline for an enabled recognizer's next result, not proof of absence.
    public let recognitionDeadline: ContinuousClock.Instant?

    /// Convenience for sources that analyze every published frame.
    public init(capturedAt: ContinuousClock.Instant, motion: Bool,
                semantic: SemanticEvidence? = nil, light: LightReading? = nil) {
        self.init(capturedAt: capturedAt, analyzedAt: capturedAt,
                  motionAt: motion ? capturedAt : nil, semantic: semantic, light: light, lightMeasuredAt: capturedAt)
    }

    public init(capturedAt: ContinuousClock.Instant,
                analyzedAt: ContinuousClock.Instant?, motionAt: ContinuousClock.Instant? = nil,
                semantic: SemanticEvidence? = nil, light: LightReading? = nil,
                lightMeasuredAt: ContinuousClock.Instant? = nil,
                analysisStatus: AnalysisStatus = .active,
                recognitionStatus: RecognitionStatus = .disabled,
                recognitionDeadline: ContinuousClock.Instant? = nil) {
        self.capturedAt = capturedAt; self.analyzedAt = analyzedAt
        self.motionAt = motionAt; self.semantic = semantic; self.light = light
        self.lightMeasuredAt = lightMeasuredAt
        self.analysisStatus = analysisStatus; self.recognitionStatus = recognitionStatus
        self.recognitionDeadline = recognitionDeadline
    }
}

/// An exclusive lease, returned ONLY after successful startup. Rejected starts
/// cannot acquire or stop another run's session. Repeated/concurrent stop calls
/// share one cleanup operation and all wait for it. Cleanup must not throw or
/// abandon resources just because the calling task has been cancelled.
public actor PresenceSession {
    public nonisolated let samples: AsyncThrowingStream<PresenceSample, Error>
    private let shutdown: @Sendable () async -> Void
    private var stopping = false
    private var stopped = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(samples: AsyncThrowingStream<PresenceSample, Error>,
                stop: @escaping @Sendable () async -> Void) {
        self.samples = samples; shutdown = stop
    }

    public func stop() async {
        if stopped { return }
        if stopping {
            await withCheckedContinuation { waiters.append($0) }
            return
        }
        stopping = true
        await shutdown()
        stopped = true
        let pending = waiters; waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

/// start() must cooperate with cancellation and unwind its OWN partial startup
/// on failure. On success the caller owns the returned session and must stop it.
/// There is intentionally no global stop() operation on a source.
public protocol PresenceSource: Sendable {
    func start() async throws -> PresenceSession
}

/// Pure rate governor. Late work is skipped, never accumulated or caught up.
/// The caller must serialize admissions and allow only one operation in flight.
struct WorkGate: Sendable {
    let minimumInterval: Duration
    let maximumDutyCycle: Double
    private(set) var next: ContinuousClock.Instant?
    func isDue(at now: ContinuousClock.Instant) -> Bool { next.map { now >= $0 } ?? true }
    mutating func finish(started: ContinuousClock.Instant, ended: ContinuousClock.Instant) {
        let cost = max(0, started.duration(to: ended).secondsValue)
        let cooldown = Duration.seconds(cost * (1 / maximumDutyCycle - 1))
        next = max(started.advanced(by: minimumInterval), ended.advanced(by: cooldown))
    }
}
