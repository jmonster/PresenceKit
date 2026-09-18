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
                print("PresenceAgent [--media /path/movie.mp4] [--manage-display] [--keep-awake] [--human | --face] [--cpu-only] [--absence-seconds N] [--fallback motion|pause] [--fallback-grace-seconds N] [--no-loop]")
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
    private var recognitionText = ""
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
                self.controller = nil; self.looper?.disableLooping(); self.looper = nil
            }
            do {
                let player = AVQueuePlayer(); self.player = player
                if let path = options.mediaPath {
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
                let controller = try PresencePlayerController(player: player, configuration: options.configuration,
                    fallback: options.fallback, manageDisplay: options.manageDisplay, keepSystemAwake: options.keepAwake) { [weak self] visible in
                        if visible { self?.window?.orderFront(nil) }
                        else { self?.window?.orderOut(nil) }
                    }
                self.controller = controller
                try await controller.run { [weak self] event in self?.handle(event) }
            } catch is CancellationError {
                setStatus("Stopped")
            } catch {
                let message = "Stopped: \(error). Use Restart monitoring after correcting the problem."
                log.error("\(message, privacy: .public)"); setStatus(message)
            }
        }
    }

    private func handle(_ event: PresenceAutomationEvent) {
        switch event {
        case .activityChanged(let activity):
            recoveryText = "Activity: \(activity.rawValue)"
        case .recovery(.retryScheduled(let attempt, let delay, let cause)):
            recoveryText = "Retry \(attempt) in \(delay): \(cause)"
        case .recovery(.failed(let error)):
            recoveryText = "Stopped: \(error)"
        case .sensing(.statusChanged(.recognition(let status))):
            recognitionText = "Recognition: \(status)"
        case .sensing(.statusChanged(.starting)):
            recoveryText = "Starting / awaiting camera permission"; recognitionText = ""
        default: return
        }
        let text = recognitionText.isEmpty ? recoveryText : recoveryText + " • " + recognitionText
        log.info("\(text, privacy: .public)"); setStatus(text)
    }
    private func setStatus(_ text: String) {
        statusItem?.title = text; item?.button?.toolTip = text
    }
    @objc private func restart() {
        guard restartTask == nil, !terminating else { return }
        let old = task; task = nil; old?.cancel()
        restartTask = Task { [weak self] in
            await old?.value
            guard let self else { return }
            self.restartTask = nil
            self.start()
        }
    }
    @objc private func quit() { NSApp.terminate(nil) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        terminating = true
        let old = task, restart = restartTask
        task = nil; restartTask = nil
        old?.cancel(); restart?.cancel()
        player?.pause(); window?.orderOut(nil)
        Task {
            await restart?.value; await old?.value
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
