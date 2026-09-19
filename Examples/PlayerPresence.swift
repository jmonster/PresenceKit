import AVFoundation
import PresenceKit
import PresencePlayback

/// Retain this in the host. Call run() from SwiftUI .task or one AppKit-owned task.
/// Transient camera failures are retried automatically. The view/UI should surface
/// lastStatus; permission/configuration/output failures require explicit correction.
/// After a terminal return, a Retry button may call run() again. Await the prior
/// lifecycle task before replacing it; never add an independent retry loop.
@MainActor
final class PlayerPresence {
    let player: AVPlayer
    private let controller: PresencePlayerController
    private(set) var lastStatus = "Not started"

    init(player: AVPlayer) throws {
        self.player = player
        var config = PresenceConfiguration.lowPower
        config.absenceDelay = .seconds(120)
        // Optional additive detection. The fallback grace applies only when degraded:
        // config.vision.mode = .humanRectangles
        // config.absenceDelay = .seconds(240)
        controller = try PresencePlayerController(player: player, configuration: config,
            fallback: .motionOnly(additionalAbsenceDelay: .seconds(120)),
            manageDisplay: false, // Opt in only after choosing the host's display policy.
            keepSystemAwake: false) // Independent opt-in; never prevents explicit user sleep.
    }
    func run() async {
        do {
            try await controller.run { [weak self] event in self?.lastStatus = String(describing: event) }
        } catch is CancellationError {
            lastStatus = "Stopped"
        } catch {
            lastStatus = "Needs attention: \(error)"
        }
    }
}
