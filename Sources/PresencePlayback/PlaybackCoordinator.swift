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

/// Test seam for the output boundary. No platform objects enter the sensing actor.
@MainActor
protocol PlaybackOutput: AnyObject {
    func begin(reportFailure: @escaping @MainActor (PresencePlaybackError) -> Void) throws
    func suppressMotion() async
    func wake() throws
    func setPlaying(_ playing: Bool)
    func sleep() async throws
    func releaseDisplay()
    func end()
}

/// Serializes playback/display effects independently of capture. Cancellation or
/// an output error pauses immediately on MainActor, then drains all owned work.
@MainActor
final class PlaybackCoordinator {
    private let output: any PlaybackOutput
    private var running = false
    private var generation: UUID?
    private var fault: PresencePlaybackError?
    private var failures: AsyncThrowingStream<Void, Error>.Continuation?

    init(output: any PlaybackOutput) { self.output = output }

    func run(automation: PresenceAutomation,
             onEvent: @escaping @MainActor @Sendable (PresenceAutomationEvent) async -> Void) async throws {
        guard !running else { throw PresenceError.alreadyRunning }
        running = true; fault = nil
        let id = UUID(); generation = id
        let pair = AsyncThrowingStream<Void, Error>.makeStream()
        failures = pair.continuation
        defer {
            output.setPlaying(false); output.end()
            failures?.finish(); failures = nil
            generation = nil; running = false
        }
        try Task.checkCancellation()
        try output.begin { [weak self] error in self?.fail(error, generation: id) }
        try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { [self] in
                    try await automation.run { event in
                        await self.apply(event, generation: id)
                        await onEvent(event)
                    }
                }
                group.addTask {
                    for try await _ in pair.stream { try Task.checkCancellation() }
                }
                do { _ = try await group.next(); try Task.checkCancellation() }
                catch {
                    // Make output safe BEFORE waiting for source/driver teardown.
                    generation = nil; output.setPlaying(false); output.releaseDisplay()
                    group.cancelAll()
                    throw error
                }
                group.cancelAll()
            }
        } onCancel: {
            // One bounded lifecycle notification, not a per-frame task. A late
            // cancellation cannot affect a new run because it carries its run ID.
            Task { @MainActor [weak self] in self?.cancelOutput(generation: id) }
        }
    }

    private func apply(_ event: PresenceAutomationEvent, generation id: UUID) async {
        guard generation == id, fault == nil else { return }
        guard case .activityChanged(let state) = event else { return }
        do {
            switch state {
            case .present:
                try Task.checkCancellation()
                await output.suppressMotion()
                guard generation == id, fault == nil else { return }
                try Task.checkCancellation()
                try output.wake()
                output.setPlaying(true)
            case .absent:
                output.setPlaying(false)
                await output.suppressMotion()
                guard generation == id, fault == nil else { return }
                try Task.checkCancellation()
                try await output.sleep()
            case .unknown:
                // Missing evidence is never a command to force the screen dark.
                output.setPlaying(false); output.releaseDisplay()
            }
        } catch is CancellationError {
            cancelOutput(generation: id)
        } catch {
            fail(error as? PresencePlaybackError ?? .power(String(describing: error)), generation: id)
        }
    }
    private func cancelOutput(generation id: UUID) {
        guard generation == id else { return }
        generation = nil; output.setPlaying(false); output.releaseDisplay()
    }
    private func fail(_ error: PresencePlaybackError, generation id: UUID) {
        guard generation == id, fault == nil else { return }
        fault = error
        output.setPlaying(false); output.releaseDisplay()
        failures?.finish(throwing: error)
    }
}
