import XCTest
@testable import PresenceKit

private actor FakeSource: PresenceSource {
    var starts = 0
    var stops = 0
    var failStart = false
    private var output: AsyncThrowingStream<PresenceSample, Error>.Continuation?
    func start() async throws -> AsyncThrowingStream<PresenceSample, Error> {
        starts += 1
        if failStart { throw PresenceError.cameraUnavailable("test startup failure") }
        let pair = AsyncThrowingStream<PresenceSample, Error>.makeStream()
        output = pair.continuation; return pair.stream
    }
    func stop() async { stops += 1; output?.finish(); output = nil }
    func send(_ sample: PresenceSample) { output?.yield(sample) }
    func end() { output?.finish() }
    func setStartupFailure() { failStart = true }
}

private actor Recorder {
    var events: [PresenceEvent] = []
    func append(_ event: PresenceEvent) { events.append(event) }
    var states: [PresenceState] {
        events.compactMap { if case .presenceChanged(let c) = $0 { return c.current }; return nil }
    }
}

@MainActor
final class MonitorTests: XCTestCase {
    private func waitFor(_ predicate: @Sendable () async -> Bool) async throws {
        for _ in 0..<200 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("condition did not become true")
        throw PresenceError.sensorStalled
    }
    private func configuration() -> PresenceConfiguration {
        var c = PresenceConfiguration.lowPower
        c.entryConfirmationCount = 1; c.camera.warmup = .zero
        c.light.dwell = .zero
        return c
    }
    func testCancellationStopsSourceAndInvalidatesDeliveredPresence() async throws {
        let source = FakeSource(), recorder = Recorder()
        let monitor = try PresenceMonitor(source: source, configuration: configuration())
        let task = Task { try await monitor.run { await recorder.append($0) } }
        try await waitFor { await source.starts == 1 }
        await source.send(.init(capturedAt: .now, motion: true))
        try await waitFor { await recorder.states.contains(.present) }
        task.cancel()
        do { try await task.value; XCTFail("expected cancellation") } catch is CancellationError {} catch { XCTFail("\(error)") }
        let stops = await source.stops, states = await recorder.states, current = await monitor.currentState
        XCTAssertEqual(stops, 1); XCTAssertEqual(states, [.unknown, .present, .unknown]); XCTAssertEqual(current, .unknown)
    }
    func testDuplicateRunIsRejectedWithoutStoppingExistingRun() async throws {
        let source = FakeSource()
        let monitor = try PresenceMonitor(source: source, configuration: configuration())
        let task = Task { try await monitor.run { _ in } }
        try await waitFor { await source.starts == 1 }
        do { try await monitor.run { _ in }; XCTFail("expected rejection") }
        catch PresenceError.alreadyRunning {} catch { XCTFail("\(error)") }
        let stops = await source.stops; XCTAssertEqual(stops, 0)
        task.cancel(); _ = await task.result
    }
    func testMonitorCanRestartAfterCancellation() async throws {
        let source = FakeSource()
        let monitor = try PresenceMonitor(source: source, configuration: configuration())
        for expected in 1...2 {
            let task = Task { try await monitor.run { _ in } }
            try await waitFor { await source.starts == expected }
            task.cancel(); _ = await task.result
        }
        let starts = await source.starts, stops = await source.stops
        XCTAssertEqual(starts, 2); XCTAssertEqual(stops, 2)
    }
    func testStartupFailureUnwindsResources() async throws {
        let source = FakeSource()
        await source.setStartupFailure()
        let monitor = try PresenceMonitor(source: source, configuration: configuration())
        do { try await monitor.run { _ in }; XCTFail("expected startup failure") } catch {}
        let stops = await source.stops; XCTAssertEqual(stops, 1)
    }
    func testUnexpectedStreamEndStopsMonitoring() async throws {
        let source = FakeSource()
        let monitor = try PresenceMonitor(source: source, configuration: configuration())
        let task = Task { try await monitor.run { _ in } }
        try await waitFor { await source.starts == 1 }
        await source.end()
        do { try await task.value; XCTFail("expected sourceEnded") }
        catch PresenceError.sourceEnded {} catch { XCTFail("\(error)") }
        let stops = await source.stops; XCTAssertEqual(stops, 1)
    }
    func testWatchdogStopsStalledSource() async throws {
        let source = FakeSource()
        var c = configuration()
        c.camera.sampleInterval = .milliseconds(100)
        c.sensorTimeout = .milliseconds(350)
        c.watchdogInterval = .milliseconds(100)
        let monitor = try PresenceMonitor(source: source, configuration: c)
        do { try await monitor.run { _ in }; XCTFail("expected sensorStalled") }
        catch PresenceError.sensorStalled {} catch { XCTFail("\(error)") }
        let stops = await source.stops; XCTAssertEqual(stops, 1)
    }
    func testSlowConsumerFailsRatherThanLosingEdgesSilently() async throws {
        let source = FakeSource(), recorder = Recorder()
        var c = configuration(); c.eventBufferCapacity = 2
        let monitor = try PresenceMonitor(source: source, configuration: c)
        let task = Task {
            try await monitor.run { event in
                await recorder.append(event)
                // Cancellable suspension simulates slow host work without blocking a thread.
                try? await Task.sleep(for: .seconds(60))
            }
        }
        try await waitFor { await recorder.events.count == 1 }
        let time = ContinuousClock.now.advanced(by: .milliseconds(-100))
        for i in 0..<8 {
            await source.send(.init(capturedAt: time.advanced(by: .milliseconds(i)), motion: false,
                                    light: .init(value: i.isMultiple(of: 2) ? 0 : 1)))
        }
        do { try await task.value; XCTFail("expected slowConsumer") }
        catch PresenceError.slowConsumer {} catch { XCTFail("\(error)") }
        let stops = await source.stops; XCTAssertEqual(stops, 1)
    }
}
