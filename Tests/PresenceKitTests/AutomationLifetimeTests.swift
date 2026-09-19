import XCTest
@testable import PresenceKit

private final class PermissionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable (Bool) -> Void)?
    private var requests = 0
    var count: Int { lock.withLock { requests } }
    func request(_ reply: @escaping @Sendable (Bool) -> Void) { lock.withLock { requests += 1; callback = reply } }
    func answer(_ allowed: Bool) {
        let reply = lock.withLock { callback }
        reply?(allowed)
    }
}
private actor PermissionSource: PresenceSource {
    let permission: PermissionProbe
    var reserved = false, started = false
    var starts = 0, stops = 0, unwinds = 0
    init(_ permission: PermissionProbe) { self.permission = permission }
    func start() async throws -> PresenceSession {
        guard !reserved else { throw PresenceError.alreadyRunning }
        reserved = true; starts += 1
        do {
            guard try await CallbackLatch<Bool>.wait(register: { [permission] in permission.request($0) }) else {
                throw PresenceError.cameraPermissionDenied
            }
            try Task.checkCancellation()
            started = true
            let pair = AsyncThrowingStream<PresenceSample, Error>.makeStream()
            return PresenceSession(samples: pair.stream) { await self.close(pair.continuation) }
        } catch { reserved = false; unwinds += 1; throw error }
    }
    func close(_ continuation: AsyncThrowingStream<PresenceSample, Error>.Continuation) {
        continuation.finish(); stops += 1; reserved = false; started = false
    }
}
@MainActor
final class AutomationLifetimeTests: XCTestCase {
    private func eventually(_ predicate: @Sendable () async -> Bool) async throws {
        for _ in 0..<400 { if await predicate() { return }; try await Task.sleep(for: .milliseconds(5)) }
        XCTFail("Synchronization timeout"); throw PresenceError.sensorStalled
    }
    func testSupervisorCancellationUnwindsPermissionAndIgnoresLateAnswer() async throws {
        let time = VirtualClock(), prompt = PermissionProbe(), source = PermissionSource(prompt)
        let a = try PresenceAutomation(source: source, clock: time.clock)
        let task = Task { try await a.run { _ in } }
        try await eventually { prompt.count == 1 }
        task.cancel()
        do { try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        prompt.answer(true); time.advance(by: .seconds(1000))
        let reserved = await source.reserved, started = await source.started, starts = await source.starts
        let unwinds = await source.unwinds, stops = await source.stops
        XCTAssertFalse(reserved); XCTAssertFalse(started); XCTAssertEqual(starts, 1)
        XCTAssertEqual(unwinds, 1); XCTAssertEqual(stops, 0); XCTAssertEqual(time.pendingSleeps, 0)
    }
    func testStartupTimeoutIsTerminalAndDoesNotReprompt() async throws {
        let time = VirtualClock(), prompt = PermissionProbe(), source = PermissionSource(prompt)
        var config = PresenceConfiguration.lowPower; config.startupTimeout = .seconds(1)
        let a = try PresenceAutomation(source: source, configuration: config, clock: time.clock)
        let task = Task { try await a.run { _ in } }
        try await eventually { prompt.count == 1 && time.pendingSleeps >= 2 }
        time.advance(by: .seconds(1))
        do { try await task.value; XCTFail("Expected timeout") } catch { XCTAssertEqual(error as? PresenceError, .startupTimedOut) }
        prompt.answer(true); time.advance(by: .seconds(1000))
        XCTAssertEqual(prompt.count, 1)
        let starts = await source.starts, reserved = await source.reserved
        XCTAssertEqual(starts, 1); XCTAssertFalse(reserved); XCTAssertEqual(time.pendingSleeps, 0)
    }
    func testAlreadyCancelledSupervisorDoesNotAskPermission() async throws {
        let time = VirtualClock(), prompt = PermissionProbe(), source = PermissionSource(prompt)
        let a = try PresenceAutomation(source: source, clock: time.clock)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await a.run { _ in }
        }
        do { try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(prompt.count, 0); XCTAssertEqual(time.pendingSleeps, 0)
    }
}
