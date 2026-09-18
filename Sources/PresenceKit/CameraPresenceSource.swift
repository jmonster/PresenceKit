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
    public internal(set) var analysisStatus: AnalysisStatus = .warmingUp
    public internal(set) var recognitionStatus: RecognitionStatus = .disabled
    public internal(set) var effectiveMotionInterval: Duration = .zero
    public internal(set) var effectiveVisionInterval: Duration = .zero
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
    private let clock: PresenceClock
    private let queue = DispatchQueue(label: "PresenceKit.capture", qos: .utility)
    private let visionQueue = DispatchQueue(label: "PresenceKit.vision", qos: .utility)
    // All mutable properties below are touched only on queue.
    private var leaseID: UUID?
    private var analyzedAt: ContinuousClock.Instant?
    private var motionAt: ContinuousClock.Instant?
    private var lightMeasuredAt: ContinuousClock.Instant?
    private var lightReading: LightReading?
    private var recognitionDeadline: ContinuousClock.Instant?
    private var nextHeartbeat = ContinuousClock.now
    private var session: AVCaptureSession?
    private var device: AVCaptureDevice?
    private var nextFormatCheck = ContinuousClock.now
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

    public init(configuration: PresenceConfiguration = .lowPower, clock: PresenceClock = .continuous) throws {
        try configuration.validate()
        config = configuration; self.clock = clock
        motion = MotionDetector(width: configuration.camera.gridWidth, height: configuration.camera.gridHeight, settings: configuration.motion)
        motionGate = WorkGate(minimumInterval: configuration.camera.sampleInterval, maximumDutyCycle: configuration.motion.maximumDutyCycle)
        visionGate = WorkGate(minimumInterval: configuration.vision.minimumInterval, maximumDutyCycle: configuration.vision.maximumDutyCycle)
        super.init()
    }

    public func start() async throws -> PresenceSession {
        try Task.checkCancellation()
        // Reserve before authorization: only one caller owns startup, even while
        // the permission dialog is unanswered. A rejected caller owns nothing.
        let id: UUID = try await withCheckedThrowingContinuation { reply in
            queue.async { [self] in
                guard leaseID == nil else { reply.resume(throwing: PresenceError.alreadyRunning); return }
                let id = UUID(); leaseID = id; reply.resume(returning: id)
            }
        }
        do {
            try Task.checkCancellation()
            guard try await Self.authorize() else { throw PresenceError.cameraPermissionDenied }
            try Task.checkCancellation()
            let stream: AsyncThrowingStream<PresenceSample, Error> = try await withCheckedThrowingContinuation { reply in
                queue.async { [self] in
                    do {
                        let pair = AsyncThrowingStream<PresenceSample, Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
                        continuation = pair.continuation
                        try configure()
                        reply.resume(returning: pair.stream)
                    } catch { reply.resume(throwing: error) }
                }
            }
            try Task.checkCancellation()
            return PresenceSession(samples: stream) { [self] in await close(lease: id) }
        } catch {
            await close(lease: id)
            throw error
        }
    }

    private func close(lease id: UUID) async {
        let owns: Bool = await withCheckedContinuation { reply in
            queue.async { [self] in
                guard leaseID == id else { reply.resume(returning: false); return }
                stopSession(); reply.resume(returning: true)
            }
        }
        guard owns else { return }
        // Keep the lease reserved until both the inference and its completion
        // callback have drained. A new session cannot overlap old owned work.
        await withCheckedContinuation { reply in visionQueue.async { reply.resume() } }
        await withCheckedContinuation { reply in
            queue.async { [self] in
                if leaseID == id { leaseID = nil }
                reply.resume()
            }
        }
    }

    public func statistics() async -> CameraStatistics {
        await withCheckedContinuation { reply in queue.async { reply.resume(returning: self.stats) } }
    }

    /// Call after your application changes the display/backlight. This is optional;
    /// the library never changes display or system power settings itself.
    public func suppressMotion(for duration: Duration = .seconds(3)) async {
        await withCheckedContinuation { reply in
            queue.async { [self] in
                suppressUntil = clock.now.advanced(by: max(.zero, duration))
                motion.reset(); reply.resume()
            }
        }
    }

    private static func authorize() async throws -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined:
            return try await CallbackLatch<Bool>.wait { reply in
                AVCaptureDevice.requestAccess(for: .video, completionHandler: reply)
            }
        default: return false
        }
    }

    private func configure() throws {
        dispatchPrecondition(condition: .onQueue(queue))
        let device: AVCaptureDevice?
        if let id = config.camera.uniqueID {
            device = AVCaptureDevice(uniqueID: id)
        } else { device = AVCaptureDevice.default(for: .video) }
        guard let device else { throw PresenceError.cameraUnavailable("No matching video device") }
        self.device = device
        let s = AVCaptureSession()
        // Store early so failures have an owned session to unwind.
        session = s
        s.beginConfiguration()
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard s.canAddInput(input) else { throw PresenceError.cameraConfigurationUnsupported("Cannot add camera input") }
            // Do not set a session preset. Input-priority is unavailable on
            // macOS; a quality preset can also undo our explicit device format.
            s.addInput(input)
            let out = AVCaptureVideoDataOutput()
            guard s.canAddOutput(out) else { throw PresenceError.cameraConfigurationUnsupported("Cannot add video output") }
            s.addOutput(out); output = out
            out.alwaysDiscardsLateVideoFrames = true
            out.setSampleBufferDelegate(self, queue: queue)
            s.commitConfiguration()
        } catch { s.commitConfiguration(); throw error }
        // Finalize the graph BEFORE applying the device format and rate. Do not
        // assign a preset or reconfigure the graph after these explicit settings.
        try selectFormat(device)
        guard let out = output else { throw PresenceError.cameraConfigurationUnsupported("Missing video output") }
        let formats: [OSType] = [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_32BGRA]
        guard let pixelFormat = formats.first(where: { out.availableVideoPixelFormatTypes.contains($0) }) else {
            throw PresenceError.cameraConfigurationUnsupported("No supported luminance/BGRA output")
        }
        out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: pixelFormat)]
        try verifyDeviceConfiguration(device)
        generation += 1; semantic = nil; motion.reset(); visionBusy = false
        motionGate = WorkGate(minimumInterval: config.camera.sampleInterval, maximumDutyCycle: config.motion.maximumDutyCycle)
        visionGate = WorkGate(minimumInterval: config.vision.minimumInterval, maximumDutyCycle: config.vision.maximumDutyCycle)
        visionDisabled = config.vision.mode == .disabled
        stats = CameraStatistics()
        setRecognition(visionDisabled ? .disabled : .active)
        let now = clock.now
        readyAt = now.advanced(by: config.camera.warmup); suppressUntil = readyAt
        analyzedAt = nil; motionAt = nil; lightMeasuredAt = nil; lightReading = nil
        nextHeartbeat = now; nextLightPoll = now; nextFormatCheck = now
        recognitionDeadline = visionDisabled ? nil : readyAt.advanced(by: config.vision.maximumInferenceDuration + config.sensorTimeout)
        errorObserver = NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: s, queue: nil) { [weak self] note in
            let message = String(describing: note.userInfo?[AVCaptureSessionErrorKey] ?? "capture runtime error")
            self?.queue.async { [weak self] in
                self?.continuation?.finish(throwing: PresenceError.cameraUnavailable(message))
            }
        }
        s.startRunning() // Blocking legacy API; never blocks MainActor or the cooperative pool.
        guard s.isRunning else { throw PresenceError.cameraUnavailable("Capture session failed to start") }
        try verifyDeviceConfiguration(device)
    }

    private func selectFormat(_ device: AVCaptureDevice) throws {
        // Keep native CMTime endpoints alongside the portable selection metadata.
        // No guessed FPS is assigned to a format that does not advertise it.
        var native: [(AVCaptureDevice.Format, AVFrameRateRange)] = []
        var modes: [CaptureMode] = []
        for format in device.formats {
            let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            for range in format.videoSupportedFrameRateRanges {
                native.append((format, range))
                modes.append(CaptureMode(width: Int(d.width), height: Int(d.height),
                    minimumFPS: range.minFrameRate, maximumFPS: range.maxFrameRate))
            }
        }
        let choice = try CaptureFormatPolicy.choose(from: modes, settings: config.camera)
        let (format, range) = native[choice.index]
        let duration: CMTime
        if choice.fps <= range.minFrameRate { duration = range.maxFrameDuration }
        else if choice.fps >= range.maxFrameRate { duration = range.minFrameDuration }
        else { duration = CMTime(seconds: 1 / choice.fps, preferredTimescale: 600_000) }
        guard duration.isNumeric, CMTimeGetSeconds(duration) > 0,
              CMTimeCompare(duration, range.minFrameDuration) >= 0,
              CMTimeCompare(duration, range.maxFrameDuration) <= 0 else {
            throw PresenceError.cameraConfigurationUnsupported("Camera advertised inconsistent frame-rate metadata")
        }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        device.activeFormat = format
        // Change the outer bound first when lengthening durations so the interim
        // min/max pair is never inverted. Shortening uses the opposite order.
        if CMTimeCompare(duration, device.activeVideoMaxFrameDuration) > 0 {
            device.activeVideoMaxFrameDuration = duration
            device.activeVideoMinFrameDuration = duration
        } else {
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
        }
    }

    private func verifyDeviceConfiguration(_ device: AVCaptureDevice) throws {
        let d = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let minimum = CMTimeGetSeconds(device.activeVideoMinFrameDuration)
        let maximum = CMTimeGetSeconds(device.activeVideoMaxFrameDuration)
        try CaptureFormatPolicy.validate(width: Int(d.width), height: Int(d.height),
            minimumFrameDuration: minimum, maximumFrameDuration: maximum, settings: config.camera)
        stats.configuredWidth = Int(d.width); stats.configuredHeight = Int(d.height)
        stats.configuredFPS = 1 / minimum
    }

    private func failCapture(_ error: any Error) {
        // Stop accepting observations immediately. The monitor owns the lease and
        // will perform ordered teardown after publishing its terminal state.
        output?.setSampleBufferDelegate(nil, queue: nil)
        continuation?.finish(throwing: error)
        continuation = nil
    }

    private func stopSession() {
        dispatchPrecondition(condition: .onQueue(queue))
        generation += 1
        if let errorObserver { NotificationCenter.default.removeObserver(errorObserver) }
        errorObserver = nil
        output?.setSampleBufferDelegate(nil, queue: nil)
        session?.stopRunning(); output = nil; session = nil; device = nil
        continuation?.finish(); continuation = nil
        legacyLight.close(); legacyValue = nil; semantic = nil
    }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard continuation != nil, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let now = clock.now
        // Check delivered dimensions on EVERY frame, before sampling or copying.
        guard CaptureFormatPolicy.dimensionsFit(width: CVPixelBufferGetWidth(buffer),
            height: CVPixelBufferGetHeight(buffer), settings: config.camera) else {
            failCapture(PresenceError.cameraUnavailable("Delivered frame exceeds the configured resolution caps"))
            return
        }
        // Recheck readback cheaply once per second to catch another client/driver
        // changing the shared device after startup. No per-frame device polling.
        if now >= nextFormatCheck, let device {
            nextFormatCheck = now.advanced(by: .seconds(1))
            do { try verifyDeviceConfiguration(device) }
            catch { failCapture(error); return }
        }
        var analyzed = false
        if motionGate.isDue(at: now) {
            if let grid = sampleLuminance(buffer, settings: config.camera) {
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
                lightReading = config.light.enabled ? light : nil
                lightMeasuredAt = now
                if now >= readyAt {
                    analyzedAt = now; analyzed = true
                    if measurement.detected && now >= suppressUntil { motionAt = now }
                }
            }
            let end = clock.now
            motionGate.finish(started: now, ended: end)
            stats.lastMotionMilliseconds = now.duration(to: end).secondsValue * 1000
            stats.effectiveMotionInterval = now.duration(to: motionGate.next ?? end)
            stats.analysisStatus = now < readyAt ? .warmingUp :
                (stats.effectiveMotionInterval > config.camera.sampleInterval + .milliseconds(50) ? .throttled : .active)
        }
        // Recognition is independently admitted, not starved by the motion gate.
        if now >= readyAt { scheduleVision(buffer, at: now) }
        // A cheap delivery heartbeat survives deliberate analysis throttling.
        // Snapshots carry original evidence times, including across dropped samples.
        if analyzed || now >= nextHeartbeat {
            nextHeartbeat = now.advanced(by: min(config.watchdogInterval, .seconds(1)))
            continuation?.yield(PresenceSample(capturedAt: now, analyzedAt: analyzedAt,
                motionAt: motionAt, semantic: semantic, light: lightReading, lightMeasuredAt: lightMeasuredAt,
                analysisStatus: stats.analysisStatus, recognitionStatus: stats.recognitionStatus,
                recognitionDeadline: recognitionDeadline))
        }
    }

    public func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        dispatchPrecondition(condition: .onQueue(queue)); stats.droppedFrames += 1
    }

    private func setRecognition(_ status: RecognitionStatus) {
        stats.recognitionStatus = status
        stats.visionStatus = String(describing: status)
    }

    private func scheduleVision(_ buffer: CVPixelBuffer, at time: ContinuousClock.Instant) {
        guard !visionDisabled, !visionBusy, visionGate.isDue(at: time) else { return }
        if ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical {
            setRecognition(.thermalPressure); recognitionDeadline = nil; return
        }
        guard let copy = copyPixelBuffer(buffer) else {
            visionDisabled = true; setRecognition(.failed(.frameCopyFailed)); recognitionDeadline = nil; return
        }
        visionBusy = true
        setRecognition(.active)
        recognitionDeadline = time.advanced(by: config.vision.maximumInferenceDuration + config.sensorTimeout)
        let owned = OwnedPixelBuffer(value: copy)
        let version = generation, config = self.config
        visionQueue.async { [self] in
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
            let end = clock.now
            queue.async { [self] in
                visionBusy = false
                guard generation == version, continuation != nil else { return }
                // Include copying and queue delay in the measured budget. It is
                // conservative elapsed time, not a CPU/GPU utilization measurement.
                visionGate.finish(started: time, ended: end)
                stats.lastVisionMilliseconds = time.duration(to: end).secondsValue * 1000
                stats.effectiveVisionInterval = time.duration(to: visionGate.next ?? end)
                if time.duration(to: end) > config.vision.maximumInferenceDuration {
                    visionDisabled = true; setRecognition(.failed(.durationBudgetExceeded))
                    recognitionDeadline = nil
                    return
                }
                switch result {
                case .failure(let error):
                    visionDisabled = true; setRecognition(.failed(.inferenceFailed(String(describing: error))))
                    recognitionDeadline = nil
                case .success(let evidence):
                    setRecognition(.active)
                    recognitionDeadline = (visionGate.next ?? end).advanced(by: config.vision.maximumInferenceDuration + config.sensorTimeout)
                    if time.duration(to: end) < config.sensorTimeout {
                        analyzedAt = max(analyzedAt ?? time, time)
                        if let evidence { semantic = SemanticEvidence(kind: evidence, capturedAt: time) }
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
