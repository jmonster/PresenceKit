#if os(macOS)
import Foundation
@preconcurrency import AVFoundation
import CoreVideo
import Vision

public struct CameraStatistics: Sendable {
    public internal(set) var configuredWidth = 0
    public internal(set) var configuredHeight = 0
    public internal(set) var configuredFPS = 0.0
    public internal(set) var analyzedFrames: UInt64 = 0
    public internal(set) var droppedFrames: UInt64 = 0
    public internal(set) var lastMotionMilliseconds = 0.0
    public internal(set) var lastVisionMilliseconds = 0.0
    public internal(set) var visionStatus = "disabled"
    public internal(set) var lastBrightness: Double?
    public internal(set) var lightSource = "unavailable"
}

extension PresenceMonitor {
    public static func camera(configuration: PresenceConfiguration = .lowPower) throws -> PresenceMonitor {
        try PresenceMonitor(source: CameraPresenceSource(configuration: configuration), configuration: configuration)
    }
}

/// The legacy capture API is confined to a dedicated utility serial queue,
/// not an actor's cooperative executor. @unchecked Sendable covers that narrow
/// queue-confinement invariant. Only immutable value samples cross into Swift tasks.
public final class CameraPresenceSource: NSObject, PresenceSource,
    AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let config: PresenceConfiguration
    private let queue = DispatchQueue(label: "PresenceKit.capture", qos: .utility)
    private let visionQueue = DispatchQueue(label: "PresenceKit.vision", qos: .utility)
    // All mutable properties below are touched only on queue.
    private var session: AVCaptureSession?
    private var output: AVCaptureVideoDataOutput?
    private var continuation: AsyncThrowingStream<PresenceSample, Error>.Continuation?
    private var errorObserver: NSObjectProtocol?
    private var motion: MotionDetector
    private var motionGate: WorkGate
    private var visionGate: WorkGate
    private var visionBusy = false
    private var visionDisabled = false
    private var generation = 0
    private var readyAt = ContinuousClock.now
    private var suppressUntil = ContinuousClock.now
    private var semantic: SemanticEvidence?
    private var stats = CameraStatistics()
    private let legacyLight = LegacyLightSensor()
    private var nextLightPoll = ContinuousClock.now
    private var legacyValue: Double?

    public init(configuration: PresenceConfiguration = .lowPower) throws {
        try configuration.validate()
        config = configuration
        motion = MotionDetector(width: configuration.camera.gridWidth, height: configuration.camera.gridHeight, settings: configuration.motion)
        motionGate = WorkGate(minimumInterval: configuration.camera.sampleInterval, maximumDutyCycle: configuration.motion.maximumDutyCycle)
        visionGate = WorkGate(minimumInterval: configuration.vision.minimumInterval, maximumDutyCycle: configuration.vision.maximumDutyCycle)
        super.init()
    }

    public func start() async throws -> AsyncThrowingStream<PresenceSample, Error> {
        try Task.checkCancellation()
        guard await Self.authorize() else { throw PresenceError.cameraPermissionDenied }
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { reply in
            queue.async { [self] in
                guard session == nil else { reply.resume(throwing: PresenceError.alreadyRunning); return }
                do {
                    let pair = AsyncThrowingStream<PresenceSample, Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
                    continuation = pair.continuation
                    try configure()
                    reply.resume(returning: pair.stream)
                } catch {
                    stopSession()
                    reply.resume(throwing: error)
                }
            }
        }
    }

    public func stop() async {
        await withCheckedContinuation { reply in
            queue.async { [self] in stopSession(); reply.resume() }
        }
        // Synchronous Vision cannot be forcibly preempted. Do not return while
        // this source still owns an inference; drain the one-in-flight slot.
        await withCheckedContinuation { reply in visionQueue.async { reply.resume() } }
        await withCheckedContinuation { reply in queue.async { reply.resume() } }
    }

    public func statistics() async -> CameraStatistics {
        await withCheckedContinuation { reply in queue.async { reply.resume(returning: self.stats) } }
    }

    /// Call after your application changes the display/backlight. This is optional;
    /// the library never changes display or system power settings itself.
    public func suppressMotion(for duration: Duration = .seconds(3)) async {
        await withCheckedContinuation { reply in
            queue.async { [self] in
                suppressUntil = ContinuousClock.now.advanced(by: max(.zero, duration))
                motion.reset(); reply.resume()
            }
        }
    }

    private static func authorize() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { reply in
                AVCaptureDevice.requestAccess(for: .video) { reply.resume(returning: $0) }
            }
        default: return false
        }
    }

    private func configure() throws {
        dispatchPrecondition(condition: .onQueue(queue))
        let device: AVCaptureDevice?
        if let id = config.camera.uniqueID {
            device = AVCaptureDevice.devices(for: .video).first { $0.uniqueID == id }
        } else { device = AVCaptureDevice.default(for: .video) }
        guard let device else { throw PresenceError.cameraUnavailable("No matching video device") }
        let s = AVCaptureSession()
        // Store early so failures have an owned session to unwind.
        session = s
        s.beginConfiguration()
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard s.canAddInput(input) else { throw PresenceError.cameraUnavailable("Cannot add camera input") }
            s.addInput(input); s.sessionPreset = .inputPriority
            let out = AVCaptureVideoDataOutput()
            guard s.canAddOutput(out) else { throw PresenceError.cameraUnavailable("Cannot add video output") }
            s.addOutput(out); output = out
            let formats: [OSType] = [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                    kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_32BGRA]
            guard let pixelFormat = formats.first(where: { out.availableVideoPixelFormatTypes.contains($0) }) else {
                throw PresenceError.cameraUnavailable("No supported luminance/BGRA output")
            }
            out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: pixelFormat)]
            out.alwaysDiscardsLateVideoFrames = true
            out.setSampleBufferDelegate(self, queue: queue)
            try selectFormat(device)
            s.commitConfiguration()
        } catch { s.commitConfiguration(); throw error }
        generation += 1; semantic = nil; motion.reset(); visionBusy = false
        motionGate = WorkGate(minimumInterval: config.camera.sampleInterval, maximumDutyCycle: config.motion.maximumDutyCycle)
        visionGate = WorkGate(minimumInterval: config.vision.minimumInterval, maximumDutyCycle: config.vision.maximumDutyCycle)
        visionDisabled = config.vision.mode == .disabled
        stats.visionStatus = visionDisabled ? "disabled" : "enabled"
        let now = ContinuousClock.now
        readyAt = now.advanced(by: config.camera.warmup); suppressUntil = readyAt
        errorObserver = NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: s, queue: nil) { [weak self] note in
            let message = String(describing: note.userInfo?[AVCaptureSessionErrorKey] ?? "capture runtime error")
            self?.queue.async { [weak self] in
                self?.continuation?.finish(throwing: PresenceError.cameraUnavailable(message))
            }
        }
        s.startRunning() // Blocking legacy API; never blocks MainActor or the cooperative pool.
        guard s.isRunning else { throw PresenceError.cameraUnavailable("Capture session failed to start") }
        let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        stats.configuredWidth = Int(dimensions.width); stats.configuredHeight = Int(dimensions.height)
        stats.configuredFPS = 1 / CMTimeGetSeconds(device.activeVideoMinFrameDuration)
        guard stats.configuredWidth <= config.camera.maximumWidth,
              stats.configuredHeight <= config.camera.maximumHeight,
              stats.configuredFPS <= config.camera.maximumFPS + 0.01 else {
            throw PresenceError.cameraUnavailable("Driver did not honor the configured format/rate caps")
        }
    }

    private func selectFormat(_ device: AVCaptureDevice) throws {
        var best: (format: AVCaptureDevice.Format, duration: CMTime, score: Double)?
        for format in device.formats {
            let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard d.width > 0 && d.height > 0 && d.width <= config.camera.maximumWidth && d.height <= config.camera.maximumHeight else { continue }
            for range in format.videoSupportedFrameRateRanges where range.minFrameRate > 0 {
                let fps = min(range.maxFrameRate, max(range.minFrameRate, config.camera.requestedFPS))
                guard fps <= config.camera.maximumFPS else { continue }
                let score = abs(log(Double(d.width) / Double(config.camera.maximumWidth)))
                          + abs(log(Double(d.height) / Double(config.camera.maximumHeight)))
                          + abs(log(fps / config.camera.requestedFPS))
                let duration: CMTime
                if fps <= range.minFrameRate { duration = range.maxFrameDuration }
                else if fps >= range.maxFrameRate { duration = range.minFrameDuration }
                else { duration = CMTime(seconds: 1 / fps, preferredTimescale: 600_000) }
                if best == nil || score < best!.score { best = (format, duration, score) }
            }
        }
        guard let best else { throw PresenceError.cameraUnavailable("No format fits the resolution/FPS caps; explicitly raise them after measuring power") }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        device.activeFormat = best.format
        if CMTimeCompare(best.duration, device.activeVideoMaxFrameDuration) > 0 {
            device.activeVideoMaxFrameDuration = best.duration; device.activeVideoMinFrameDuration = best.duration
        } else {
            device.activeVideoMinFrameDuration = best.duration; device.activeVideoMaxFrameDuration = best.duration
        }
    }

    private func stopSession() {
        dispatchPrecondition(condition: .onQueue(queue))
        generation += 1
        if let errorObserver { NotificationCenter.default.removeObserver(errorObserver) }
        errorObserver = nil
        output?.setSampleBufferDelegate(nil, queue: nil)
        session?.stopRunning(); output = nil; session = nil
        continuation?.finish(); continuation = nil
        legacyLight.close(); legacyValue = nil; semantic = nil
    }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard continuation != nil else { return }
        let now = ContinuousClock.now
        guard motionGate.isDue(at: now), let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        defer {
            let end = ContinuousClock.now
            motionGate.finish(started: now, ended: end)
            stats.lastMotionMilliseconds = now.duration(to: end).secondsValue * 1000
        }
        guard let grid = sampleLuminance(buffer, settings: config.camera) else { return }
        let measurement = motion.measure(grid)
        stats.analyzedFrames += 1
        var light = LightReading(value: measurement.mean)
        if config.light.legacyCalibration != nil {
            if now >= nextLightPoll {
                nextLightPoll = now.advanced(by: .seconds(2))
                legacyValue = legacyLight.read(now: ProcessInfo.processInfo.systemUptime)
            }
            if let value = legacyValue { light = LightReading(value: value, source: .legacyAmbient) }
        }
        stats.lastBrightness = light.value
        stats.lightSource = light.source == .camera ? "camera-luma" : "legacy-raw"
        guard now >= readyAt else { return }
        scheduleVision(buffer, at: now)
        // Timestamp is delegate acquisition time, not the camera's hardware PTS.
        // The cached semantic result retains that original time across inferences.
        continuation?.yield(PresenceSample(capturedAt: now,
            motion: measurement.detected && now >= suppressUntil,
            semantic: semantic, light: config.light.enabled ? light : nil))
    }

    public func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        dispatchPrecondition(condition: .onQueue(queue)); stats.droppedFrames += 1
    }

    private func scheduleVision(_ buffer: CVPixelBuffer, at time: ContinuousClock.Instant) {
        guard !visionDisabled, !visionBusy, visionGate.isDue(at: time) else { return }
        if ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical {
            stats.visionStatus = "paused: thermal pressure"; return
        }
        guard let copy = copyPixelBuffer(buffer) else {
            visionDisabled = true; stats.visionStatus = "disabled: frame-copy failure"; return
        }
        visionBusy = true
        let owned = OwnedPixelBuffer(value: copy)
        let version = generation, config = self.config
        visionQueue.async { [self] in
            let start = ContinuousClock.now
            let result: Result<PresenceEvidence?, PresenceError> = autoreleasepool {
                let request: VNImageBasedRequest
                switch config.vision.mode {
                case .humanRectangles: request = VNDetectHumanRectanglesRequest()
                case .faceRectangles: request = VNDetectFaceRectanglesRequest()
                case .disabled: return .success(nil)
                }
                request.preferBackgroundProcessing = true
                // Compatibility escape hatch for patched Intel graphics. Automatic
                // is the default; do not assume CPU-only is more energy-efficient.
                if config.vision.compute == .cpuOnly { request.usesCPUOnly = true }
                let r = config.camera.region
                request.regionOfInterest = CGRect(x: r.x, y: 1 - r.y - r.height, width: r.width, height: r.height)
                do {
                    try VNImageRequestHandler(cvPixelBuffer: owned.value, orientation: .up, options: [:]).perform([request])
                    let observations = request.results as? [VNDetectedObjectObservation] ?? []
                    let found = observations.contains {
                        Double($0.confidence) >= config.vision.minimumConfidence &&
                        Double($0.boundingBox.width * $0.boundingBox.height) >= config.vision.minimumArea
                    }
                    return .success(found ? (config.vision.mode == .faceRectangles ? .face : .human) : nil)
                } catch { return .failure(.cameraUnavailable("Vision: \(error)")) }
            }
            let end = ContinuousClock.now
            queue.async { [self] in
                visionBusy = false
                guard generation == version, continuation != nil else { return }
                visionGate.finish(started: start, ended: end)
                stats.lastVisionMilliseconds = start.duration(to: end).secondsValue * 1000
                if start.duration(to: end) > config.vision.maximumInferenceDuration {
                    visionDisabled = true; stats.visionStatus = "disabled: inference exceeded duration budget"
                    return
                }
                switch result {
                case .failure(let error): visionDisabled = true; stats.visionStatus = "disabled: \(error)"
                case .success(let evidence):
                    stats.visionStatus = "enabled"
                    if let evidence, time.duration(to: end) < config.sensorTimeout {
                        semantic = SemanticEvidence(kind: evidence, capturedAt: time)
                    }
                }
            }
        }
    }
}

/// A detached, privately-owned copy. No writes occur after construction; only
/// the Vision queue reads it. Camera-pool buffers are never sent across queues.
private struct OwnedPixelBuffer: @unchecked Sendable { let value: CVPixelBuffer }
#endif
