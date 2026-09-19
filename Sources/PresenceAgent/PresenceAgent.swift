#if os(macOS)
import AppKit
import AVKit
import PresenceKit
import PresencePlayback
import os

@main @MainActor
struct PresenceAgentMain {
    static func main() {
        do {
            if CommandLine.arguments.contains("--help") {
                print("PresenceAgent [--media /path/movie.mp4] [--manage-display] [--keep-awake] [--human | --face] [--cpu-only] [--absence-seconds N] [--fallback motion|pause] [--fallback-grace-seconds N] [--input-grace-seconds N] [--loop]")
                return
            }
            if CommandLine.arguments.contains("--self-test") {
                _ = try PresencePlayerController(player: AVPlayer())
                print("PresenceAgent self-test passed (no camera opened or power changed)")
                return
            }
            let options = try AgentOptions(arguments: Array(CommandLine.arguments.dropFirst()))
            if CommandLine.arguments.contains("--check-config") {
                print("PresenceAgent configuration is valid (no camera opened)"); return
            }
            let app = NSApplication.shared
            let delegate = AgentDelegate(options: options)
            app.delegate = delegate
            withExtendedLifetime(delegate) { app.run() }
        } catch {
            print("PresenceAgent: \(error)"); exit(1)
        }
    }
}

@MainActor
final class AgentDelegate: NSObject, NSApplicationDelegate {
    private let log = Logger(subsystem: "io.github.jmonster.PresenceKit", category: "agent")
    private let options: AgentOptions
    private var task: Task<Void, Never>?
    private var restartTask: Task<Void, Never>?
    private var terminating = false
    private var item: NSStatusItem?
    private var statusItem: NSMenuItem?
    private var recoveryText = "Starting"
    private var sensedText = "unknown"
    private var activityText = "unknown"
    private var recognitionText = "Mode: motion only"
    private var diagnosticsTask: Task<Void, Never>?
    private var controller: PresencePlayerController?
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var window: NSWindow?

    init(options: AgentOptions) { self.options = options }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "PK"
        let menu = NSMenu()
        statusItem = menu.addItem(withTitle: "Starting", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        let retry = menu.addItem(withTitle: "Restart monitoring", action: #selector(restart), keyEquivalent: "r")
        retry.target = self
        let reload = menu.addItem(withTitle: "Reload media and restart", action: #selector(reloadMedia), keyEquivalent: "")
        reload.target = self
        let diagnostics = menu.addItem(withTitle: "Show diagnostics", action: #selector(showDiagnostics), keyEquivalent: "d")
        diagnostics.target = self
        let quit = menu.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        item.menu = menu; self.item = item
        start()
    }

    private func start() {
        guard !terminating else { return }
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                self.player?.pause(); self.window?.orderOut(nil)
                self.controller = nil
            }
            do {
                let player = self.player ?? AVQueuePlayer()
                if self.player == nil, let path = options.mediaPath {
                    let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                    guard FileManager.default.isReadableFile(atPath: url.path) else {
                        throw PresencePlaybackError.media("The media file is not readable")
                    }
                    let asset = AVURLAsset(url: url)
                    // Load before constructing AVPlayerLooper: zero or unknown
                    // durations are rejected rather than triggering an ObjC exception.
                    let duration = try await asset.load(.duration)
                    let playable = try await asset.load(.isPlayable)
                    try Task.checkCancellation()
                    guard playable, duration.isNumeric, duration.seconds > 0, duration.seconds.isFinite else {
                        throw PresencePlaybackError.media("Use a playable finite-duration local movie")
                    }
                    let template = AVPlayerItem(asset: asset)
                    if options.loop { looper = AVPlayerLooper(player: player, templateItem: template) }
                    else { player.insert(template, after: nil) }
                    let view = AVPlayerView(frame: NSRect(x: 0, y: 0, width: 960, height: 540))
                    view.player = player; view.controlsStyle = .none
                    if window == nil {
                        let w = NSWindow(contentRect: view.bounds, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
                        w.title = "PresenceKit Player"; w.center(); window = w
                    }
                    window?.contentView = view
                }
                self.player = player
                let controller = try PresencePlayerController(player: player, configuration: options.configuration,
                    fallback: options.fallback, manageDisplay: options.manageDisplay, keepSystemAwake: options.keepAwake,
                    userInputGraceSeconds: options.inputGraceSeconds) { [weak self] visible in
                        if visible { self?.window?.orderFront(nil) }
                        else { self?.window?.orderOut(nil) }
                    }
                self.controller = controller
                try await controller.run { [weak self] event in self?.handle(event) }
            } catch is CancellationError {
                setStatus("Stopped")
            } catch {
                let message = "Stopped: \(error). Correct the problem, then Restart monitoring (or Reload media for a media error)."
                log.error("\(message, privacy: .public)"); setStatus(message)
            }
        }
    }

    private func handle(_ event: PresenceAutomationEvent) {
        switch event {
        case .activityChanged(let activity):
            activityText = activity.rawValue
        case .sensing(.presenceChanged(let change)):
            sensedText = change.current.rawValue
        case .recovery(.monitoring): recoveryText = "Monitoring"
        case .recovery(.retryScheduled(let attempt, let delay, let cause)):
            recoveryText = "Retry \(attempt) in \(delay): \(cause)"
        case .recovery(.failed(let error)):
            recoveryText = "Stopped: \(error)"
        case .modeChanged(let mode):
            switch mode {
            case .motionOnly: recognitionText = "Mode: motion only (stationary people may be missed)"
            case .semantic: recognitionText = "Mode: motion + recognition"
            case .motionFallback(let status): recognitionText = "Mode: motion fallback — \(status)"
            case .unavailable(let status): recognitionText = "Paused: recognition required — \(status)"
            }
        case .recovery(.recovered): recoveryText = "Sensing recovered"
        case .recovery(.suspended): recoveryText = "Suspended: system sleep or inactive session"
        case .recovery(.stopped): recoveryText = "Stopped"
        case .sensing(.statusChanged(.starting)):
            recoveryText = "Starting / awaiting camera permission"
        default: return
        }
        let text = recoveryText + " • sensed: " + sensedText + " • playback: " + activityText + " • " + recognitionText
        log.info("\(text, privacy: .public)"); setStatus(text)
    }
    private func setStatus(_ text: String) {
        statusItem?.title = text; item?.button?.toolTip = text
    }
    @objc private func restart() { scheduleRestart(reload: false) }
    @objc private func reloadMedia() { scheduleRestart(reload: true) }
    private func scheduleRestart(reload: Bool) {
        guard restartTask == nil, !terminating else { return }
        let old = task, diagnostics = diagnosticsTask
        task = nil; old?.cancel(); diagnostics?.cancel()
        restartTask = Task { [weak self] in
            await old?.value; await diagnostics?.value
            guard let self else { return }
            self.restartTask = nil
            guard !Task.isCancelled, !self.terminating else { return }
            if reload {
                self.looper?.disableLooping(); self.looper = nil
                self.player?.removeAllItems(); self.player = nil
            }
            self.start()
        }
    }
    @objc private func showDiagnostics() {
        guard diagnosticsTask == nil, let controller, !terminating else { return }
        diagnosticsTask = Task { [weak self] in
            let stats = await controller.statistics(), camera = await controller.cameraStatistics()
            guard let self else { return }
            defer { self.diagnosticsTask = nil }
            guard !Task.isCancelled, !self.terminating else { return }
            var text = "Attempts: \(stats.attempts), retries: \(stats.retries); active sensing: \(stats.activeTime), inactive/backoff: \(stats.inactiveTime). Mode: \(stats.mode)"
            if let camera {
                text += "\nCapture: \(camera.configuredWidth)×\(camera.configuredHeight) @ \(camera.configuredFPS) fps. Analyzed: \(camera.analyzedFrames), dropped: \(camera.droppedFrames). Motion interval: \(camera.effectiveMotionInterval); Vision interval: \(camera.effectiveVisionInterval)."
            }
            self.log.info("\(text, privacy: .public)")
            self.setStatus(text)
        }
    }
    @objc private func quit() { NSApp.terminate(nil) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        terminating = true
        let old = task, restart = restartTask, diagnostics = diagnosticsTask
        task = nil; restartTask = nil; diagnosticsTask = nil
        old?.cancel(); restart?.cancel(); diagnostics?.cancel()
        player?.pause(); window?.orderOut(nil)
        Task {
            await restart?.value; await old?.value; await diagnostics?.value
            self.looper?.disableLooping(); self.looper = nil; self.player = nil
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
#else
@main struct PresenceAgentMain {
    static func main() { print("PresenceAgent requires macOS 13 or later.") }
}
#endif
