import XCTest
@testable import PresenceKit

private actor RecoveringSource: PresenceSource {
    var startupErrors: [PresenceError]
    var starts = 0
    var stops = 0
    var active = false
    var maximumActive = 0
    var pending: AsyncThrowingStream<PresenceSample, Error>.Continuation?
    init(_ startupErrors: [PresenceError] = []) { self.startupErrors = startupErrors }
    func start() async throws -> PresenceSession {
        guard !active else { throw PresenceError.alreadyRunning }
        starts += 1
        if !startupErrors.isEmpty { throw startupErrors.removeFirst() }
        active = true; maximumActive = max(maximumActive, 1)
        let pair = AsyncThrowingStream<PresenceSample, Error>.makeStream()
        pending = pair.continuation
        return PresenceSession(samples: pair.stream) { await self.stop() }
    }
    func stop() { pending?.finish(); pending = nil; active = false; stops += 1 }
    func fail(_ error: PresenceError = .sensorStalled) { pending?.finish(throwing: error) }
    func send(_ sample: PresenceSample) { pending?.yield(sample) }
}
private actor AutomationLog {
    var events: [PresenceAutomationEvent] = []
    func append(_ event: PresenceAutomationEvent) { events.append(event) }
    var retries: [Int] { events.compactMap { if case .recovery(.retryScheduled(let n, _, _)) = $0 { n } else { nil } } }
    var monitoringCount: Int { events.filter { $0 == .recovery(.monitoring) }.count }
    var states: [PresenceState] { events.compactMap { if case .activityChanged(let s) = $0 { s } else { nil } } }
}
@MainActor
final class AutomationTests: XCTestCase {
    private func eventually(_ predicate: @Sendable () async -> Bool) async throws {
        for _ in 0..<400 { if await predicate() { return }; try await Task.sleep(for: .milliseconds(5)) }
        XCTFail("Task synchronization timed out"); throw PresenceError.sensorStalled
    }
    private func config() -> PresenceConfiguration {
        var c = PresenceConfiguration.lowPower
        c.entryConfirmationCount = 1; c.camera.warmup = .zero; c.light.enabled = false
        return c
    }
    private func changed(_ state: PresenceState, at time: ContinuousClock.Instant) -> PresenceEvent {
        .presenceChanged(.init(previous: .unknown, current: state, reason: .inactivity, at: time))
    }

    func testTransientStartupRetriesAndRecovers() async throws {
        let time = VirtualClock(), source = RecoveringSource([.captureFailure(.disconnected)]), log = AutomationLog()
        let automation = try PresenceAutomation(source: source, configuration: config(), clock: time.clock)
        let task = Task { try await automation.run { await log.append($0) } }
        defer { task.cancel() }
        try await eventually { await log.retries == [1] }
        time.advance(by: .seconds(2))
        try await eventually { await log.monitoringCount == 1 }
        await source.send(.init(capturedAt: time.now, motion: true))
        try await eventually { await automation.currentActivity == .present }
        task.cancel(); _ = await task.result
        let states = await log.states, stops = await source.stops
        XCTAssertEqual(states, [.unknown, .present, .unknown]); XCTAssertEqual(stops, 1)
    }
    func testPermissionAndConfigurationFaultsNeverRetry() async throws {
        for expected: PresenceError in [.cameraPermissionDenied, .invalidConfiguration("bad"),
            .cameraConfigurationUnsupported("caps"), .alreadyRunning, .startupTimedOut, .slowConsumer, .cameraUnavailable("unclassified driver error")] {
            let source = RecoveringSource([expected]), log = AutomationLog()
            let automation = try PresenceAutomation(source: source, configuration: config())
            do { try await automation.run { await log.append($0) }; XCTFail("Expected failure") }
            catch { XCTAssertEqual(error as? PresenceError, expected) }
            let retries = await log.retries, starts = await source.starts, stops = await source.stops
            XCTAssertTrue(retries.isEmpty); XCTAssertEqual(starts, 1); XCTAssertEqual(stops, 0)
        }
    }
    func testCancellationDuringBackoffNeverRestarts() async throws {
        let time = VirtualClock(), source = RecoveringSource([.sensorStalled]), log = AutomationLog()
        let a = try PresenceAutomation(source: source, configuration: config(), clock: time.clock)
        let task = Task { try await a.run { await log.append($0) } }
        try await eventually { await log.retries == [1] }
        task.cancel(); _ = await task.result
        time.advance(by: .seconds(1000))
        let starts = await source.starts
        XCTAssertEqual(starts, 1); XCTAssertEqual(time.pendingSleeps, 0)
    }
    func testFailuresRespectMaximumRetries() async throws {
        let time = VirtualClock(), source = RecoveringSource([.sensorStalled, .sensorStalled, .sensorStalled]), log = AutomationLog()
        var retry = PresenceRetryPolicy(); retry.maximumRetries = 1
        let a = try PresenceAutomation(source: source, configuration: config(), retry: retry, clock: time.clock)
        let task = Task { try await a.run { await log.append($0) } }
        try await eventually { await log.retries == [1] }
        time.advance(by: .seconds(2))
        do { try await task.value; XCTFail("Expected exhausted recovery") }
        catch { XCTAssertEqual(error as? PresenceError, .sensorStalled) }
        let starts = await source.starts
        XCTAssertEqual(starts, 2)
    }
    func testStableRunResetsBackoffButStartupDoesNot() async throws {
        let time = VirtualClock(), source = RecoveringSource(), log = AutomationLog()
        var retry = PresenceRetryPolicy(); retry.resetAfter = .seconds(2)
        let a = try PresenceAutomation(source: source, configuration: config(), retry: retry, clock: time.clock)
        let task = Task { try await a.run { await log.append($0) } }
        defer { task.cancel() }
        try await eventually { await log.monitoringCount == 1 }
        await source.fail(); try await eventually { await log.retries == [1] }
        time.advance(by: .seconds(2)); try await eventually { await log.monitoringCount == 2 }
        await source.fail(); try await eventually { await log.retries == [1, 2] }
        time.advance(by: .seconds(4)); try await eventually { await log.monitoringCount == 3 }
        await source.send(.init(capturedAt: time.now, motion: true))
        try await eventually { await log.events.contains(.recovery(.recovered)) }
        time.advance(by: .seconds(3))
        await source.send(.init(capturedAt: time.now, motion: true))
        try await eventually { await a.currentActivity == .present }
        await source.fail(); try await eventually { await log.retries == [1, 2, 1] }
        let stops = await source.stops
        XCTAssertEqual(stops, 3)
        task.cancel(); _ = await task.result
    }
    func testDuplicateAutomationRunDoesNotStopOwner() async throws {
        let source = RecoveringSource(), log = AutomationLog()
        let a = try PresenceAutomation(source: source, configuration: config())
        let task = Task { try await a.run { await log.append($0) } }
        defer { task.cancel() }
        try await eventually { await log.monitoringCount == 1 }
        do { try await a.run { _ in }; XCTFail("Expected duplicate rejection") }
        catch { XCTAssertEqual(error as? PresenceError, .alreadyRunning) }
        let stops = await source.stops; XCTAssertEqual(stops, 0)
        task.cancel(); _ = await task.result
    }
    func testRetryValidationAndSaturatingDelay() async throws {
        var p = PresenceRetryPolicy()
        XCTAssertEqual(p.delay(forRetry: 1), .seconds(2)); XCTAssertEqual(p.delay(forRetry: 2), .seconds(4))
        XCTAssertEqual(p.delay(forRetry: Int.min), .seconds(2))
        XCTAssertEqual(p.delay(forRetry: 100_000), .seconds(60))
        p.initialDelay = .zero; XCTAssertThrowsError(try p.validate())
        p = .init(); p.maximumRetries = -1; XCTAssertThrowsError(try p.validate())
    }
    func testMotionOnlyDoesNotGetRecognitionGrace() async {
        let t = ContinuousClock.now
        var p = ActivityPolicy(recognitionRequested: false, fallback: .motionOnly(additionalAbsenceDelay: .seconds(120)))
        XCTAssertEqual(p.accept(changed(.present, at: t), at: t), .present)
        XCTAssertEqual(p.accept(changed(.absent, at: t), at: t), .absent)
    }
    func testDegradedRecognitionGetsBoundedGraceAndNoDuplicates() async {
        let t = ContinuousClock.now
        var p = ActivityPolicy(recognitionRequested: true, fallback: .motionOnly(additionalAbsenceDelay: .seconds(10)))
        _ = p.accept(changed(.present, at: t), at: t)
        XCTAssertNil(p.accept(changed(.absent, at: t), at: t))
        XCTAssertNil(p.accept(changed(.absent, at: t), at: t.advanced(by: .seconds(9))))
        XCTAssertEqual(p.tick(at: t.advanced(by: .seconds(10))), .absent)
        XCTAssertNil(p.tick(at: t.advanced(by: .seconds(11))))
    }
    func testUnknownNeverWaitsForFallbackGrace() async {
        let t = ContinuousClock.now
        var p = ActivityPolicy(recognitionRequested: true, fallback: .motionOnly(additionalAbsenceDelay: .seconds(10)))
        _ = p.accept(changed(.present, at: t), at: t)
        _ = p.accept(changed(.absent, at: t), at: t)
        XCTAssertEqual(p.accept(changed(.unknown, at: t), at: t), .unknown)
        XCTAssertNil(p.tick(at: t.advanced(by: .seconds(100))))
    }
    func testPresenceCancelsPendingAbsence() async {
        let t = ContinuousClock.now
        var p = ActivityPolicy(recognitionRequested: true, fallback: .motionOnly(additionalAbsenceDelay: .seconds(10)))
        _ = p.accept(changed(.present, at: t), at: t)
        _ = p.accept(changed(.absent, at: t), at: t)
        _ = p.accept(changed(.present, at: t), at: t.advanced(by: .seconds(9)))
        XCTAssertNil(p.tick(at: t.advanced(by: .seconds(11)))); XCTAssertEqual(p.state, .present)
    }
    func testPauseFallbackResumesOnlyWhenRecognitionActive() async {
        let t = ContinuousClock.now
        var p = ActivityPolicy(recognitionRequested: true, fallback: .pauseUntilRecovered)
        XCTAssertNil(p.accept(changed(.present, at: t), at: t))
        XCTAssertEqual(p.accept(.statusChanged(.recognition(.active)), at: t), .present)
        XCTAssertEqual(p.accept(.statusChanged(.recognition(.thermalPressure)), at: t), .unknown)
        XCTAssertEqual(p.accept(.statusChanged(.recognition(.active)), at: t), .present)
    }
    func testHealthyRecognizerDoesNotExtendAbsence() async {
        let t = ContinuousClock.now
        var p = ActivityPolicy(recognitionRequested: true, fallback: .motionOnly(additionalAbsenceDelay: .seconds(10)))
        _ = p.accept(.statusChanged(.recognition(.active)), at: t)
        _ = p.accept(changed(.present, at: t), at: t)
        XCTAssertEqual(p.accept(changed(.absent, at: t), at: t), .absent)
    }
    func testGraceValidationRejectsNegativeAndUnboundedValues() async {
        XCTAssertThrowsError(try PresenceAutomation(source: RecoveringSource(), fallback: .motionOnly(additionalAbsenceDelay: .seconds(-1))))
        XCTAssertThrowsError(try PresenceAutomation(source: RecoveringSource(), fallback: .motionOnly(additionalAbsenceDelay: .seconds(3601))))
    }
    func testJitterCannotRemoveMinimumDelayOrExceedCeiling() async throws {
        var p = PresenceRetryPolicy()
        p.jitter = { _, _ in .seconds(-100) }
        XCTAssertEqual(p.delay(forRetry: 9), .milliseconds(100))
        p.jitter = { _, _ in .seconds(10_000) }
        XCTAssertEqual(p.delay(forRetry: 1), .seconds(60))
        p.jitter = { delay, _ in delay / 2 }
        XCTAssertEqual(p.delay(forRetry: 2), .seconds(2))
    }
    func testAllTypedCaptureReasonsRetryButUnknownMessagesDoNot() async {
        for reason: CaptureFailureReason in [.interrupted, .disconnected, .deviceInUse, .mediaServicesReset] {
            XCTAssertTrue(PresenceError.captureFailure(reason).isRetryable)
        }
        XCTAssertFalse(PresenceError.cameraUnavailable("disconnected").isRetryable)
        XCTAssertFalse(PresenceError.cameraUnavailable("permission denied").isRetryable)
    }
    func testStartupTimeDoesNotResetBackoff() async throws {
        let time = VirtualClock(), source = RecoveringSource([.sensorStalled]), log = AutomationLog()
        var retry = PresenceRetryPolicy(); retry.resetAfter = .seconds(2)
        let a = try PresenceAutomation(source: source, configuration: config(), retry: retry, clock: time.clock)
        let task = Task { try await a.run { await log.append($0) } }; defer { task.cancel() }
        try await eventually { await log.retries == [1] }
        time.advance(by: .seconds(2)); try await eventually { await log.monitoringCount == 1 }
        time.advance(by: .seconds(3))
        await source.send(.init(capturedAt: time.now, motion: true))
        try await eventually { await a.currentActivity == .present }
        await source.fail(); try await eventually { await log.retries == [1, 2] }
        task.cancel(); _ = await task.result
    }
    func testSilenceAndSlowTeardownCannotEarnHealthyReset() async throws {
        let time = VirtualClock(), source = RecoveringSource([.sensorStalled]), log = AutomationLog()
        var retry = PresenceRetryPolicy(); retry.resetAfter = .seconds(120)
        let a = try PresenceAutomation(source: source, configuration: config(), retry: retry, clock: time.clock)
        let task = Task { try await a.run { await log.append($0) } }; defer { task.cancel() }
        try await eventually { await log.retries == [1] }
        time.advance(by: .seconds(2)); try await eventually { await log.monitoringCount == 1 }
        await source.send(.init(capturedAt: time.now, motion: true))
        try await eventually { await a.currentActivity == .present }
        time.advance(by: .seconds(200))
        try await eventually { await log.retries == [1, 2] }
        task.cancel(); _ = await task.result
    }
    func testRecoveredRequiresAnalysisNotSuccessfulStartup() async throws {
        let time = VirtualClock(), source = RecoveringSource([.captureFailure(.deviceInUse)]), log = AutomationLog()
        let a = try PresenceAutomation(source: source, configuration: config(), clock: time.clock)
        let task = Task { try await a.run { await log.append($0) } }; defer { task.cancel() }
        try await eventually { await log.retries == [1] }
        time.advance(by: .seconds(2)); try await eventually { await log.monitoringCount == 1 }
        let initial = await log.events; XCTAssertFalse(initial.contains(.recovery(.recovered)))
        await source.send(.init(capturedAt: time.now, analyzedAt: nil, analysisStatus: .warmingUp))
        try await eventually { await log.events.contains(.sensing(.statusChanged(.analysis(.warmingUp)))) }
        let warming = await log.events; XCTAssertFalse(warming.contains(.recovery(.recovered)))
        time.advance(by: .milliseconds(500)); await source.send(.init(capturedAt: time.now, motion: true))
        try await eventually { await log.events.contains(.recovery(.recovered)) }
        task.cancel(); _ = await task.result
        let events = await log.events
        XCTAssertEqual(events.filter { $0 == .recovery(.recovered) }.count, 1)
    }
    func testStrictFallbackWarmupAndEachDegradationRecoverExplicitly() async throws {
        let time = VirtualClock(), source = RecoveringSource(), log = AutomationLog()
        var c = config(); c.vision.mode = .humanRectangles; c.absenceDelay = .seconds(240)
        let a = try PresenceAutomation(source: source, configuration: c, fallback: .pauseUntilRecovered, clock: time.clock)
        let task = Task { try await a.run { await log.append($0) } }; defer { task.cancel() }
        try await eventually { await log.monitoringCount == 1 }
        await source.send(.init(capturedAt: time.now, analyzedAt: time.now, motionAt: time.now,
            recognitionStatus: .warmingUp, recognitionDeadline: time.now.advanced(by: .seconds(5))))
        try await eventually { await log.events.contains(.modeChanged(.unavailable(.warmingUp))) }
        XCTAssertEqual(a.latestActivity, .unknown); XCTAssertFalse(a.sensingAvailable)
        for degraded: RecognitionStatus in [.thermalPressure, .cadenceExceeded, .failed(.durationBudgetExceeded),
                                            .failed(.inferenceFailed("test")), .failed(.frameCopyFailed)] {
            time.advance(by: .milliseconds(100))
            await source.send(.init(capturedAt: time.now, analyzedAt: time.now, recognitionStatus: .active))
            try await eventually { a.latestActivity == .present && a.sensingAvailable }
            time.advance(by: .milliseconds(100))
            await source.send(.init(capturedAt: time.now, analyzedAt: time.now, recognitionStatus: degraded))
            try await eventually { await log.events.contains(.modeChanged(.unavailable(degraded))) }
            XCTAssertEqual(a.latestActivity, .unknown); XCTAssertFalse(a.sensingAvailable)
        }
        task.cancel(); _ = await task.result
        let raw = await log.events.filter { if case .sensing(.presenceChanged(let change)) = $0 { change.current == .present } else { false } }
        XCTAssertEqual(raw.count, 1, "Presentation degradation must not rewrite raw sensed occupancy")
    }
    func testStrictFallbackWithoutRecognitionIsRejected() async {
        XCTAssertThrowsError(try PresenceAutomation(source: RecoveringSource(), fallback: .pauseUntilRecovered))
    }
    func testRecognitionDegradationBreaksHealthyResetPeriod() async throws {
        let time = VirtualClock(), source = RecoveringSource([.sensorStalled]), log = AutomationLog()
        var c = config(); c.vision.mode = .humanRectangles; c.absenceDelay = .seconds(240)
        var retry = PresenceRetryPolicy(); retry.resetAfter = .seconds(2)
        let a = try PresenceAutomation(source: source, configuration: c, retry: retry, clock: time.clock)
        let task = Task { try await a.run { await log.append($0) } }; defer { task.cancel() }
        try await eventually { await log.retries == [1] }
        time.advance(by: .seconds(2)); try await eventually { await log.monitoringCount == 1 }
        await source.send(.init(capturedAt: time.now, analyzedAt: time.now, motionAt: time.now, recognitionStatus: .active))
        try await eventually { await log.events.contains(.recovery(.recovered)) }
        time.advance(by: .seconds(1))
        await source.send(.init(capturedAt: time.now, analyzedAt: time.now, recognitionStatus: .thermalPressure))
        try await eventually { await log.events.contains(.modeChanged(.motionFallback(.thermalPressure))) }
        time.advance(by: .seconds(3))
        await source.send(.init(capturedAt: time.now, analyzedAt: time.now, recognitionStatus: .active))
        try await eventually { await a.operatingMode == .semantic }
        await source.fail(); try await eventually { await log.retries == [1, 2] }
        task.cancel(); _ = await task.result
    }
    func testManualRetryAfterTerminalFailureReusesExclusiveOwner() async throws {
        let source = RecoveringSource([.cameraPermissionDenied]), log = AutomationLog()
        let a = try PresenceAutomation(source: source, configuration: config())
        do { try await a.run { await log.append($0) }; XCTFail("Expected terminal failure") }
        catch { XCTAssertEqual(error as? PresenceError, .cameraPermissionDenied) }
        let before = await source.starts; XCTAssertEqual(before, 1)
        let task = Task { try await a.run { await log.append($0) } }
        try await eventually { await log.monitoringCount == 1 }
        task.cancel(); _ = await task.result
        let starts = await source.starts, stops = await source.stops, maximum = await source.maximumActive
        XCTAssertEqual(starts, 2); XCTAssertEqual(stops, 1); XCTAssertEqual(maximum, 1)
    }
    func testDiagnosticsSeparateActiveAndBackoffTime() async throws {
        let time = VirtualClock(), source = RecoveringSource([.sensorStalled]), log = AutomationLog()
        let a = try PresenceAutomation(source: source, configuration: config(), clock: time.clock)
        let task = Task { try await a.run { await log.append($0) } }; defer { task.cancel() }
        try await eventually { await log.retries == [1] }
        time.advance(by: .seconds(2)); try await eventually { await log.monitoringCount == 1 }
        time.advance(by: .seconds(3)); await source.fail()
        try await eventually { await log.retries == [1, 2] }
        let stats = await a.statistics()
        XCTAssertEqual(stats.attempts, 2); XCTAssertEqual(stats.retries, 2)
        XCTAssertEqual(stats.inactiveTime, .seconds(2)); XCTAssertEqual(stats.activeTime, .seconds(3))
        task.cancel(); _ = await task.result
    }

}
