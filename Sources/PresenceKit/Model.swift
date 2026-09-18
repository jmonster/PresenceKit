import Foundation

public enum PresenceState: String, Sendable { case unknown, present, absent }
public enum LightingState: String, Sendable { case unknown, dark, bright }
public enum PresenceEvidence: String, Sendable { case motion, human, face }
public enum PresenceReason: String, Sendable {
    case initial, motion, human, face, inactivity, sensorUnavailable, stopped
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
}

public enum PresenceError: Error, Sendable, CustomStringConvertible {
    case invalidConfiguration(String)
    case alreadyRunning
    case cameraPermissionDenied
    case cameraUnavailable(String)
    case sensorStalled
    case sourceEnded
    case slowConsumer

    public var description: String {
        switch self {
        case .invalidConfiguration(let message): "Invalid configuration: \(message)"
        case .alreadyRunning: "This monitor/source already has a running session"
        case .cameraPermissionDenied: "Camera access denied; check the host app's camera permission and usage description"
        case .cameraUnavailable(let message): "Camera unavailable: \(message)"
        case .sensorStalled: "No fresh camera samples arrived within sensorTimeout"
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

/// A small immutable value; never contains an image or a camera-pool buffer.
public struct PresenceSample: Sendable {
    public let capturedAt: ContinuousClock.Instant
    public let motion: Bool
    public let semantic: SemanticEvidence?
    public let light: LightReading?
    public init(capturedAt: ContinuousClock.Instant, motion: Bool,
                semantic: SemanticEvidence? = nil, light: LightReading? = nil) {
        self.capturedAt = capturedAt; self.motion = motion
        self.semantic = semantic; self.light = light
    }
}

/// A source has one consumer and one session at a time. stop() must finish the
/// stream and await owned work. start() must unwind partial resources on failure.
public protocol PresenceSource: Sendable {
    func start() async throws -> AsyncThrowingStream<PresenceSample, Error>
    func stop() async
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
