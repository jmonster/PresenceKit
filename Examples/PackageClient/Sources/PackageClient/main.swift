import PresenceKit
import PresencePlayback
#if os(macOS)
import AVFoundation
#endif

private actor SmokeSource: PresenceSource {
    private var continuation: AsyncThrowingStream<PresenceSample, Error>.Continuation?
    func start() async throws -> PresenceSession {
        let pair = AsyncThrowingStream<PresenceSample, Error>.makeStream()
        continuation = pair.continuation
        return PresenceSession(samples: pair.stream) { await self.close() }
    }
    func sendPresence() { continuation?.yield(.init(capturedAt: .now, motion: true)) }
    func close() { continuation?.finish(); continuation = nil }
}

/// A real external consumer of the public adapter API (not @testable).
@MainActor
private final class SmokeOutput: PresencePlaybackOutput {
    var playing = false, ended = false
    func begin(reportFailure: @escaping @MainActor (PresencePlaybackError) -> Void) {}
    func suppressMotion() async {}
    func setMonitoring(_ active: Bool, permit: @escaping @Sendable () -> Bool) async throws {}
    func wake(permit: @escaping @Sendable () -> Bool) async throws {}
    func setPlaying(_ playing: Bool) { self.playing = playing }
    func sleep(permit: @escaping @Sendable () -> Bool) async throws -> PresenceDisplaySleepResult { .finished }
    func releaseDisplay() async {}
    func end() async { ended = true }
}

@main
struct PackageClient {
    @MainActor
    static func main() async throws {
        #if os(macOS)
        // These references must typecheck and link to the actual macOS backend.
        // Creating a monitor does not start capture or ask for permission.
        _ = try PresenceMonitor.camera()
        let player = AVPlayer()
        #endif
        var config = PresenceConfiguration.lowPower
        config.entryConfirmationCount = 1
        let source = SmokeSource()
        let monitor = try PresenceMonitor(source: source, configuration: config)
        var states: [PresenceState] = []
        do {
            try await monitor.run { @MainActor event in
                switch event {
                case .statusChanged(.running): await source.sendPresence()
                case .presenceChanged(let change):
                    states.append(change.current)
                    #if os(macOS)
                    // Exercise the MainActor/AVPlayer integration without media.
                    player.pause()
                    #endif
                    if change.current == .present { await source.close() }
                default: break
                }
            }
        } catch PresenceError.sourceEnded {
            // The source deliberately ends after the host observes presence.
        }
        guard states == [.unknown, .present, .unknown], await monitor.currentState == .unknown else {
            throw PresenceError.cameraUnavailable("External client received unexpected callback sequence: \(states)")
        }
        let controlledSource = SmokeSource()
        var retry = PresenceRetryPolicy(); retry.maximumRetries = 0
        let automation = try PresenceAutomation(source: controlledSource, configuration: config, retry: retry)
        var controlledStates: [PresenceState] = []
        let handler: @MainActor @Sendable (PresenceAutomationEvent) async -> Void = { event in
            if case .recovery(.monitoring) = event { await controlledSource.sendPresence() }
            if case .activityChanged(let state) = event {
                controlledStates.append(state)
                if state == .present { await controlledSource.close() }
            }
        }
        do {
            #if os(macOS)
            let controller = try PresencePlayerController(player: AVPlayer(), automation: automation)
            try await controller.run(onEvent: handler)
            #else
            try await automation.run(onEvent: handler)
            #endif
        } catch PresenceError.sourceEnded { }
        guard controlledStates == [.unknown, .present, .unknown] else {
            throw PresenceError.invalidConfiguration("Unexpected automation events: \(controlledStates)")
        }
        let hostSource = SmokeSource(), output = SmokeOutput(), lifecycle = PresenceLifecycle()
        let hostAutomation = try PresenceAutomation(source: hostSource, configuration: config, retry: retry)
        let host = PresencePlaybackController(output: output)
        do {
            try await lifecycle.run {
                try await host.run(automation: hostAutomation) { event in
                    if event == .recovery(.monitoring) { await hostSource.sendPresence() }
                    if event == .activityChanged(.present) { await hostSource.close() }
                }
            }
        } catch PresenceError.sourceEnded { }
        guard output.ended, !output.playing else { throw PresenceError.invalidConfiguration("Host output was not cleaned up") }
        #if os(macOS)
        print("External package client passed: sensing, recovery, public adapters/lifecycle, native AVPlayer controller and teardown")
        #else
        print("External package client passed: sensing, recovery, public adapters/lifecycle and teardown (native AVPlayer excluded on Linux)")
        #endif
    }
}
