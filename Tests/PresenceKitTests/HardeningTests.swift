import XCTest
@testable import PresenceKit

private final class PermissionPrompt: @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [@Sendable (Bool) -> Void] = []
    var count: Int { lock.withLock { replies.count } }
    func register(_ reply: @escaping @Sendable (Bool) -> Void) { lock.withLock { replies.append(reply) } }
    func answer(_ allowed: Bool) {
        let pending = lock.withLock { let copy = replies; replies.removeAll(); return copy }
        // A hostile/misbehaving callback API can even invoke its callback twice.
        for reply in pending { reply(allowed); reply(allowed) }
    }
}

private actor LeaseSource: PresenceSource {
    let prompt: PermissionPrompt?
    let delayedCleanup: Bool
    let returnLeaseOnCancelledStart: Bool
    private var id: UUID?
    private var continuation: AsyncThrowingStream<PresenceSample, Error>.Continuation?
    private var cleanupGate: CheckedContinuation<Void, Never>?
    private(set) var starts = 0
    private(set) var stops = 0
    private(set) var partialUnwinds = 0
    private(set) var cleanupPending = false

    init(prompt: PermissionPrompt? = nil, delayedCleanup: Bool = false,
         returnLeaseOnCancelledStart: Bool = false) {
        self.prompt = prompt; self.delayedCleanup = delayedCleanup
        self.returnLeaseOnCancelledStart = returnLeaseOnCancelledStart
    }
    func start() async throws -> PresenceSession {
        guard id == nil else { throw PresenceError.alreadyRunning }
        let lease = UUID(); id = lease; starts += 1
        do {
            if let prompt {
                do {
                    let allowed = try await CallbackLatch<Bool>.wait { prompt.register($0) }
                    guard allowed else { throw PresenceError.cameraPermissionDenied }
                } catch is CancellationError {
                    if !returnLeaseOnCancelledStart { throw CancellationError() }
                }
            }
            if !returnLeaseOnCancelledStart { try Task.checkCancellation() }
            let pair = AsyncThrowingStream<PresenceSample, Error>.makeStream()
            continuation = pair.continuation
            return PresenceSession(samples: pair.stream) { await self.close(lease) }
        } catch {
            partialUnwinds += 1; id = nil
            throw error
        }
    }
    private func close(_ lease: UUID) async {
        guard id == lease else { return }
        stops += 1
        continuation?.finish(); continuation = nil
        if delayedCleanup { await withCheckedContinuation { cleanupGate = $0; cleanupPending = true } }
        id = nil
    }
    func allowCleanup() { cleanupGate?.resume(); cleanupGate = nil; cleanupPending = false }
    func send(_ sample: PresenceSample) { continuation?.yield(sample) }
    func fail() { continuation?.finish(throwing: PresenceError.cameraUnavailable("synthetic failure")) }
}

private actor Events {
    private(set) var all: [PresenceEvent] = []
    func record(_ event: PresenceEvent) { all.append(event) }
    var states: [PresenceState] {
        all.compactMap { if case .presenceChanged(let change) = $0 { return change.current }; return nil }
    }
}

private actor Suspension {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    func wait() async { await withCheckedContinuation { continuation = $0; entered = true } }
    func open() { continuation?.resume(); continuation = nil }
}

@MainActor
final class HardeningTests: XCTestCase {
    private func eventually(_ predicate: @Sendable () async -> Bool) async throws {
        // Only synchronizes runnable tasks. Virtual time controls actual deadlines.
        for _ in 0..<400 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Synchronization timed out")
        throw PresenceError.sensorStalled
    }
    private func config() -> PresenceConfiguration {
        var c = PresenceConfiguration.lowPower
        c.camera.warmup = .zero; c.entryConfirmationCount = 1; c.light.enabled = false
        return c
    }

    func testBudgetedAnalysisSilenceDoesNotTripDeliveryWatchdog() async throws {
        let time = VirtualClock(), source = LeaseSource(), events = Events()
        var c = config(); c.motion.maximumDutyCycle = 0.001
        let monitor = try PresenceMonitor(source: source, configuration: c, clock: time.clock)
        let task = Task { try await monitor.run { await events.record($0) } }
        try await eventually { await events.all.contains(.statusChanged(.running)) }
        let origin = time.now
        await source.send(.init(capturedAt: origin, motion: true))
        try await eventually { await monitor.currentState == .present }
        var gate = WorkGate(minimumInterval: c.camera.sampleInterval, maximumDutyCycle: c.motion.maximumDutyCycle)
        gate.finish(started: origin, ended: origin.advanced(by: .milliseconds(20)))
        XCTAssertEqual(origin.duration(to: try XCTUnwrap(gate.next)).secondsValue, 20, accuracy: 0.000001)
        for _ in 1...20 {
            time.advance(by: .seconds(1))
            let now = time.now
            await source.send(.init(capturedAt: now, analyzedAt: origin, motionAt: origin,
                                    analysisStatus: .throttled))
            try await eventually { await monitor.lastFrameTime == now }
        }
        let stops = await source.stops, states = await events.states
        XCTAssertEqual(stops, 0)
        XCTAssertEqual(states, [.unknown, .present, .unknown])
        let status = await events.all
        XCTAssertTrue(status.contains(.statusChanged(.analysis(.throttled))))
        XCTAssertTrue(status.contains(.statusChanged(.analysis(.stale))))
        time.advance(by: .milliseconds(1))
        await source.send(.init(capturedAt: time.now, motion: true))
        try await eventually { await monitor.currentState == .present }
        task.cancel(); _ = await task.result
    }

    func testVisionConfigurationRejectsAuditedContradictoryCadence() {
        var c = config(); c.vision.mode = .humanRectangles; c.absenceDelay = .seconds(20)
        XCTAssertThrowsError(try c.validate())
        c.absenceDelay = .seconds(240)
        XCTAssertNoThrow(try c.validate())
    }

    func testCompatibleVisionBudgetKeepsStationaryOccupantPresent() throws {
        var c = config(); c.vision.mode = .humanRectangles
        c.vision.maximumInferenceDuration = .milliseconds(500)
        try c.validate() // 2 * 50s + 8s <= the default 120s grace.
        let origin = ContinuousClock.now
        var gate = WorkGate(minimumInterval: c.vision.minimumInterval, maximumDutyCycle: c.vision.maximumDutyCycle)
        gate.finish(started: origin, ended: origin.advanced(by: .milliseconds(500)))
        XCTAssertEqual(origin.duration(to: try XCTUnwrap(gate.next)).secondsValue, 50, accuracy: 0.000001)
        var reducer = PresenceReducer(config: c)
        _ = reducer.ingest(.init(capturedAt: origin, motion: false), now: origin)
        for halfSecond in 1...300 {
            let now = origin.advanced(by: .milliseconds(halfSecond * 500))
            let lastInference = origin.advanced(by: .seconds(((halfSecond - 1) / 100) * 50))
            let events = reducer.ingest(.init(capturedAt: now, analyzedAt: now,
                semantic: .init(kind: .human, capturedAt: lastInference), recognitionStatus: .active,
                recognitionDeadline: lastInference.advanced(by: .seconds(58.5))), now: now)
            XCTAssertEqual(reducer.presence, .present)
            XCTAssertFalse(events.contains { if case .presenceChanged(let c) = $0 { return c.current == .absent }; return false })
        }
    }

    func testOverdueRecognizerDoesNotProduceSilentDeparture() throws {
        var c = config(); c.vision.mode = .humanRectangles; c.absenceDelay = .seconds(240)
        try c.validate()
        var r = PresenceReducer(config: c)
        let origin = ContinuousClock.now
        _ = r.ingest(.init(capturedAt: origin, motion: true), now: origin)
        var events: [PresenceEvent] = []
        for second in 1...241 {
            let now = origin.advanced(by: .seconds(second))
            events += r.ingest(.init(capturedAt: now, analyzedAt: now,
                recognitionStatus: .active, recognitionDeadline: origin.advanced(by: .seconds(20))), now: now)
        }
        XCTAssertEqual(r.presence, .unknown)
        XCTAssertTrue(events.contains(.statusChanged(.recognition(.cadenceExceeded))))
        XCTAssertFalse(events.contains { if case .presenceChanged(let c) = $0 { return c.current == .absent }; return false })
    }

    func testRejectedSecondMonitorCannotStopFirstSession() async throws {
        let source = LeaseSource(), events = Events()
        let first = try PresenceMonitor(source: source, configuration: config())
        let second = try PresenceMonitor(source: source, configuration: config())
        let task = Task { try await first.run { await events.record($0) } }
        try await eventually { await events.all.contains(.statusChanged(.running)) }
        do { try await second.run { _ in }; XCTFail("Expected rejection") }
        catch PresenceError.alreadyRunning { }
        let stops = await source.stops; XCTAssertEqual(stops, 0)
        await source.send(.init(capturedAt: .now, motion: true))
        try await eventually { await first.currentState == .present }
        task.cancel(); _ = await task.result
    }

    func testFailureNotifiesUnknownBeforeSlowCleanup() async throws {
        let source = LeaseSource(delayedCleanup: true), events = Events()
        let monitor = try PresenceMonitor(source: source, configuration: config())
        let task = Task { try await monitor.run { await events.record($0) } }
        try await eventually { await events.all.contains(.statusChanged(.running)) }
        await source.send(.init(capturedAt: .now, motion: true))
        try await eventually { await events.states == [.unknown, .present] }
        await source.fail()
        try await eventually { await source.cleanupPending }
        let current = await monitor.currentState, states = await events.states
        XCTAssertEqual(current, .unknown)
        XCTAssertEqual(states, [.unknown, .present, .unknown])
        do { try await monitor.run { _ in }; XCTFail("A draining monitor must remain exclusive") }
        catch PresenceError.alreadyRunning { }
        await source.allowCleanup()
        _ = await task.result
        let stops = await source.stops; XCTAssertEqual(stops, 1)
    }

    func testCancellationReleasesPermissionWaitAndIgnoresLateAnswer() async throws {
        let prompt = PermissionPrompt(), events = Events()
        let source = LeaseSource(prompt: prompt)
        let monitor = try PresenceMonitor(source: source, configuration: config())
        let task = Task { try await monitor.run { await events.record($0) } }
        try await eventually { prompt.count == 1 }
        task.cancel()
        do { try await task.value; XCTFail("Expected cancellation") } catch is CancellationError { }
        prompt.answer(true)
        let stops = await source.stops, unwinds = await source.partialUnwinds
        XCTAssertEqual(stops, 0); XCTAssertEqual(unwinds, 1)
        // Restart is possible; the late answer did not start a hidden session.
        let restarted = Task { try await monitor.run { await events.record($0) } }
        try await eventually { prompt.count == 1 }
        prompt.answer(true)
        try await eventually { await events.all.contains(.statusChanged(.running)) }
        restarted.cancel(); _ = await restarted.result
        let finalStops = await source.stops; XCTAssertEqual(finalStops, 1)
    }

    func testVirtualStartupTimeoutUnwindsPermissionReservation() async throws {
        let prompt = PermissionPrompt(), time = VirtualClock(), events = Events()
        let source = LeaseSource(prompt: prompt)
        var c = config(); c.startupTimeout = .seconds(1)
        let monitor = try PresenceMonitor(source: source, configuration: c, clock: time.clock)
        let task = Task { try await monitor.run { await events.record($0) } }
        try await eventually { prompt.count == 1 && time.pendingSleeps == 1 }
        time.advance(by: .seconds(1))
        do { try await task.value; XCTFail("Expected startup timeout") }
        catch PresenceError.startupTimedOut { }
        prompt.answer(true)
        let unwinds = await source.partialUnwinds, stops = await source.stops
        XCTAssertEqual(unwinds, 1); XCTAssertEqual(stops, 0)
        let all = await events.all
        XCTAssertTrue(all.contains(.statusChanged(.failed(.startupTimedOut))))
    }

    func testTimeoutDrainsLosingSuccessfulStartupLease() async throws {
        let prompt = PermissionPrompt(), time = VirtualClock()
        let source = LeaseSource(prompt: prompt, returnLeaseOnCancelledStart: true)
        var c = config(); c.startupTimeout = .seconds(1)
        let monitor = try PresenceMonitor(source: source, configuration: c, clock: time.clock)
        let task = Task { try await monitor.run { _ in } }
        try await eventually { prompt.count == 1 && time.pendingSleeps == 1 }
        time.advance(by: .seconds(1))
        do { try await task.value; XCTFail("Expected timeout") } catch PresenceError.startupTimedOut { }
        let stops = await source.stops; XCTAssertEqual(stops, 1)
        prompt.answer(true)
    }

    func testConcurrentLeaseStopsShareOneCleanup() async throws {
        let source = LeaseSource(delayedCleanup: true)
        let lease = try await source.start()
        let first = Task { await lease.stop() }, second = Task { await lease.stop() }
        try await eventually { await source.cleanupPending }
        let stops = await source.stops; XCTAssertEqual(stops, 1)
        await source.allowCleanup(); await first.value; await second.value
        let replacement = try await source.start()
        await lease.stop() // A stale handle must never stop the replacement.
        let afterStaleStop = await source.stops; XCTAssertEqual(afterStaleStop, 1)
        let cleanup = Task { await replacement.stop() }
        try await eventually { await source.cleanupPending }
        await source.allowCleanup(); await cleanup.value
    }

    func testHeartbeatsDoNotMultiplyMotionConfirmationsOrLightDwell() {
        var c = config(); c.entryConfirmationCount = 2; c.light.enabled = true; c.light.dwell = .seconds(1)
        let origin = ContinuousClock.now
        var r = PresenceReducer(config: c)
        for i in 0...4 {
            let now = origin.advanced(by: .milliseconds(500 * i))
            _ = r.ingest(.init(capturedAt: now, analyzedAt: origin, motionAt: origin,
                light: .init(value: 0), lightMeasuredAt: origin), now: now)
        }
        XCTAssertEqual(r.presence, .unknown)
        XCTAssertEqual(r.lighting, .unknown)
    }

    func testRecognitionFallbackIsTypedAndDeduplicated() {
        let origin = ContinuousClock.now
        var r = PresenceReducer(config: config()), events: [PresenceEvent] = []
        for i in 0..<5 {
            let now = origin.advanced(by: .milliseconds(500 * i))
            events += r.ingest(.init(capturedAt: now, analyzedAt: now,
                recognitionStatus: .failed(.durationBudgetExceeded)), now: now)
        }
        XCTAssertEqual(events.filter { $0 == .statusChanged(.recognition(.failed(.durationBudgetExceeded))) }.count, 1)
    }

    func testVirtualWatchdogStillDetectsActualFrameFailure() async throws {
        let source = LeaseSource(), time = VirtualClock(), events = Events()
        let monitor = try PresenceMonitor(source: source, configuration: config(), clock: time.clock)
        let task = Task { try await monitor.run { await events.record($0) } }
        try await eventually { await events.all.contains(.statusChanged(.running)) && time.pendingSleeps == 1 }
        time.advance(by: .seconds(8))
        do { try await task.value; XCTFail("Expected actual camera stall") }
        catch PresenceError.sensorStalled { }
        let stops = await source.stops; XCTAssertEqual(stops, 1)
    }
    func testAlreadyCancelledPermissionWaitDoesNotRegisterPrompt() async throws {
        let prompt = PermissionPrompt(), gate = Suspension()
        let task = Task {
            await gate.wait()
            return try await CallbackLatch<Bool>.wait { prompt.register($0) }
        }
        try await eventually { await gate.entered }
        task.cancel(); await gate.open()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError { }
        XCTAssertEqual(prompt.count, 0)
    }

    func testSynchronousDuplicateAuthorizationResponseIsSafe() async throws {
        let allowed = try await CallbackLatch<Bool>.wait { reply in reply(true); reply(false) }
        XCTAssertTrue(allowed)
    }

    func testLogicalFailurePrecedesBlockedCallbackDrain() async throws {
        let source = LeaseSource(), events = Events(), gate = Suspension()
        let monitor = try PresenceMonitor(source: source, configuration: config())
        let task = Task {
            try await monitor.run { event in
                await events.record(event)
                if case .presenceChanged(let change) = event, change.current == .present {
                    await gate.wait()
                }
            }
        }
        try await eventually { await events.all.contains(.statusChanged(.running)) }
        await source.send(.init(capturedAt: .now, motion: true))
        try await eventually { await gate.entered }
        await source.fail()
        try await eventually { await monitor.currentState == .unknown }
        let stopsDuringCallback = await source.stops
        XCTAssertEqual(stopsDuringCallback, 0)
        await gate.open(); _ = await task.result
        let states = await events.states
        XCTAssertEqual(states, [.unknown, .present, .unknown])
    }

    func testRecoveryCannotReplayCachedPreGapEvidence() {
        var c = config(); c.entryConfirmationCount = 2
        var r = PresenceReducer(config: c)
        let t = ContinuousClock.now
        _ = r.ingest(.init(capturedAt: t, motion: true), now: t)
        let last = t.advanced(by: .milliseconds(500))
        _ = r.ingest(.init(capturedAt: last, motion: true), now: last)
        XCTAssertEqual(r.presence, .present)
        let stale = t.advanced(by: .seconds(9))
        _ = r.ingest(.init(capturedAt: stale, analyzedAt: last, motionAt: last), now: stale)
        let recovered = t.advanced(by: .seconds(10))
        _ = r.ingest(.init(capturedAt: recovered, analyzedAt: recovered, motionAt: last,
                          semantic: .init(kind: .human, capturedAt: last)), now: recovered)
        XCTAssertEqual(r.presence, .unknown)
        let one = recovered.advanced(by: .milliseconds(500))
        _ = r.ingest(.init(capturedAt: one, motion: true), now: one)
        XCTAssertEqual(r.presence, .unknown)
        let two = one.advanced(by: .milliseconds(500))
        _ = r.ingest(.init(capturedAt: two, motion: true), now: two)
        XCTAssertEqual(r.presence, .present)
    }

}
