import AVFoundation
import PresenceKit

/// Call run() from SwiftUI .task or another lifecycle-owned task.
@MainActor
final class PlayerPresence {
    let player: AVPlayer
    private let monitor: PresenceMonitor

    init(player: AVPlayer) throws {
        self.player = player
        var config = PresenceConfiguration.lowPower
        config.absenceDelay = .seconds(120)
        // Opt in only after testing on the target Mac:
        // config.vision.mode = .humanRectangles
        // config.absenceDelay = .seconds(240)
        monitor = try PresenceMonitor.camera(configuration: config)
    }

    func run() async {
        let player = player
        do {
            try await monitor.run { @MainActor event in
                if case .statusChanged(let status) = event {
                    print("PresenceKit operational status: \(status)")
                }
                guard case .presenceChanged(let change) = event else { return }
                switch change.current {
                case .present: player.play()
                case .absent: player.pause()
                case .unknown:
                    // Deliberate failure policy, not a claim of vacancy.
                    player.pause()
                }
            }
        } catch is CancellationError {
            // Normal lifecycle shutdown; camera cleanup has completed.
        } catch {
            player.pause()
            print("PresenceKit stopped: \(error)")
        }
    }
}
