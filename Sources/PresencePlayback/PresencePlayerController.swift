#if os(macOS)
import AVFoundation
import AppKit
import CoreGraphics
import Foundation
import PresenceKit

/// macOS integration with explicit ownership. Retain one controller and await
/// run() from a lifecycle task. Do not concurrently control its AVPlayer elsewhere.
/// Construction neither opens the camera nor changes playback/power settings.
@MainActor
public final class PresencePlayerController {
    public let player: AVPlayer
    private let automation: PresenceAutomation
    private let coordinator: PlaybackCoordinator
    private let lifecycle = PresenceLifecycle()
    private var running = false
    private var camera: CameraPresenceSource?
    private var observeSystemLifecycle = false

    public convenience init(player: AVPlayer, configuration: PresenceConfiguration = .lowPower,
                retry: PresenceRetryPolicy = .init(),
                fallback: RecognitionFallbackPolicy = .motionOnly(additionalAbsenceDelay: .seconds(120)),
                manageDisplay: Bool = false, keepSystemAwake: Bool = false,
                userInputGraceSeconds: Double = 60,
                visibility: @escaping @MainActor (Bool) -> Void = { _ in }) throws {
        let source = try CameraPresenceSource(configuration: configuration)
        let automation = try PresenceAutomation(source: source, configuration: configuration,
                                               retry: retry, fallback: fallback)
        try self.init(player: player, automation: automation, manageDisplay: manageDisplay,
                      keepSystemAwake: keepSystemAwake, userInputGraceSeconds: userInputGraceSeconds,
                      suppressMotion: { await source.suppressMotion() }, visibility: visibility)
        camera = source; observeSystemLifecycle = true
    }

    /// Injection path for custom sensors and integration tests. The caller supplies
    /// display-feedback suppression when its source uses camera motion.
    public init(player: AVPlayer, automation: PresenceAutomation, manageDisplay: Bool = false,
                keepSystemAwake: Bool = false, userInputGraceSeconds: Double = 60,
                suppressMotion: @escaping @Sendable () async -> Void = {},
                visibility: @escaping @MainActor (Bool) -> Void = { _ in }) throws {
        guard userInputGraceSeconds.isFinite, (0...3600).contains(userInputGraceSeconds) else {
            throw PresenceError.invalidConfiguration("User-input grace must be 0...3600 seconds")
        }
        self.player = player; self.automation = automation
        coordinator = PlaybackCoordinator(output: MediaPlayerOutput(player: player, suppression: suppressMotion,
            manageDisplay: manageDisplay, keepAwake: keepSystemAwake,
            inputGrace: userInputGraceSeconds, visibility: visibility))
    }

    public func run(onEvent: @escaping @MainActor @Sendable (PresenceAutomationEvent) async -> Void = { _ in }) async throws {
        guard !running else { throw PresenceError.alreadyRunning }
        running = true
        let workspace = WorkspaceSuspension(lifecycle: lifecycle)
        if observeSystemLifecycle { workspace.begin() }
        defer { workspace.end(); running = false }
        try await lifecycle.run(operation: { [self] in
            try await coordinator.run(automation: automation, onEvent: onEvent)
        }, onSuspension: { await onEvent(.recovery(.suspended)) })
    }

    /// Inexpensive snapshots, suitable for a user-invoked diagnostics action.
    public func statistics() async -> PresenceAutomationStatistics { await automation.statistics() }
    public func cameraStatistics() async -> CameraStatistics? { await camera?.statistics() }
}

@MainActor
private final class MediaPlayerOutput: PlaybackOutput {
    let player: AVPlayer
    let suppression: @Sendable () async -> Void
    let manageDisplay: Bool
    let keepAwake: Bool
    let inputGrace: Double
    let visibility: @MainActor (Bool) -> Void
    let power = SystemDisplayPower()
    var observations: [NSKeyValueObservation] = []
    var itemObservation: NSKeyValueObservation?
    var generation: UUID?
    var report: (@MainActor (PresencePlaybackError) -> Void)?

    init(player: AVPlayer, suppression: @escaping @Sendable () async -> Void, manageDisplay: Bool, keepAwake: Bool,
         inputGrace: Double, visibility: @escaping @MainActor (Bool) -> Void) {
        self.player = player; self.suppression = suppression; self.manageDisplay = manageDisplay
        self.keepAwake = keepAwake; self.inputGrace = inputGrace; self.visibility = visibility
    }
    func begin(reportFailure: @escaping @MainActor (PresencePlaybackError) -> Void) throws {
        let id = UUID(); generation = id; report = reportFailure
        // KVO supports the macOS 13 baseline. Rare metadata events may arrive on
        // arbitrary queues; never send AVPlayerItem objects across those queues.
        observations = [
            player.observe(\.status, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.checkFailure(id) }
            },
            player.observe(\.currentItem, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.observeItem(id) }
            }
        ]
    }
    func observeItem(_ id: UUID) {
        guard generation == id else { return }
        itemObservation?.invalidate()
        itemObservation = player.currentItem?.observe(\.status, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.checkFailure(id) }
        }
        checkFailure(id)
    }
    func checkFailure(_ id: UUID) {
        guard generation == id else { return }
        if player.status == .failed || player.currentItem?.status == .failed {
            report?(.media(String(describing: player.error ?? player.currentItem?.error)))
        }
    }
    func suppressMotion() async { await suppression() }
    func setMonitoring(_ active: Bool, permit: @escaping @Sendable () -> Bool) async throws {
        if keepAwake { try await power.setMonitoring(active, permit: permit) }
    }
    func wake(permit: @escaping @Sendable () -> Bool) async throws {
        if manageDisplay { try await power.wake(permit: permit) }
    }
    func setPlaying(_ playing: Bool) {
        if playing { visibility(true); player.play() }
        else { player.pause(); visibility(false) }
    }
    func sleep(permit: @escaping @Sendable () -> Bool) async throws -> PresenceDisplaySleepResult {
        if manageDisplay { return try await power.sleep(inputGrace: inputGrace, permit: permit) }
        return .finished
    }
    func releaseDisplay() async { await power.releaseDisplay() }
    func end() async {
        generation = nil
        for observation in observations { observation.invalidate() }
        observations.removeAll(); itemObservation?.invalidate(); itemObservation = nil; report = nil
        await power.close()
    }
}
/// Notification callbacks execute on the main operation queue. Removing observers
/// and generation guarding prevents old notifications from restarting a new owner.
@MainActor
private final class WorkspaceSuspension {
    let lifecycle: PresenceLifecycle
    private var observers: [NSObjectProtocol] = []
    private var active = false
    init(lifecycle: PresenceLifecycle) { self.lifecycle = lifecycle }
    func begin() {
        active = true
        let center = NSWorkspace.shared.notificationCenter
        let entries: [(Notification.Name, PresenceSuspensionReason, Bool)] = [
            (NSWorkspace.willSleepNotification, .systemSleep, true),
            (NSWorkspace.didWakeNotification, .systemSleep, false),
            (NSWorkspace.sessionDidResignActiveNotification, .inactiveSession, true),
            (NSWorkspace.sessionDidBecomeActiveNotification, .inactiveSession, false)
        ]
        for (name, reason, suspended) in entries {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.active else { return }
                    self.lifecycle.setSuspended(suspended, for: reason)
                }
            })
        }
        // Do not open a camera for a background Fast User Switching session.
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        lifecycle.setSuspended(session?[kCGSessionOnConsoleKey] as? Bool != true, for: .inactiveSession)
        lifecycle.setSuspended(false, for: .systemSleep)
    }
    func end() {
        active = false
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
    }
}
#endif
