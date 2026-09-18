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
        let time = VirtualClock(), source = RecoveringSource([.cameraUnavailable("disconnected")]), log = AutomationLog()
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
            .cameraConfigurationUnsupported("caps"), .alreadyRunning, .startupTimedOut, .slowConsumer] {
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
}
