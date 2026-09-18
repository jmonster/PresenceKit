import Foundation
import PresenceKit

/// Kept portable so invalid command lines fail before camera/power side effects.
struct AgentOptions {
    var configuration = PresenceConfiguration.lowPower
    var fallback: RecognitionFallbackPolicy = .motionOnly(additionalAbsenceDelay: .seconds(120))
    var mediaPath: String?
    var manageDisplay = false
    var keepAwake = false
    var loop = true

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
            case "--no-loop": loop = false
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
        configuration.absenceDelay = .seconds(absence ?? (human || face ? 240 : 120))
        guard (0...3600).contains(grace) else { throw PresenceError.invalidConfiguration("Fallback grace must be 0...3600 seconds") }
        switch fallbackName {
        case "motion": fallback = .motionOnly(additionalAbsenceDelay: .seconds(grace))
        case "pause": fallback = .pauseUntilRecovered
        default: throw PresenceError.invalidConfiguration("--fallback must be motion or pause")
        }
        keepAwake = keepAwake || manageDisplay
        try configuration.validate()
    }
}
