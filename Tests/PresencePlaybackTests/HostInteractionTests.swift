import XCTest
@testable import PresenceKit
@testable import PresencePlayback

private actor HostSource: PresenceSource {
    let time: VirtualClock
    var starts = 0, stops = 0, active = 0, maximumActive = 0
    var continuation: AsyncThrowingStream<PresenceSample, Error>.Continuation?
    var slowCleanup = false
    var cleanup: CheckedContinuation<Void, Never>?
    init(_ time: VirtualClock) { self.time = time }
    func start() throws -> PresenceSession {
        guard active == 0 else { throw PresenceError.alreadyRunning }
        starts += 1; active += 1; maximumActive = max(maximumActive, active)
        let pair = AsyncThrowingStream<PresenceSample, Error>.makeStream()
        continuation = pair.continuation
        return PresenceSession(samples: pair.stream) { await self.close() }
    }
    func send(motion: Bool) { continuation?.yield(.init(capturedAt: time.now, motion: motion)) }
    func fail(_ error: PresenceError = .captureFailure(.disconnected)) { continuation?.finish(throwing: error) }
    func delayCleanup() { slowCleanup = true }
    func finishCleanup() { cleanup?.resume(); cleanup = nil; slowCleanup = false }
    func close() async {
        stops += 1; continuation?.finish(); continuation = nil
        if slowCleanup { await withCheckedContinuation { cleanup = $0 } }
        active -= 1
    }
}

@MainActor
private final class HostOutput: PresencePlaybackOutput {
    let time: VirtualClock
    var lastInput: ContinuousClock.Instant
    var grace: Duration = .seconds(5)
    var playing = false, displayHeld = false, systemHeld = false
    var sleepChecks = 0, sleeps = 0, wakes = 0, ends = 0
    var trace: [String] = []
    var delaySleep = false, delaySuppression = false
    var sleepGate: CheckedContinuation<Void, Never>?
    var suppressionGate: CheckedContinuation<Void, Never>?
    init(_ time: VirtualClock) { self.time = time; lastInput = time.now }
    func begin(reportFailure: @escaping @MainActor (PresencePlaybackError) -> Void) { trace.append("begin") }
    func suppressMotion() async {
        trace.append("suppress")
        if delaySuppression { await withCheckedContinuation { suppressionGate = $0 } }
    }
    func setMonitoring(_ active: Bool, permit: @escaping @Sendable () -> Bool) {
        systemHeld = active && permit(); trace.append(systemHeld ? "hold-system" : "release-system")
    }
    func wake(permit: @escaping @Sendable () -> Bool) throws {
        try Task.checkCancellation(); guard permit() else { return }
        displayHeld = true; wakes += 1; trace.append("wake")
    }
    func setPlaying(_ value: Bool) { playing = value; trace.append(value ? "play" : "pause") }
    func sleep(permit: @escaping @Sendable () -> Bool) async throws -> PresenceDisplaySleepResult {
        sleepChecks += 1
        if delaySleep { await withCheckedContinuation { sleepGate = $0 } }
        try Task.checkCancellation()
        guard permit() else { return .finished }
        let idle = lastInput.duration(to: time.now)
        if idle < grace { return .deferred(grace - idle) }
        sleeps += 1; trace.append("sleep"); return .finished
    }
    func releaseDisplay() { displayHeld = false; trace.append("release-display") }
    func end() { ends += 1; playing = false; displayHeld = false; systemHeld = false; trace.append("end") }
    func releaseSleep() { delaySleep = false; sleepGate?.resume(); sleepGate = nil }
    func releaseSuppression() { delaySuppression = false; suppressionGate?.resume(); suppressionGate = nil }
}

@MainActor
final class HostInteractionTests: XCTestCase {
    private func eventually(_ predicate: @MainActor () async -> Bool) async throws {
        for _ in 0..<400 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Synchronization timeout"); throw PresenceError.sensorStalled
    }
    private func automation(_ source: HostSource, _ time: VirtualClock) throws -> PresenceAutomation {
        var c = PresenceConfiguration.lowPower
        c.entryConfirmationCount = 1; c.camera.warmup = .zero; c.absenceDelay = .seconds(1)
        c.watchdogInterval = .milliseconds(100); c.light.enabled = false
        return try PresenceAutomation(source: source, configuration: c, clock: time.clock)
    }
    private func arrive(_ source: HostSource, _ output: HostOutput, _ time: VirtualClock) async throws {
        try await eventually { await source.active == 1 }
        time.advance(by: .milliseconds(10)); await source.send(motion: true)
        try await eventually { output.playing && output.systemHeld }
    }
    private func depart(_ source: HostSource, _ output: HostOutput, _ time: VirtualClock) async throws {
        time.advance(by: .seconds(1)); await source.send(motion: false)
        try await eventually { output.sleepChecks == 1 }
        XCTAssertFalse(output.playing); XCTAssertFalse(output.displayHeld)
    }
    func testDeferredSleepRechecksWithoutAnotherAbsenceEvent() async throws {
        let time = VirtualClock(), source = HostSource(time), output = HostOutput(time)
        let a = try automation(source, time), c = PresencePlaybackController(output: output, clock: time.clock)
        let task = Task { try await c.run(automation: a) }; defer { task.cancel() }
        try await arrive(source, output, time); try await depart(source, output, time)
        XCTAssertEqual(output.sleeps, 0)
        time.advance(by: .seconds(4))
        try await eventually { output.sleeps == 1 }
        XCTAssertEqual(output.sleepChecks, 2)
        task.cancel(); _ = await task.result
        XCTAssertFalse(output.displayHeld); XCTAssertFalse(output.systemHeld); XCTAssertEqual(time.pendingSleeps, 0)
    }
    func testLocalInputExtendsOneOwnedRecheck() async throws {
        let time = VirtualClock(), source = HostSource(time), output = HostOutput(time)
        let c = PresencePlaybackController(output: output, clock: time.clock), a = try automation(source, time)
        let task = Task { try await c.run(automation: a) }; defer { task.cancel() }
        try await arrive(source, output, time); try await depart(source, output, time)
        time.advance(by: .seconds(2)); output.lastInput = time.now
        time.advance(by: .seconds(2)); await source.send(motion: false)
        try await eventually { output.sleepChecks == 2 }
        XCTAssertEqual(output.sleeps, 0)
        time.advance(by: .seconds(3))
        try await eventually { output.sleeps == 1 }
        XCTAssertEqual(output.sleepChecks, 3)
        task.cancel(); _ = await task.result
    }
    func testArrivalCancelsDeferredSleepAndDuplicatePresenceIsIdempotent() async throws {
        let time = VirtualClock(), source = HostSource(time), output = HostOutput(time)
        let c = PresencePlaybackController(output: output, clock: time.clock), a = try automation(source, time)
        let task = Task { try await c.run(automation: a) }; defer { task.cancel() }
        try await arrive(source, output, time); try await depart(source, output, time)
        time.advance(by: .milliseconds(100)); await source.send(motion: true)
        try await eventually { output.playing && output.wakes == 2 }
        for _ in 0..<5 {
            time.advance(by: .milliseconds(100)); await source.send(motion: true)
        }
        XCTAssertEqual(output.wakes, 2)
        task.cancel(); _ = await task.result; time.advance(by: .seconds(100))
        XCTAssertEqual(output.sleeps, 0); XCTAssertEqual(time.pendingSleeps, 0)
    }
    func testQueuedSleepDrainsBeforeArrivalWake() async throws {
        let time = VirtualClock(), source = HostSource(time), output = HostOutput(time)
        output.delaySleep = true; output.grace = .zero
        let c = PresencePlaybackController(output: output, clock: time.clock), a = try automation(source, time)
        let task = Task { try await c.run(automation: a) }; defer { task.cancel() }
        try await arrive(source, output, time); try await depart(source, output, time)
        try await eventually { output.sleepGate != nil }
        time.advance(by: .milliseconds(100)); await source.send(motion: true)
        try await eventually { a.latestActivity == .present }
        XCTAssertEqual(output.wakes, 1)
        output.releaseSleep()
        try await eventually { output.wakes == 2 && output.playing }
        XCTAssertEqual(output.sleeps, 0)
        task.cancel(); _ = await task.result
    }
    func testBufferedArrivalInvalidatesSleepPermitBeforeCallbackDelivery() async throws {
        let time = VirtualClock(), source = HostSource(time), output = HostOutput(time)
        output.delaySleep = true; output.grace = .zero
        let c = PresencePlaybackController(output: output, clock: time.clock), a = try automation(source, time)
        var callbackGate: CheckedContinuation<Void, Never>?
        let task = Task {
            try await c.run(automation: a) { event in
                if event == .activityChanged(.absent) { await withCheckedContinuation { callbackGate = $0 } }
            }
        }
        defer { task.cancel() }
        try await arrive(source, output, time); try await depart(source, output, time)
        try await eventually { callbackGate != nil && output.sleepGate != nil }
        time.advance(by: .milliseconds(100)); await source.send(motion: true)
        try await eventually { a.latestActivity == .present }
        output.releaseSleep()
        // Await the worker's completion while the arrival callback remains blocked.
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(output.sleeps, 0)
        callbackGate?.resume(); callbackGate = nil
        try await eventually { output.playing }
        task.cancel(); _ = await task.result
    }
    func testUnknownDuringSlowFailureCleanupCannotWakeAfterSuppression() async throws {
        let time = VirtualClock(), source = HostSource(time), output = HostOutput(time)
        let c = PresencePlaybackController(output: output, clock: time.clock), a = try automation(source, time)
        let task = Task { try await c.run(automation: a) }; defer { task.cancel() }
        try await eventually { await source.active == 1 }
        output.delaySuppression = true
        time.advance(by: .milliseconds(10)); await source.send(motion: true)
        try await eventually { output.suppressionGate != nil }
        await source.delayCleanup(); await source.fail()
        try await eventually { await source.cleanup != nil }
        XCTAssertEqual(a.latestActivity, .unknown)
        output.releaseSuppression()
        try await eventually { !output.playing && !output.displayHeld }
        XCTAssertEqual(output.wakes, 0)
        task.cancel(); await source.finishCleanup(); _ = await task.result
        XCTAssertEqual(time.pendingSleeps, 0)
    }
    func testRetryBackoffReleasesAllHoldsBeforeAnotherAttempt() async throws {
        let time = VirtualClock(), source = HostSource(time), output = HostOutput(time)
        let c = PresencePlaybackController(output: output, clock: time.clock), a = try automation(source, time)
        var retrySeen = false
        let task = Task { try await c.run(automation: a) { event in
            if case .recovery(.retryScheduled) = event { retrySeen = true }
        } }
        defer { task.cancel() }
        try await arrive(source, output, time); await source.fail()
        try await eventually { retrySeen && !output.systemHeld && !output.displayHeld && !output.playing }
        let starts = await source.starts; XCTAssertEqual(starts, 1)
        time.advance(by: .seconds(2))
        try await eventually { await source.starts == 2 }
        XCTAssertFalse(output.systemHeld, "Startup alone must not acquire a system hold")
        task.cancel(); _ = await task.result
    }
    func testSleepAndSessionSuspensionsDrainBeforeSingleReplacement() async throws {
        let time = VirtualClock(), source = HostSource(time), output = HostOutput(time), lifecycle = PresenceLifecycle()
        let c = PresencePlaybackController(output: output, clock: time.clock), a = try automation(source, time)
        let task = Task { try await lifecycle.run { try await c.run(automation: a) } }; defer { task.cancel() }
        try await arrive(source, output, time)
        await source.delayCleanup()
        lifecycle.setSuspended(true, for: .systemSleep)
        lifecycle.setSuspended(true, for: .inactiveSession)
        lifecycle.setSuspended(false, for: .systemSleep)
        try await eventually { await source.cleanup != nil }
        try await eventually { !output.playing && !output.displayHeld && !output.systemHeld }
        await source.finishCleanup()
        try await eventually { await source.active == 0 }
        let starts = await source.starts; XCTAssertEqual(starts, 1)
        lifecycle.setSuspended(false, for: .inactiveSession)
        try await eventually { await source.starts == 2 }
        task.cancel(); _ = await task.result
        let maximum = await source.maximumActive, active = await source.active
        XCTAssertEqual(maximum, 1); XCTAssertEqual(active, 0); XCTAssertEqual(output.ends, 2)
        XCTAssertEqual(time.pendingSleeps, 0)
    }
    func testCancellationWhileSuspendedNeverStartsOperation() async throws {
        let lifecycle = PresenceLifecycle()
        lifecycle.setSuspended(true, for: .host)
        var starts = 0, suspended = false
        let task = Task { try await lifecycle.run(operation: { starts += 1 }, onSuspension: { suspended = true }) }
        try await eventually { suspended }
        task.cancel(); _ = await task.result
        lifecycle.setSuspended(false, for: .host)
        XCTAssertEqual(starts, 0)
    }
    func testLifecycleDuplicateRunAndTerminalErrorNeedExplicitRetry() async throws {
        let lifecycle = PresenceLifecycle()
        var starts = 0
        do { try await lifecycle.run { starts += 1; throw PresenceError.cameraPermissionDenied }; XCTFail("Expected terminal error") }
        catch { XCTAssertEqual(error as? PresenceError, .cameraPermissionDenied) }
        XCTAssertEqual(starts, 1)
        lifecycle.setSuspended(true, for: .host)
        var waiting = false
        let task = Task { try await lifecycle.run(operation: { starts += 1 }, onSuspension: { waiting = true }) }
        try await eventually { waiting }
        do { try await lifecycle.run { starts += 1 }; XCTFail("Expected ownership rejection") }
        catch { XCTAssertEqual(error as? PresenceError, .alreadyRunning) }
        lifecycle.setSuspended(false, for: .host)
        try await task.value
        XCTAssertEqual(starts, 2)
    }
}
