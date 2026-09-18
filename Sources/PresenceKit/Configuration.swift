import Foundation

public struct PresenceConfiguration: Sendable {
    public var startupTimeout: Duration = .seconds(60)
    public var absenceDelay: Duration = .seconds(120)
    public var sensorTimeout: Duration = .seconds(8)
    public var watchdogInterval: Duration = .seconds(1)
    public var entryConfirmationCount = 2
    public var entryWindow: Duration = .seconds(2)
    public var eventBufferCapacity = 32
    public var camera = CameraConfiguration()
    public var motion = MotionConfiguration()
    public var vision = VisionConfiguration()
    public var light = LightConfiguration()

    public init() {}
    /// Conservative starting policy, not a measured energy guarantee.
    public static var lowPower: Self { Self() }

    public func validate() throws {
        func require(_ condition: Bool, _ message: String) throws {
            guard condition else { throw PresenceError.invalidConfiguration(message) }
        }
        func finite(_ value: Double, in range: ClosedRange<Double>) -> Bool {
            value.isFinite && range.contains(value)
        }
        try require(startupTimeout >= .seconds(1) && startupTimeout <= .seconds(300), "startupTimeout must be 1...300 seconds")
        try require(absenceDelay >= .seconds(1) && absenceDelay <= .seconds(86_400), "absenceDelay must be 1 second...1 day")
        try require(sensorTimeout > camera.sampleInterval * 2 && sensorTimeout <= .seconds(120), "sensorTimeout must exceed two sample intervals and be <= 120 seconds")
        try require(watchdogInterval >= .milliseconds(100) && watchdogInterval < sensorTimeout, "watchdogInterval must be >= 100 ms and < sensorTimeout")
        try require((1...20).contains(entryConfirmationCount), "entryConfirmationCount must be 1...20")
        try require(entryWindow >= camera.sampleInterval * (entryConfirmationCount - 1) && entryWindow > .zero && entryWindow <= .seconds(60), "entryWindow cannot accommodate the configured confirmations")
        try require((2...1024).contains(eventBufferCapacity), "eventBufferCapacity must be 2...1024")
        try require(camera.sampleInterval >= .milliseconds(100) && camera.sampleInterval <= .seconds(5), "sampleInterval must be 100 ms...5 seconds")
        try require(camera.warmup >= .zero && camera.warmup < sensorTimeout, "warmup must be nonnegative and less than sensorTimeout")
        try require(finite(camera.requestedFPS, in: 1...30) && finite(camera.maximumFPS, in: camera.requestedFPS...60), "invalid camera frame-rate bounds")
        try require((160...1280).contains(camera.maximumWidth) && (120...720).contains(camera.maximumHeight), "camera dimension caps out of range")
        try require((16...160).contains(camera.gridWidth) && (12...120).contains(camera.gridHeight), "motion grid dimensions out of range")
        let r = camera.region
        try require([r.x, r.y, r.width, r.height].allSatisfy { finite($0, in: 0...1) } && r.width >= 0.05 && r.height >= 0.05 && r.x + r.width <= 1 && r.y + r.height <= 1, "region must fit in the normalized image")
        try require(finite(motion.pixelDifference, in: 0.001...1) && finite(motion.minimumChangedFraction, in: 0.0001...0.99) && finite(motion.maximumChangedFraction, in: motion.minimumChangedFraction...1), "invalid motion thresholds")
        try require(finite(motion.rejectBrightnessJump, in: 0.001...1) && (1...(camera.gridWidth * camera.gridHeight)).contains(motion.minimumConnectedCells), "invalid motion noise rejection")
        try require(finite(motion.maximumDutyCycle, in: 0.001...0.25), "motion duty cycle must be 0.001...0.25")
        try require(vision.minimumInterval >= .seconds(1) && vision.minimumInterval <= .seconds(300), "Vision interval must be 1...300 seconds")
        try require(finite(vision.maximumDutyCycle, in: 0.001...0.25) && vision.maximumInferenceDuration > .zero && vision.maximumInferenceDuration <= .seconds(10), "invalid Vision budget")
        try require(finite(vision.minimumConfidence, in: 0...1) && finite(vision.minimumArea, in: 0...1), "invalid Vision acceptance thresholds")
        if vision.mode != .disabled {
            try require(vision.maximumInferenceDuration < sensorTimeout,
                        "Vision duration budget must be less than sensorTimeout")
            let worstInterval = max(vision.minimumInterval,
                .seconds(vision.maximumInferenceDuration.secondsValue / vision.maximumDutyCycle))
            let required = worstInterval * 2 + sensorTimeout
            try require(absenceDelay >= required,
                        "absenceDelay must be at least \(required.secondsValue) seconds for two budgeted Vision opportunities; increase it or reduce the inference budget")
        }
        try require(finite(light.cameraDarkBelow, in: 0...1) && finite(light.cameraBrightAbove, in: 0...1) && light.cameraDarkBelow < light.cameraBrightAbove, "invalid camera light thresholds")
        try require(light.dwell >= .zero && light.dwell <= .seconds(300), "invalid light dwell")
        if let calibration = light.legacyCalibration {
            try require(calibration.darkBelow.isFinite && calibration.brightAbove.isFinite && calibration.darkBelow >= 0 && calibration.brightAbove > calibration.darkBelow, "invalid legacy sensor calibration")
        }
    }
}

public struct CameraConfiguration: Sendable {
    public var uniqueID: String?
    public var requestedFPS = 5.0
    /// Refuse a format above this cap rather than silently capturing at 30 fps.
    public var maximumFPS = 10.0
    public var maximumWidth = 640
    public var maximumHeight = 480
    public var sampleInterval: Duration = .milliseconds(500)
    public var warmup: Duration = .seconds(3)
    public var gridWidth = 96
    public var gridHeight = 72
    public var region = ImageRegion()
    public init() {}
}

/// Normalized coordinates with a top-left origin. Used by motion AND Vision.
public struct ImageRegion: Sendable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double = 0, y: Double = 0, width: Double = 1, height: Double = 1) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

public struct MotionConfiguration: Sendable {
    public var pixelDifference = 0.065
    public var minimumChangedFraction = 0.025
    public var maximumChangedFraction = 0.65
    public var rejectBrightnessJump = 0.12
    public var minimumConnectedCells = 6
    /// Measured processing wall time / scheduling interval, NOT CPU usage or watts.
    public var maximumDutyCycle = 0.02
    public init() {}
}

public struct VisionConfiguration: Sendable {
    public enum Mode: Sendable { case disabled, humanRectangles, faceRectangles }
    public enum Compute: Sendable { case automatic, cpuOnly }
    public var mode: Mode = .disabled
    /// Let Vision select supported compute. A Neural Engine is NOT required.
    public var compute: Compute = .automatic
    public var minimumInterval: Duration = .seconds(10)
    public var maximumDutyCycle = 0.01
    /// A completed over-budget request disables Vision for this run. Not a preemption deadline.
    public var maximumInferenceDuration: Duration = .seconds(1)
    public var minimumConfidence = 0.6
    public var minimumArea = 0.01
    public init() {}
}

public struct LightConfiguration: Sendable {
    public var enabled = true
    public var cameraDarkBelow = 0.08
    public var cameraBrightAbove = 0.16
    public var dwell: Duration = .seconds(5)
    /// Nil disables the undocumented legacy probe. Camera brightness is the fallback.
    public var legacyCalibration: LegacyLightCalibration?
    public init() {}
}

public struct LegacyLightCalibration: Sendable {
    public var darkBelow: Double, brightAbove: Double
    public init(darkBelow: Double, brightAbove: Double) {
        self.darkBelow = darkBelow; self.brightAbove = brightAbove
    }
}

extension Duration {
    var secondsValue: Double {
        let c = components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }
}
