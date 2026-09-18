import Foundation

/// Deterministic state machine; all timestamps come from the caller. Camera
/// delivery, usable analysis, and positive evidence have independent clocks.
struct PresenceReducer: Sendable {
    let config: PresenceConfiguration
    private(set) var presence: PresenceState = .unknown
    private(set) var lighting: LightingState = .unknown
    private(set) var lastFrame: ContinuousClock.Instant?
    private(set) var lastAnalysis: ContinuousClock.Instant?
    private var began: ContinuousClock.Instant?
    private var lastEvidence: ContinuousClock.Instant?
    private var lastMotion: ContinuousClock.Instant?
    private var lastSemantic: ContinuousClock.Instant?
    private var lastLightMeasurement: ContinuousClock.Instant?
    private var hits: [ContinuousClock.Instant] = []
    private var rawAnalysis: AnalysisStatus = .warmingUp
    private var rawRecognition: RecognitionStatus = .disabled
    private var recognitionDeadline: ContinuousClock.Instant?
    private var publishedAnalysis: AnalysisStatus?
    private var publishedRecognition: RecognitionStatus?
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
        rawAnalysis = sample.analysisStatus
        rawRecognition = sample.recognitionStatus
        recognitionDeadline = sample.recognitionDeadline

        if let analyzed = sample.analyzedAt,
           analyzed <= sample.capturedAt, analyzed.duration(to: now) < config.sensorTimeout,
           lastAnalysis.map({ analyzed > $0 }) ?? true {
            if let last = lastAnalysis, last.duration(to: analyzed) >= config.sensorTimeout {
                events += forgetEvidence(at: now, reason: .analysisUnavailable)
            }
            lastAnalysis = analyzed
            if began == nil { began = analyzed }
        }
        // A cached positive result counts exactly once. Heartbeats cannot turn one
        // motion hit into two confirmations or refresh the absence countdown.
        if let at = sample.motionAt, let analyzed = lastAnalysis, let began,
           at >= began, at <= analyzed, at.duration(to: now) < config.sensorTimeout,
           lastMotion.map({ at > $0 }) ?? true {
            lastMotion = at
            let window = config.entryWindow
            hits.removeAll { $0.duration(to: at) > window }
            if presence == .present {
                lastEvidence = max(lastEvidence ?? at, at)
            } else {
                hits.append(at)
                if hits.count >= config.entryConfirmationCount {
                    lastEvidence = at
                    events += transition(to: .present, reason: .motion, at: now)
                    hits.removeAll(keepingCapacity: true)
                }
            }
        }
        if let evidence = sample.semantic, let began,
           evidence.capturedAt <= sample.capturedAt, evidence.capturedAt >= began,
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
        if config.light.enabled, let measured = sample.lightMeasuredAt,
           measured <= sample.capturedAt, measured.duration(to: now) < config.sensorTimeout,
           lastLightMeasurement.map({ measured > $0 }) ?? true {
            lastLightMeasurement = measured
            events += updateLight(sample.light, at: measured)
        }
        return events
    }

    mutating func tick(at now: ContinuousClock.Instant) -> [PresenceEvent] {
        guard let lastFrame, lastFrame.duration(to: now) < config.sensorTimeout else {
            return invalidate(at: now, reason: .sensorUnavailable)
        }
        var events: [PresenceEvent] = []
        let fresh = lastAnalysis.map { $0.duration(to: now) < config.sensorTimeout } ?? false
        let analysis: AnalysisStatus = fresh ? rawAnalysis : (rawAnalysis == .warmingUp ? .warmingUp : .stale)
        if analysis != publishedAnalysis {
            publishedAnalysis = analysis; events.append(.statusChanged(.analysis(analysis)))
        }
        let overdue = rawRecognition == .active && recognitionDeadline.map { now >= $0 } == true
        let recognition: RecognitionStatus = overdue ? .cadenceExceeded : rawRecognition
        if recognition != publishedRecognition {
            publishedRecognition = recognition; events.append(.statusChanged(.recognition(recognition)))
        }
        guard fresh else {
            return events + forgetEvidence(at: now, reason: .analysisUnavailable)
        }
        if let reference = lastEvidence ?? began, reference.duration(to: now) >= config.absenceDelay {
            // No silent departure while an enabled recognizer has missed its
            // advertised result deadline. Explicitly failed/paused recognition is
            // a typed motion-only fallback, rather than an unannounced one.
            events += transition(to: overdue ? .unknown : .absent,
                                 reason: overdue ? .recognitionUnavailable : .inactivity, at: now)
        }
        return events
    }

    mutating func invalidate(at now: ContinuousClock.Instant, reason: PresenceReason) -> [PresenceEvent] {
        let events = forgetEvidence(at: now, reason: reason)
        lastFrame = nil; lastAnalysis = nil
        return events
    }

    private mutating func forgetEvidence(at now: ContinuousClock.Instant, reason: PresenceReason) -> [PresenceEvent] {
        let events = transition(to: .unknown, reason: reason, at: now)
        began = nil; lastEvidence = nil; lastSemantic = nil; lastMotion = nil
        hits.removeAll(keepingCapacity: true)
        lastLightMeasurement = nil
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
