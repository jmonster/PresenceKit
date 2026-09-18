#if os(macOS)
import AppKit
import AVKit
import PresenceKit
import os

@main
@MainActor
struct PresenceAgentMain {
    static func main() {
        // CI smoke path: validate public API linkage without a camera, consent
        // prompt, NSApplication event loop, display assertions, or media playback.
        if CommandLine.arguments.contains("--self-test") {
            do {
                _ = try PresenceMonitor.camera()
                print("PresenceAgent self-test passed (no camera opened)")
            } catch {
                print("PresenceAgent self-test failed: \(error)")
                exit(1)
            }
            return
        }
        let app = NSApplication.shared
        let delegate = AgentDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AgentDelegate: NSObject, NSApplicationDelegate {
    private let log = Logger(subsystem: "io.github.jmonster.PresenceKit", category: "agent")
    private var task: Task<Void, Never>?
    private var source: CameraPresenceSource?
    private var item: NSStatusItem?
    private var player: AVPlayer?
    private var window: NSWindow?
    private let power = DisplayPower()
    private var manageDisplay = false
    private var keepAwake = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let args = CommandLine.arguments
        manageDisplay = args.contains("--manage-display")
        keepAwake = manageDisplay || args.contains("--keep-awake")
        var config = PresenceConfiguration.lowPower
        if args.contains("--human") { config.vision.mode = .humanRectangles }
        if args.contains("--face") { config.vision.mode = .faceRectangles }
        if config.vision.mode != .disabled { config.absenceDelay = .seconds(240) }
        if args.contains("--cpu-only") { config.vision.compute = .cpuOnly }
        if let i = args.firstIndex(of: "--absence-seconds"), i + 1 < args.count,
           let seconds = Double(args[i + 1]), seconds.isFinite { config.absenceDelay = .seconds(seconds) }
        if let i = args.firstIndex(of: "--media"), i + 1 < args.count {
            let p = AVPlayer(url: URL(fileURLWithPath: args[i + 1]))
            player = p
            let view = AVPlayerView(frame: NSRect(x: 0, y: 0, width: 960, height: 540))
            view.player = p
            let w = NSWindow(contentRect: view.bounds, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = "PresenceKit Media Demo"; w.contentView = view; w.center()
            window = w
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "PK"
        let menu = NSMenu()
        menu.addItem(withTitle: "PresenceKit", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self; item.menu = menu; self.item = item
        do {
            let source = try CameraPresenceSource(configuration: config)
            self.source = source
            let monitor = try PresenceMonitor(source: source, configuration: config)
            task = Task { [weak self] in
                var backoff = 2.0
                while !Task.isCancelled {
                    do {
                        try await monitor.run { [weak self] event in await self?.handle(event) }
                    } catch is CancellationError { break }
                    catch {
                        self?.log.error("Monitoring stopped: \(String(describing: error), privacy: .public)")
                        self?.power.close()
                        if let error = error as? PresenceError,
                           case .cameraPermissionDenied = error { break }
                    }
                    do { try await Task.sleep(for: .seconds(backoff)) } catch { break }
                    backoff = min(60, backoff * 2)
                }
                self?.power.close()
            }
        } catch { log.error("\(String(describing: error), privacy: .public)") }
    }

    private func handle(_ event: PresenceEvent) async {
        switch event {
        case .presenceChanged(let change):
            item?.button?.toolTip = "PresenceKit: \(change.current.rawValue)"
            log.info("Presence: \(change.current.rawValue, privacy: .public); reason: \(change.reason.rawValue, privacy: .public)")
            if change.reason == .initial && keepAwake { power.beginMonitoring() }
            switch change.current {
            case .present:
                window?.makeKeyAndOrderFront(nil)
                player?.play()
            case .absent, .unknown:
                // Unknown is an explicit demo policy: pause media, but never force
                // display sleep on failed sensing. Change this for your application.
                player?.pause(); window?.orderOut(nil)
            }
            if manageDisplay {
                await source?.suppressMotion()
                await power.apply(change.current)
            }
            if let source {
                let s = await source.statistics()
                log.info("Camera \(s.configuredWidth)x\(s.configuredHeight) @ \(s.configuredFPS) fps; motion \(s.lastMotionMilliseconds) ms; Vision \(s.visionStatus, privacy: .public), \(s.lastVisionMilliseconds) ms")
            }
        case .statusChanged(let status):
            log.info("Sensing status: \(String(describing: status), privacy: .public)")
        case .lightingChanged(_, let current):
            log.info("Lighting: \(current.rawValue, privacy: .public)")
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let task else { power.close(); return .terminateNow }
        self.task = nil
        task.cancel()
        Task { await task.value; power.close(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}
#else
@main struct PresenceAgentMain {
    static func main() { print("PresenceAgent requires macOS 13 or later.") }
}
#endif
