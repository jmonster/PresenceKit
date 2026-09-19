# PresenceKit

**Use a Mac's camera to make media playback respond to people in the room.**

PresenceKit is a Swift package that looks for motion, optionally adds human or face detection, and reports whether someone appears to be present. You can use those signals in your own application, let the playback library control an `AVPlayer`, or try the included **PresenceAgent** menu-bar app without writing an integration.

Everything runs locally. Images are not recorded or uploaded, and human/face detection does not identify people. There are no third-party package dependencies.

**Requirements:** macOS 13 or newer, Intel or Apple silicon, a Swift 6 toolchain, and a camera that supports the configured capture limits. This is a source prerelease: build it locally, and expect API changes before 1.0. It is not a notarized end-user download.

[Try the player](#try-the-player) · [Use in your app](#use-in-your-app) · [How presence is decided](#how-presence-is-decided) · [Development and project map](#development-and-project-map)

## What is included?

The project separates **sensing**, **decisions**, and **actions**. You can use only the layers you need.

| Component | What it does | Start here when… |
| --- | --- | --- |
| `PresenceKit` | Reads camera input. `PresenceMonitor` emits raw state changes; `PresenceAutomation` adds retries and decides what to do when recognition is unavailable. | You want presence callbacks or your own application behavior. |
| `PresencePlayback` | Applies those decisions to playback and optional display power control. `PresencePlayerController` is the macOS `AVPlayer` entry point. | You already have a player to integrate. |
| `PresenceAgent` | A windowed local-media player with a menu-bar status UI, built on the same public controller. | You want to try the project or run a standalone player. |

## Try the player

On a Mac with Swift 6 available, clone this fork and build the app bundle:

```sh
git clone https://github.com/jmonster/PresenceKit.git
cd PresenceKit
bash scripts/build-app.sh
open build/PresenceAgent.app --args --media "/absolute/path/movie.mp4"
```

Replace the media path with a readable local movie. The app validates that the media is playable and has a finite duration. Grant camera access when prompted, then move within the camera's view after its three-second warmup. The macOS camera indicator remains visible while capture is active.

With the defaults, accepted motion resumes playback; 120 seconds without accepted evidence pauses it, as long as observations remain fresh. Media **plays once**, not on a loop. Display power settings are unchanged unless you opt in.

Quit the running app before relaunching it with different arguments. Common options are:

| Option | Effect |
| --- | --- |
| `--loop` | Repeat the movie instead of playing it once. |
| `--manage-display` | Wake the display and keep it on while present; request display sleep when absent. Recent local input defers forced sleep. |
| `--keep-awake` | Separately prevent idle system sleep while sensing is live and the policy permits it. Explicit user sleep is still allowed. |
| `--human` or `--face` | Add human-rectangle or face-rectangle detection. Either selects a 240-second default absence delay. |
| `--absence-seconds N` | Set the absence delay, subject to the sensing configuration's minimum requirements. |

The menu shows sensed state, playback decisions, recovery, and recognition mode. **Show diagnostics** reports capture and processing statistics. **Restart monitoring** keeps the current media; **Reload media and restart** reloads it, including replay after it reaches the end.

For login startup, run `bash scripts/install-agent.sh --media "/absolute/path/movie.mp4"` as your normal user, **not with sudo**. Append the same options as above. Remove the login setup with `bash scripts/uninstall-agent.sh`.

See the [unattended operation guide](docs/UNATTENDED.md#launch-a-local-movie) for all launch options, argument validation, and login behavior.

## How presence is decided

Motion is the baseline: the camera image is reduced to a small brightness grid and compared over time. After warmup, entry needs two positive samples within two seconds. Optional Apple Vision detection can add evidence for a person who is not moving. It supplements motion; it does not turn the system into a human-only classifier.

| State | Meaning | Built-in playback behavior |
| --- | --- | --- |
| `present` | The detector has accepted presence evidence. | Show/resume media; optionally wake the display and keep it on. |
| `absent` | No accepted evidence arrived within the configured absence delay, while observations remained fresh. | Pause/hide media; optionally request display sleep. |
| `unknown` | Sensing is not reliable enough to decide, including during startup or stale observations. | Pause/hide media and stop keeping the display on; **never force display sleep because observations are missing**. |

Events report **state changes**, not periodic “still present” messages. Automation may delay an absence action under its recognition-fallback policy, so its playback decision can differ from the raw sensed state.

Absence is not proof that a room is empty. Motion alone can miss a stationary person, and detection accuracy depends on the camera and scene. This is not an identity system, screen unlocker, or kiosk lockdown tool.

## Use in your app

### Add the package

In Xcode, add this repository as a package dependency and select `PresenceKit`. Also select `PresencePlayback` for player integration. For a `Package.swift` manifest, add:

```swift
// In your package's dependencies:
.package(url: "https://github.com/jmonster/PresenceKit.git", exact: "0.1.0-beta.2")

// In your application target's dependencies:
.product(name: "PresenceKit", package: "PresenceKit"),
.product(name: "PresencePlayback", package: "PresenceKit")
```

`0.1.0-beta.2` includes the supervised player API; `v0.1.0-beta.1` is the earlier sensing baseline. For unreleased changes, pin an inspected full commit rather than assuming that `main` matches a release. See the [release contract](docs/RELEASE_CONTRACT.md) for versioning and migration details.

Your host app needs `NSCameraUsageDescription` in its `Info.plist`, plus the camera entitlement when required by its sandbox or hardened-runtime settings. Camera consent belongs to your app. No root access is required.

### Control an existing AVPlayer

The controller handles presence decisions, transient camera recovery, and cleanup. Power control is off by default:

```swift
import AVFoundation
import PresenceKit
import PresencePlayback

@MainActor
func runPresencePlayback(player: AVPlayer) async throws {
    let controller = try PresencePlayerController(
        player: player,
        configuration: .lowPower,
        manageDisplay: false,
        keepSystemAwake: false
    )

    try await controller.run { event in
        print(event) // Surface recovery and degraded sensing in your UI.
    }
}
```

Call this from a SwiftUI `.task` or one AppKit-owned task, and handle errors at that boundary. Keep one controller per active player; do not independently drive the same player while the controller owns playback. Cancel **and await** the run before replacing it. Cancellation pauses playback, releases owned power assertions, and waits for camera cleanup.

The [complete integration example](Examples/PlayerPresence.swift) shows a retained controller and terminal-error handling. Temporary camera faults retry automatically with increasing delays; permission, configuration, and media/power errors require correction. Do not add a second automatic retry loop around the controller.

### Receive callbacks without controlling playback

Use `PresenceAutomation` for supervised sensing with your own actions:

```swift
import PresenceKit

func watchPresence() async throws {
    let configuration = PresenceConfiguration.lowPower
    let source = try CameraPresenceSource(configuration: configuration)
    let automation = try PresenceAutomation(
        source: source,
        configuration: configuration
    )

    try await automation.run { event in
        if case .activityChanged(let state) = event {
            print(state) // Handle present, absent, and unknown here.
        }
    }
}
```

Apply actions to `activityChanged`, the fallback-adjusted decision. `sensing` exposes raw events, `recovery` reports retries and failures, and `modeChanged` reports recognition availability. These callbacks are ordered and asynchronous, but **not implicitly on MainActor**. Keep them short and cancellation-cooperative; hop to MainActor for UI work.

For fully custom policy, use `PresenceMonitor.run` directly; it does not retry. For custom playback or power outputs, implement `PresencePlaybackOutput` and use `PresencePlaybackController`. See [ownership and public entry points](docs/UNATTENDED.md#ownership-and-public-entry-points).

## Tune detection

Start with `PresenceConfiguration.lowPower`, which uses motion only and a 120-second absence delay. To add recognition, configure it **before** constructing the source or controller:

```swift
var configuration = PresenceConfiguration.lowPower
configuration.vision.mode = .humanRectangles // Or .faceRectangles.
configuration.absenceDelay = .seconds(240)
// configuration.vision.compute = .cpuOnly // Compatibility option.
```

The longer absence delay leaves room for budgeted recognition opportunities. With the default enabled-recognition limits, the validated minimum is 208 seconds; 240 seconds is a valid starting point, not a guarantee of stationary-person detection.

When requested recognition becomes unavailable, the default automation policy continues with motion and adds 120 seconds of grace to a pending present-to-absent transition. It never delays `unknown` or error handling. Choose `.pauseUntilRecovered` to pause while recognition is unavailable; this requires recognition to be enabled and does not make detection human-only. The [fallback guide](docs/UNATTENDED.md#recognition-fallback-and-raw-state) explains degradation and recovery.

Default motion processing compares a 96 × 72 grid at a nominal 500 ms interval. Capture requests 5 fps and refuses formats above 640 × 480 or 10 fps. Motion and recognition have separate elapsed-time scheduling budgets; overdue work is skipped rather than queued. These are **not CPU percentages, wattage limits, or guaranteed detection latencies**. See [configuration](Sources/PresenceKit/Configuration.swift) for the available settings and validation rules.

Raw sensing also provides dark/bright transitions. Camera brightness is a heuristic, not a lux measurement, and light changes alone do not establish presence.

## Display sleep is not system sleep

The display can sleep while the camera keeps monitoring, but the **Mac itself must remain awake**. `--manage-display` / `manageDisplay` and `--keep-awake` / `keepSystemAwake` are independent opt-ins. Local keyboard or mouse input defers forced display sleep for 60 seconds by default. Power control uses temporary holds that are released during cleanup, not persistent system-setting changes.

A fully sleeping Mac cannot detect arrivals with this camera pipeline. Occupancy-triggered wake from whole-system sleep needs an independent sensor. Keeping a Mac awake for sensing may also cost more energy than the display automation saves: measure the complete system using the [power acceptance guide](docs/POWER.md).

## Development and project map

From the repository root:

```sh
swift test
swift test -c release
swift run --package-path Examples/PackageClient -c release PackageClient
```

The [CI workflow](.github/workflows/ci.yml) defines native Intel and Apple-silicon tests, app packaging, integration-example typechecking, and portable Linux tests. Linux coverage exercises portable logic; it does not make the camera or player app available on Linux. Native tests use synthetic sensors and mock power outputs rather than opening a camera or forcing display sleep. Check CI artifacts for actual results; passing software tests does not establish detection accuracy or energy savings on your hardware.

```text
Sources/PresenceKit/       Camera input, state changes, configuration, recovery
Sources/PresencePlayback/  Playback actions, display power, lifecycle management
Sources/PresenceAgent/     Reference app and command-line options
Examples/                 Host integration and an external package consumer
Tests/                    Sensing and playback tests
scripts/                  App packaging, login installation, release tooling
```

| Read next | What you will find |
| --- | --- |
| [Unattended operation](docs/UNATTENDED.md) | Ownership, retries, fallback, display behavior, and agent options. |
| [Architecture](docs/ARCHITECTURE.md) | How capture, freshness, scheduling, and concurrency fit together. |
| [macOS validation](docs/MACOS_VALIDATION.md) | What validation evidence covers and what still needs hardware testing. |
| [Power acceptance](docs/POWER.md) | How to measure whether the complete setup saves energy. |
| [Release contract](docs/RELEASE_CONTRACT.md) and [changelog](CHANGELOG.md) | Prerelease guarantees, migration notes, and changes between versions. |

## License

[MIT](LICENSE).
