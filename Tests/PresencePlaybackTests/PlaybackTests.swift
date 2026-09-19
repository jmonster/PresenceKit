import XCTest
import PresenceKit
@testable import PresencePlayback
#if os(macOS)
import AVFoundation
#endif

private actor OutputSource: PresenceSource {
    var continuation: AsyncThrowingStream<PresenceSample, Error>.Continuation?
    var stops = 0
    var cleanupPending = false
    var cleanupGate: CheckedContinuation<Void, Never>?
    let delayStop: Bool
    init(delayStop: Bool = false) { self.delayStop = delayStop }
    func start() -> PresenceSession {
        let pair = AsyncThrowingStream<PresenceSample, Error>.makeStream()
        continuation = pair.continuation
        return PresenceSession(samples: pair.stream) { await self.close() }
    }
    func send() { continuation?.yield(.init(capturedAt: .now, motion: true)) }
    func fail() { continuation?.finish(throwing: PresenceError.cameraPermissionDenied) }
    func close() async {
        stops += 1; continuation?.finish(); continuation = nil
        if delayStop { await withCheckedContinuation { cleanupGate = $0; cleanupPending = true } }
    }
    func resumeCleanup() { cleanupGate?.resume(); cleanupGate = nil; cleanupPending = false }
}

@MainActor
private final class OutputSpy: PlaybackOutput {
    var trace: [String] = []
    var beginError = false
    var wakeError = false
    var cancelOnWake = false
    var delaySuppression = false
    var suppression: CheckedContinuation<Void, Never>?
    var report: (@MainActor (PresencePlaybackError) -> Void)?
    func begin(reportFailure: @escaping @MainActor (PresencePlaybackError) -> Void) throws {
        trace.append("begin"); report = reportFailure
        if beginError { throw PresencePlaybackError.power("begin failed") }
    }
    func suppressMotion() async {
        trace.append("suppress")
        if delaySuppression { await withCheckedContinuation { suppression = $0 } }
    }
    func wake(permit: @escaping @Sendable () -> Bool) throws {
        guard permit() else { return }; trace.append("wake")
        if cancelOnWake { withUnsafeCurrentTask { $0?.cancel() } }
        if wakeError { throw PresencePlaybackError.power("wake failed") }
    }
    func setPlaying(_ playing: Bool) { trace.append(playing ? "play" : "pause") }
    func setMonitoring(_ active: Bool, permit: @escaping @Sendable () -> Bool) { trace.append(active ? "hold-system" : "release-system") }
    func sleep(permit: @escaping @Sendable () -> Bool) async throws -> PresenceDisplaySleepResult {
        if permit() { trace.append("sleep") }
        return .finished
    }
    func releaseDisplay() { trace.append("release") }
    func end() { trace.append("end") }
}

@MainActor
final class PlaybackTests: XCTestCase {
    private func eventually(_ predicate: @MainActor () async -> Bool) async throws {
        for _ in 0..<400 { if await predicate() { return }; try await Task.sleep(for: .milliseconds(5)) }
        XCTFail("Synchronization timeout"); throw PresenceError.sensorStalled
    }
    private func automation(_ source: OutputSource, absence: Duration = .seconds(120)) throws -> PresenceAutomation {
        var c = PresenceConfiguration.lowPower; c.entryConfirmationCount = 1; c.camera.warmup = .zero
        c.absenceDelay = absence; c.watchdogInterval = .milliseconds(100)
        var retry = PresenceRetryPolicy(); retry.maximumRetries = 0
        return try PresenceAutomation(source: source, configuration: c, retry: retry)
    }
    func testWakePrecedesPlayAndFailureNeverForcesSleep() async throws {
        let source = OutputSource(), spy = OutputSpy(), coordinator = PlaybackCoordinator(output: spy)
        let a = try automation(source)
        do {
            try await coordinator.run(automation: a) { event in
                if case .recovery(.monitoring) = event { await source.send() }
                if case .activityChanged(.present) = event { await source.fail() }
            }
            XCTFail("Expected failure")
        } catch { XCTAssertEqual(error as? PresenceError, .cameraPermissionDenied) }
        let wake = try XCTUnwrap(spy.trace.firstIndex(of: "wake")), play = try XCTUnwrap(spy.trace.firstIndex(of: "play"))
        XCTAssertLessThan(wake, play); XCTAssertFalse(spy.trace.contains("sleep"))
        XCTAssertEqual(spy.trace.last, "end")
    }
    func testAbsencePausesBeforeDisplaySleep() async throws {
        let source = OutputSource(), spy = OutputSpy(), coordinator = PlaybackCoordinator(output: spy)
        let a = try automation(source, absence: .seconds(1))
        let task = Task {
            try await coordinator.run(automation: a) { event in
                if case .recovery(.monitoring) = event { await source.send() }
            }
        }
        try await eventually { spy.trace.contains("sleep") }
        await source.fail()
        do { try await task.value; XCTFail("Expected failure") }
        catch { XCTAssertEqual(error as? PresenceError, .cameraPermissionDenied) }
        let sleep = try XCTUnwrap(spy.trace.firstIndex(of: "sleep"))
        let pause = try XCTUnwrap(spy.trace[..<sleep].lastIndex(of: "pause"))
        XCTAssertEqual(spy.trace[pause - 1], "suppress")
        XCTAssertLessThan(pause, sleep)
    }

    func testWakeFailureNeverStartsMediaAndCleansUp() async throws {
        let source = OutputSource(), spy = OutputSpy(), coordinator = PlaybackCoordinator(output: spy)
        spy.wakeError = true
        do {
            try await coordinator.run(automation: automation(source)) { event in
                if case .recovery(.monitoring) = event { await source.send() }
            }
            XCTFail("Expected output failure")
        } catch { XCTAssertEqual(error as? PresencePlaybackError, .power("wake failed")) }
        XCTAssertFalse(spy.trace.contains("play")); XCTAssertEqual(spy.trace.last, "end")
        let stops = await source.stops; XCTAssertEqual(stops, 1)
    }
    func testBeginFailureReleasesPartialResourcesWithoutOpeningSource() async throws {
        let source = OutputSource(), spy = OutputSpy(), coordinator = PlaybackCoordinator(output: spy)
        spy.beginError = true
        do { try await coordinator.run(automation: automation(source)) { _ in }; XCTFail("Expected error") }
        catch { XCTAssertEqual(error as? PresencePlaybackError, .power("begin failed")) }
        XCTAssertEqual(spy.trace, ["begin", "pause", "release", "release-system", "end"])
        let stops = await source.stops; XCTAssertEqual(stops, 0)
    }
    func testCancellationPausesBeforeDelayedCameraCleanup() async throws {
        let source = OutputSource(delayStop: true), spy = OutputSpy(), coordinator = PlaybackCoordinator(output: spy)
        let a = try automation(source)
        let task = Task {
            try await coordinator.run(automation: a) { event in
                if case .recovery(.monitoring) = event { await source.send() }
            }
        }
        try await eventually { spy.trace.contains("play") }
        spy.trace.removeAll(); task.cancel()
        try await eventually { await source.cleanupPending }
        try await eventually { spy.trace.contains("pause") && spy.trace.contains("release") }
        XCTAssertFalse(spy.trace.contains("end"))
        await source.resumeCleanup(); _ = await task.result
        XCTAssertEqual(spy.trace.last, "end")
    }
    func testCancellationDuringWakeCannotStartPlayback() async throws {
        let source = OutputSource(), spy = OutputSpy(), coordinator = PlaybackCoordinator(output: spy)
        spy.cancelOnWake = true
        let a = try automation(source)
        let task = Task {
            try await coordinator.run(automation: a) { event in
                if case .recovery(.monitoring) = event { await source.send() }
            }
        }
        try await eventually { spy.trace.contains("wake") }
        // The spy cancels the callback task during wake; terminate the owner too.
        task.cancel(); _ = await task.result
        XCTAssertFalse(spy.trace.contains("play")); XCTAssertEqual(spy.trace.last, "end")
    }
    func testCancelDuringSuppressionCannotWakeOrPlayLater() async throws {
        let source = OutputSource(), spy = OutputSpy(), coordinator = PlaybackCoordinator(output: spy)
        spy.delaySuppression = true
        let a = try automation(source)
        let task = Task {
            try await coordinator.run(automation: a) { event in
                if case .recovery(.monitoring) = event { await source.send() }
            }
        }
        try await eventually { spy.suppression != nil }
        task.cancel(); spy.suppression?.resume(); spy.suppression = nil
        _ = await task.result
        XCTAssertFalse(spy.trace.contains("wake")); XCTAssertFalse(spy.trace.contains("play"))
        XCTAssertEqual(spy.trace.last, "end")
    }
    func testAsynchronousPlayerFailureIsTerminalAndDoesNotLeakCapture() async throws {
        let source = OutputSource(), spy = OutputSpy(), coordinator = PlaybackCoordinator(output: spy)
        let a = try automation(source)
        let task = Task {
            try await coordinator.run(automation: a) { event in
                if case .recovery(.monitoring) = event { await source.send() }
            }
        }
        try await eventually { spy.trace.contains("play") }
        spy.report?(.media("decoder failed"))
        do { try await task.value; XCTFail("Expected media failure") }
        catch { XCTAssertEqual(error as? PresencePlaybackError, .media("decoder failed")) }
        let stops = await source.stops; XCTAssertEqual(stops, 1); XCTAssertEqual(spy.trace.last, "end")
    }
    func testDuplicateControllerRunDoesNotAffectExistingOutput() async throws {
        let source = OutputSource(), spy = OutputSpy(), coordinator = PlaybackCoordinator(output: spy)
        let a = try automation(source)
        let task = Task { try await coordinator.run(automation: a) { _ in } }
        try await eventually { spy.trace.contains("begin") }
        let before = spy.trace
        do { try await coordinator.run(automation: a) { _ in }; XCTFail("Expected alreadyRunning") }
        catch { XCTAssertEqual(error as? PresenceError, .alreadyRunning) }
        XCTAssertEqual(spy.trace, before)
        task.cancel(); _ = await task.result
    }
    func testLateFailureFromOldRunCannotStopReplacement() async throws {
        let source = OutputSource(), spy = OutputSpy(), coordinator = PlaybackCoordinator(output: spy)
        let a = try automation(source)
        let first = Task { try await coordinator.run(automation: a) { _ in } }
        try await eventually { spy.report != nil }
        let stale = spy.report
        first.cancel(); _ = await first.result
        spy.trace.removeAll()
        let second = Task { try await coordinator.run(automation: a) { _ in } }
        try await eventually { spy.trace.contains("begin") }
        let before = spy.trace
        stale?(.media("late error"))
        XCTAssertEqual(before, spy.trace)
        second.cancel(); _ = await second.result
    }
    #if os(macOS)
    func testNativeControllerPublicInjectionAndAVPlayerLinkage() async throws {
        let source = OutputSource(), a = try automation(source), player = AVPlayer()
        var visible: [Bool] = []
        let controller = try PresencePlayerController(player: player, automation: a, visibility: { visible.append($0) })
        do {
            try await controller.run { event in
                if case .recovery(.monitoring) = event { await source.send() }
                if case .activityChanged(.present) = event { await source.fail() }
            }
        } catch { XCTAssertEqual(error as? PresenceError, .cameraPermissionDenied) }
        XCTAssertTrue(visible.contains(true)); XCTAssertEqual(visible.last, false)
        XCTAssertEqual(player.rate, 0)
    }
    func testAnyInputEventSentinelWithoutDisplaySideEffects() throws {
        XCTAssertNoThrow(try SystemDisplayPower.anyInputEvent())
    }
    func testInvalidPowerGraceRejectedBeforeCameraUse() async throws {
        XCTAssertThrowsError(try PresencePlayerController(player: AVPlayer(), userInputGraceSeconds: .nan))
    }
    #endif
}
