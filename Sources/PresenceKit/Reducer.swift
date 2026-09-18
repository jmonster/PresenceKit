import Foundation

/// Deterministic state machine; all time comes from the caller. Owned by one actor.
struct PresenceReducer: Sendable {
    let config: PresenceConfiguration
    private(set) var presence: PresenceState = .unknown
    private(set) var lighting: LightingState = .unknown
    private(set) var lastFrame: ContinuousClock.Instant?
    private var began: ContinuousClock.Instant?
    private var lastEvidence: ContinuousClock.Instant?
    private var lastSemantic: ContinuousClock.Instant?
    private var hits: [ContinuousClock.Instant] = []
    private var lightSource: LightReading.Source?
    private var lightCandidate: LightingState?
    private var lightCandidateSince: ContinuousClock.Instant?

    init(config: PresenceConfiguration) { self.config = config }

    mutating func ingest(_ sample: PresenceSample, now: ContinuousClock.Instant) -> [PresenceEvent] {
        guard sample.capturedAt <= now,
              sample.capturedAt.duration(to: now) < config.sensorTimeout,
              lastFrame.map({ sample.capturedAt > $0 }) ?? true else { return [] }
        var events: [PresenceEvent] = []
        if let last = lastFrame, last.duration(to: sample.capturedAt) >= config.sensorTimeout {
            events += invalidate(at: now, reason: .sensorUnavailable)
        }
        lastFrame = sample.capturedAt
        if began == nil { began = sample.capturedAt }
        let entryWindow = config.entryWindow
        hits.removeAll { $0.duration(to: sample.capturedAt) > entryWindow }
        if sample.motion {
            if presence == .present {
                lastEvidence = sample.capturedAt
            } else {
                hits.append(sample.capturedAt)
                if hits.count >= config.entryConfirmationCount {
                    lastEvidence = sample.capturedAt
                    events += transition(to: .present, reason: .motion, at: now)
                    hits.removeAll(keepingCapacity: true)
                }
            }
        }
        if let evidence = sample.semantic,
           evidence.capturedAt <= sample.capturedAt,
           evidence.capturedAt >= (began ?? sample.capturedAt),
           evidence.capturedAt.duration(to: now) < config.sensorTimeout,
           lastSemantic.map({ evidence.capturedAt > $0 }) ?? true {
            lastSemantic = evidence.capturedAt
            lastEvidence = max(lastEvidence ?? evidence.capturedAt, evidence.capturedAt)
            let reason: PresenceReason = switch evidence.kind {
            case .motion: .motion
            case .human: .human
            case .face: .face
            }
            events += transition(to: .present, reason: reason, at: now)
        }
        events += tick(at: now)
        if config.light.enabled { events += updateLight(sample.light, at: sample.capturedAt) }
        return events
    }

    mutating func tick(at now: ContinuousClock.Instant) -> [PresenceEvent] {
        guard let lastFrame, lastFrame.duration(to: now) < config.sensorTimeout else {
            return invalidate(at: now, reason: .sensorUnavailable)
        }
        if let reference = lastEvidence ?? began, reference.duration(to: now) >= config.absenceDelay {
            return transition(to: .absent, reason: .inactivity, at: now)
        }
        return []
    }

    mutating func invalidate(at now: ContinuousClock.Instant, reason: PresenceReason) -> [PresenceEvent] {
        let events = transition(to: .unknown, reason: reason, at: now)
        lastFrame = nil; began = nil; lastEvidence = nil; lastSemantic = nil; hits.removeAll(keepingCapacity: true)
        lightCandidate = nil; lightCandidateSince = nil; lightSource = nil
        let previous = lighting; lighting = .unknown
        return events + (previous == .unknown ? [] : [.lightingChanged(previous: previous, current: .unknown)])
    }

    private mutating func transition(to state: PresenceState, reason: PresenceReason,
                                     at now: ContinuousClock.Instant) -> [PresenceEvent] {
        guard presence != state else { return [] }
        let previous = presence; presence = state
        return [.presenceChanged(.init(previous: previous, current: state, reason: reason, at: now))]
    }

    private mutating func updateLight(_ reading: LightReading?, at time: ContinuousClock.Instant) -> [PresenceEvent] {
        guard let reading, reading.value.isFinite else {
            lightCandidate = nil; lightCandidateSince = nil; lightSource = nil
            let previous = lighting; lighting = .unknown
            return previous == .unknown ? [] : [.lightingChanged(previous: previous, current: .unknown)]
        }
        var events: [PresenceEvent] = []
        if reading.source != lightSource {
            let previous = lighting; lighting = .unknown
            if previous != .unknown { events.append(.lightingChanged(previous: previous, current: .unknown)) }
            lightSource = reading.source; lightCandidate = nil; lightCandidateSince = nil
        }
        let thresholds: (Double, Double)
        switch reading.source {
        case .camera: thresholds = (config.light.cameraDarkBelow, config.light.cameraBrightAbove)
        case .legacyAmbient:
            guard let c = config.light.legacyCalibration else { return events }
            thresholds = (c.darkBelow, c.brightAbove)
        }
        let target: LightingState? = reading.value <= thresholds.0 ? .dark : (reading.value >= thresholds.1 ? .bright : nil)
        guard let target, target != lighting else {
            lightCandidate = nil; lightCandidateSince = nil; return events
        }
        if target != lightCandidate { lightCandidate = target; lightCandidateSince = time }
        if let since = lightCandidateSince, since.duration(to: time) >= config.light.dwell {
            events.append(.lightingChanged(previous: lighting, current: target))
            lighting = target; lightCandidate = nil; lightCandidateSince = nil
        }
        return events
    }
}
