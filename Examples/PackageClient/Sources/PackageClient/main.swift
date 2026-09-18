import PresenceKit
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
        print("External package client passed: import, link, MainActor callbacks, teardown")
    }
}
