import Foundation

/// Value-only description of one device format/rate range. Keeping policy out of
/// AVFoundation lets us test hostile driver metadata without opening a camera.
struct CaptureMode: Sendable {
    let width: Int
    let height: Int
    let minimumFPS: Double
    let maximumFPS: Double
}

struct CaptureChoice: Sendable, Equatable {
    let index: Int
    let fps: Double
}

enum CaptureFormatPolicy {
    static func choose(from modes: [CaptureMode], settings: CameraConfiguration) throws -> CaptureChoice {
        guard settings.maximumWidth > 0, settings.maximumHeight > 0,
              settings.requestedFPS.isFinite, settings.requestedFPS > 0,
              settings.maximumFPS.isFinite, settings.maximumFPS >= settings.requestedFPS else {
            throw PresenceError.invalidConfiguration("Invalid capture format limits")
        }
        var best: (choice: CaptureChoice, score: Double)?
        for (index, mode) in modes.enumerated() {
            guard dimensionsFit(width: mode.width, height: mode.height, settings: settings),
                  mode.minimumFPS.isFinite, mode.maximumFPS.isFinite,
                  mode.minimumFPS > 0, mode.maximumFPS >= mode.minimumFPS else { continue }
            let fps = min(mode.maximumFPS, max(mode.minimumFPS, settings.requestedFPS))
            guard fps <= settings.maximumFPS else { continue }
            let score = abs(log(Double(mode.width) / Double(settings.maximumWidth)))
                + abs(log(Double(mode.height) / Double(settings.maximumHeight)))
                + abs(log(fps / settings.requestedFPS))
            if best == nil || score < best!.score {
                best = (CaptureChoice(index: index, fps: fps), score)
            }
        }
        guard let best else {
            throw PresenceError.cameraUnavailable("No format fits the resolution/FPS caps; raise them explicitly only after evaluating power")
        }
        return best.choice
    }

    static func dimensionsFit(width: Int, height: Int, settings: CameraConfiguration) -> Bool {
        width > 0 && height > 0 && width <= settings.maximumWidth && height <= settings.maximumHeight
    }

    /// Validate device readback, not merely what was requested. A minimum frame
    /// duration is a MAXIMUM FPS; maximum duration is a MINIMUM FPS. Reject NaN,
    /// indefinite/zero timings and inverted ranges instead of treating them as safe.
    static func validate(width: Int, height: Int, minimumFrameDuration: Double,
                         maximumFrameDuration: Double, settings: CameraConfiguration) throws {
        guard dimensionsFit(width: width, height: height, settings: settings),
              minimumFrameDuration.isFinite, maximumFrameDuration.isFinite,
              minimumFrameDuration > 0, maximumFrameDuration >= minimumFrameDuration,
              1 / minimumFrameDuration <= settings.maximumFPS + 0.01 else {
            throw PresenceError.cameraUnavailable("Camera configuration exceeds the resolution/FPS caps or reports invalid frame durations")
        }
    }
}
