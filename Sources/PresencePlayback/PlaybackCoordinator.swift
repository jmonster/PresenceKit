import Foundation
import PresenceKit

public enum PresencePlaybackError: Error, Sendable, Equatable, CustomStringConvertible {
    case power(String)
    case media(String)
    public var description: String {
        switch self {
        case .power(let message): "Display power: \(message)"
        case .media(let message): "Media playback: \(message)"
        }
    }
}

public enum PresenceDisplaySleepResult: Sendable, Equatable {
    /// Sleep was requested, disabled by configuration, or safely declined.
    case finished
    /// Local input is still recent. The owner will recheck once this delay elapses.
    case deferred(Duration)
}

/// Injectable host boundary. Media/UI operations are short MainActor calls.
/// Legacy power operations must suspend onto a confined utility queue. Cleanup
/// must release resources even when its calling task is already cancelled.
@MainActor
public protocol PresencePlaybackOutput: AnyObject {
    func begin(reportFailure: @escaping @MainActor (PresencePlaybackError) -> Void) throws
    func suppressMotion() async
    func setMonitoring(_ active: Bool, permit: @escaping @Sendable () -> Bool) async throws
    func wake(permit: @escaping @Sendable () -> Bool) async throws
    func setPlaying(_ playing: Bool)
    /// Recheck permit immediately before a queued external side effect. Never
    /// retain it beyond this call. Cancellation must drain owned subprocesses.
    func sleep(permit: @escaping @Sendable () -> Bool) async throws -> PresenceDisplaySleepResult
    func releaseDisplay() async
    func end() async
}

/// One lifecycle-owned run, ordered output, and at most one deferred vacancy task.
/// Transitions are idempotent. Stop/cancellation pauses promptly, then awaits all
/// owned capture, display and deferred work before allowing a replacement run.
@MainActor
public final class PresencePlaybackController {
    private let output: any PresencePlaybackOutput
    private let clock: PresenceClock
    private var running = false
    private var generation: UUID?
    private var fault: PresencePlaybackError?
    private var failures: AsyncThrowingStream<Void, Error>.Continuation?
    private var state: PresenceState?
    private var playing: Bool?
    private var deferredSleep: Task<Void, Never>?
    private var sleepPermit: EffectPermit?
    private var captureRunning = false
    private var analysisHealthy = false
    private var modeAvailable = true
    private var monitoring = false

    public init(output: any PresencePlaybackOutput, clock: PresenceClock = .continuous) {
        self.output = output; self.clock = clock
    }

    public func run(automation: PresenceAutomation,
                    onEvent: @escaping @MainActor @Sendable (PresenceAutomationEvent) async -> Void = { _ in }) async throws {
        guard !running else { throw PresenceError.alreadyRunning }
        running = true; fault = nil; state = nil; playing = nil
        captureRunning = false; analysisHealthy = false; modeAvailable = true; monitoring = false
        let id = UUID(); generation = id
        let pair = AsyncThrowingStream<Void, Error>.makeStream()
        failures = pair.continuation
        var failure: (any Error)?
        do {
            try Task.checkCancellation()
            try output.begin { [weak self] error in self?.fail(error, generation: id) }
            try await withTaskCancellationHandler {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { [self] in
                        try await automation.run { event in
                            await self.apply(event, automation: automation, generation: id)
                            await onEvent(event)
                        }
                    }
                    group.addTask {
                        for try await _ in pair.stream { try Task.checkCancellation() }
                    }
                    do {
                        _ = try await group.next()
                        try Task.checkCancellation()
                        if let fault { throw fault }
                    } catch {
                        // Make output safe before waiting for slow source teardown.
                        invalidate()
                        group.cancelAll()
                        await stopOutputs()
                        throw error
                    }
                    group.cancelAll()
                }
            } onCancel: {
                // One lifecycle notification, not a task per camera frame. The
                // generation check prevents a delayed stop affecting a new run.
                Task { @MainActor [weak self] in self?.cancelOutput(generation: id) }
            }
        } catch { failure = error }
        invalidate()
        await stopOutputs()
        await output.end()
        failures?.finish(); failures = nil; running = false
        if Task.isCancelled || failure is CancellationError { throw CancellationError() }
        if let failure { throw failure }
    }

    private func setPlaying(_ value: Bool) {
        guard playing != value else { return }
        playing = value; output.setPlaying(value)
    }
    private func valid(_ id: UUID) -> Bool { generation == id && fault == nil && !Task.isCancelled }

    private func apply(_ event: PresenceAutomationEvent, automation: PresenceAutomation, generation id: UUID) async {
        guard valid(id) else { return }
        do {
            switch event {
            case .sensing(.statusChanged(.starting)), .sensing(.statusChanged(.stopped)), .sensing(.statusChanged(.failed)):
                captureRunning = false; analysisHealthy = false
            case .sensing(.statusChanged(.running)): captureRunning = true
            case .sensing(.statusChanged(.analysis(let status))):
                analysisHealthy = status == .active || status == .throttled
            case .modeChanged(let mode):
                if case .unavailable = mode { modeAvailable = false } else { modeAvailable = true }
            case .activityChanged(let next):
                guard next != state, next == automation.latestActivity else { return }
                state = next
                await cancelSleep()
                guard valid(id) else { return }
                // Suppress before changing visibility, illumination or playback.
                await output.suppressMotion()
                guard valid(id), next == automation.latestActivity else { return }
                switch next {
                case .present:
                    try await output.wake { automation.latestActivity == .present }
                    guard valid(id), automation.latestActivity == .present else { return }
                    setPlaying(true)
                case .absent:
                    setPlaying(false)
                    await output.releaseDisplay()
                    guard valid(id) else { return }
                    let permit = EffectPermit(); sleepPermit = permit
                    deferredSleep = Task { [weak self] in
                        await self?.sleepWhileAbsent(automation: automation, generation: id, permit: permit)
                    }
                case .unknown:
                    setPlaying(false)
                    await output.releaseDisplay()
                }
            default: break
            }
            guard valid(id) else { return }
            let wanted = captureRunning && analysisHealthy && modeAvailable && automation.sensingAvailable
            if wanted != monitoring {
                monitoring = wanted
                try await output.setMonitoring(wanted) { automation.sensingAvailable }
            }
        } catch is CancellationError { cancelOutput(generation: id) }
        catch { fail(error as? PresencePlaybackError ?? .power(String(describing: error)), generation: id) }
    }

    private func sleepWhileAbsent(automation: PresenceAutomation, generation id: UUID, permit: EffectPermit) async {
        do {
            while valid(id), state == .absent, automation.latestActivity == .absent {
                try Task.checkCancellation()
                await output.suppressMotion()
                guard valid(id), state == .absent, automation.latestActivity == .absent else { return }
                // The worker rechecks both this lifecycle's permit and sensed
                // policy state, even if an arrival callback is still buffered.
                let result = try await output.sleep {
                    permit.isValid && automation.latestActivity == .absent
                }
                try Task.checkCancellation()
                switch result {
                case .finished: return
                case .deferred(let delay):
                    guard delay > .zero, delay <= .seconds(3600) else {
                        throw PresencePlaybackError.power("Invalid local-input recheck delay")
                    }
                    try await clock.sleep(until: clock.now.advanced(by: max(.milliseconds(100), delay)))
                }
            }
        } catch is CancellationError { /* The state/lifecycle owner drains us. */ }
        catch { fail(error as? PresencePlaybackError ?? .power(String(describing: error)), generation: id) }
    }
    private func cancelSleep() async {
        sleepPermit?.cancel(); sleepPermit = nil
        let old = deferredSleep; deferredSleep = nil
        old?.cancel(); await old?.value
    }
    private func invalidate() {
        generation = nil; state = .unknown
        sleepPermit?.cancel(); deferredSleep?.cancel()
        setPlaying(false)
    }
    private func stopOutputs() async {
        await cancelSleep()
        await output.releaseDisplay()
        try? await output.setMonitoring(false) { false }
        monitoring = false
    }
    private func cancelOutput(generation id: UUID) {
        guard generation == id else { return }
        invalidate(); failures?.finish(throwing: CancellationError())
    }
    private func fail(_ error: PresencePlaybackError, generation id: UUID) {
        guard generation == id, fault == nil else { return }
        fault = error; invalidate(); failures?.finish(throwing: error)
    }
}

// Retain the module's original internal names for its existing regression tests.
typealias PlaybackOutput = PresencePlaybackOutput
typealias PlaybackCoordinator = PresencePlaybackController

/// This lock covers only a Boolean; no locks are held across callbacks or awaits.
private final class EffectPermit: @unchecked Sendable {
    private let lock = NSLock()
    private var allowed = true
    var isValid: Bool { lock.withLock { allowed } }
    func cancel() { lock.withLock { allowed = false } }
}
