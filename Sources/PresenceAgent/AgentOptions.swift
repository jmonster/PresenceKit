import Foundation
import PresenceKit

/// Kept portable so invalid command lines fail before camera/power side effects.
struct AgentOptions {
    var configuration = PresenceConfiguration.lowPower
    var fallback: RecognitionFallbackPolicy = .motionOnly(additionalAbsenceDelay: .seconds(120))
    var mediaPath: String?
    var manageDisplay = false
    var keepAwake = false
    var loop = false
    var inputGraceSeconds = 60.0

    init(arguments: [String]) throws {
        var i = 0, human = false, face = false, absence: Double?, grace = 120.0, fallbackName = "motion"
        func number(_ value: String, _ name: String) throws -> Double {
            guard let n = Double(value), n.isFinite else { throw PresenceError.invalidConfiguration("\(name) requires a finite number") }
            return n
        }
        while i < arguments.count {
            let arg = arguments[i]; i += 1
            func value() throws -> String {
                guard i < arguments.count, !arguments[i].hasPrefix("--") else {
                    throw PresenceError.invalidConfiguration("Missing value for \(arg)")
                }
                defer { i += 1 }; return arguments[i]
            }
            switch arg {
            case "--media": mediaPath = try value()
            case "--manage-display": manageDisplay = true
            case "--keep-awake": keepAwake = true
            case "--human": human = true
            case "--face": face = true
            case "--cpu-only": configuration.vision.compute = .cpuOnly
            case "--loop": loop = true
            case "--no-loop": loop = false
            case "--input-grace-seconds": inputGraceSeconds = try number(value(), arg)
            case "--absence-seconds": absence = try number(value(), arg)
            case "--fallback-grace-seconds": grace = try number(value(), arg)
            case "--fallback": fallbackName = try value()
            case "--check-config": break
            default: throw PresenceError.invalidConfiguration("Unknown option: \(arg)")
            }
        }
        guard !(human && face) else { throw PresenceError.invalidConfiguration("Choose --human OR --face") }
        if human { configuration.vision.mode = .humanRectangles }
        if face { configuration.vision.mode = .faceRectangles }
        // Validate before Duration conversion; a finite Double can still overflow.
        if let absence, !(1...86_400).contains(absence) {
            throw PresenceError.invalidConfiguration("Absence delay must be 1...86400 seconds")
        }
        configuration.absenceDelay = .seconds(absence ?? (human || face ? 240 : 120))
        guard (0...3600).contains(grace) else { throw PresenceError.invalidConfiguration("Fallback grace must be 0...3600 seconds") }
        switch fallbackName {
        case "motion": fallback = .motionOnly(additionalAbsenceDelay: .seconds(grace))
        case "pause": fallback = .pauseUntilRecovered
        default: throw PresenceError.invalidConfiguration("--fallback must be motion or pause")
        }
        guard (0...3600).contains(inputGraceSeconds) else {
            throw PresenceError.invalidConfiguration("Input grace must be 0...3600 seconds")
        }
        if fallback == .pauseUntilRecovered, configuration.vision.mode == .disabled {
            throw PresenceError.invalidConfiguration("--fallback pause requires --human or --face")
        }
        try configuration.validate()
    }
}
