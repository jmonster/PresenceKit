# PresenceKit

**Local presence sensing for Swift apps on macOS.**

PresenceKit turns camera observations into **presence, lighting, and sensor-status events**. It uses lightweight motion detection, optional on-device human or face detection, and configurable timing to report whether someone appears to be present. Your application decides what to do with that information.

Use those events to adapt an interface, suspend expensive work, drive an interactive installation, or feed your own automation system. PresenceKit provides the sensing and lifecycle machinery; your application supplies the behavior.

Processing stays on the Mac. Images are not recorded or uploaded, and human/face detection does not identify people. There are no third-party package dependencies.

**Requirements:** Swift 6, macOS 13 or newer, Intel or Apple silicon, and a camera that supports the configured capture limits. This is a source prerelease; APIs may change before 1.0.

[Quick start](#quick-start) · [What it reports](#what-it-reports) · [Recovery and custom behavior](#recovery-and-custom-behavior) · [Configuration](#configuration) · [Optional playback example](#optional-playback-example) · [Development](#development)

## What it reports

PresenceKit separates observations from application behavior. Its core presence states do not imply a particular action:

| State | Meaning |
| --- | --- |
| `present` | The detector has accepted evidence of presence. |
| `absent` | No accepted evidence arrived within the configured absence delay, while observations remained fresh. |
| `unknown` | Sensing is not reliable enough to decide, including during startup or when observations become stale. |

**Unknown is not absent.** Your application should handle it explicitly rather than interpreting a sensor problem as an empty room. Absence is an inference, not proof of physical vacancy.

`PresenceMonitor` also reports lighting transitions (`dark`, `bright`, `unknown`) and operational status, including startup, recognition availability, and failures. Camera brightness is a heuristic, not a calibrated lux reading; light changes alone do not establish presence.

Presence notifications include the previous state, current state, reason, and timestamp. A run starts with an initial `unknown` notification, then reports state changes rather than periodic “still present” messages.

## Quick start

### Add the core library

In Xcode, add this repository as a package dependency and select **`PresenceKit`**. No playback product is needed. For a `Package.swift` manifest, use these entries:

```swift
// In your package's dependencies:
.package(url: "https://github.com/jmonster/PresenceKit.git", exact: "0.1.0-beta.2")

// In your application target's dependencies:
.product(name: "PresenceKit", package: "PresenceKit")
```

This pins a source prerelease. For unreleased changes, pin an inspected full commit rather than assuming `main` matches a release. See the [release contract](docs/RELEASE_CONTRACT.md) for versioning and migration details.

Your host app needs `NSCameraUsageDescription` in its `Info.plist`, plus the camera entitlement when required by its sandbox or hardened-runtime settings. Grant camera access to that app when prompted. The camera indicator remains visible during capture; no root access is required.

### Listen for events

This example observes the room without controlling playback, display power, or any other application behavior:

```swift
import PresenceKit

func observePresence() async throws {
    let monitor = try PresenceMonitor.camera(configuration: .lowPower)

    try await monitor.run { event in
        switch event {
        case .presenceChanged(let change):
            print("Presence:", change.current, "Reason:", change.reason)
        case .lightingChanged(_, let state):
            print("Lighting:", state)
        case .statusChanged(let status):
            print("Sensor:", status)
        }
    }
}
```

Replace the logging with your application's event handling. Run this from one app-owned task, such as a SwiftUI `.task`, and handle errors at that boundary. `run` continues until cancellation or failure; it does not return after the first event. Cancel **and await** the task before replacing it so camera cleanup finishes first.

Callbacks are ordered and asynchronous, but **not implicitly on MainActor**. Keep them short and cancellation-cooperative; hop to MainActor for UI updates. The event buffer is bounded, and a consumer that cannot keep up fails explicitly instead of silently losing transitions.

## Recovery and custom behavior

### Choose the policy you need

`PresenceMonitor` manages a single sensing run and emits raw events. It does not retry failures. Use it when your application owns recovery and decision-making.

`PresenceAutomation`, also in the core `PresenceKit` product, adds automatic retries for classified transient sensor faults and a configurable policy for unavailable recognition. It still leaves application actions to you:

```swift
import PresenceKit

func observeWithRecovery() async throws {
    let configuration = PresenceConfiguration.lowPower
    let source = try CameraPresenceSource(configuration: configuration)
    let automation = try PresenceAutomation(
        source: source,
        configuration: configuration
    )

    try await automation.run { event in
        if case .activityChanged(let state) = event {
            print("Activity:", state) // Connect your application's behavior here.
        }
    }
}
```

Use `activityChanged` for decisions that should respect the selected fallback policy. `sensing` wraps unchanged raw presence, lighting, and status events; `modeChanged` exposes recognition availability; `recovery` reports retries, suspension, and failures. Surface those operational events in your app rather than showing only the activity state.

Retries use increasing delays and do not overlap camera sessions. Permission denial, invalid configuration, and other terminal errors require correction, not another automatic retry loop. The same task ownership and callback rules apply to both APIs. See the [recovery and lifecycle guide](docs/UNATTENDED.md) for the detailed contract.

### Supply your own input

The monitor accepts any implementation of [`PresenceSource`](Sources/PresenceKit/Model.swift). The supplied camera source is one implementation; you can write an adapter for another input or inject a synthetic source for testing. Other hardware adapters are not bundled.

A source returns a `PresenceSession` containing samples and session-specific asynchronous cleanup. Custom sources must preserve observation timestamps, cooperate with cancellation, and respect session ownership. See the [architecture](docs/ARCHITECTURE.md) and [source migration contract](docs/RELEASE_CONTRACT.md) before implementing one.

## Configuration

`PresenceConfiguration.lowPower` starts with motion-only sensing: a three-second camera warmup, two positive samples within two seconds to confirm entry, and a 120-second absence delay. Motion compares a 96 × 72 brightness grid at a nominal 500 ms interval. By default, capture requests 5 fps and refuses formats above 640 × 480 or 10 fps.

Configure the source and monitor with the same settings. To add human detection:

```swift
var configuration = PresenceConfiguration.lowPower
configuration.vision.mode = .humanRectangles // Or .faceRectangles.
configuration.absenceDelay = .seconds(240)

let monitor = try PresenceMonitor.camera(configuration: configuration)
```

Human/face detection uses Apple Vision and can provide evidence for stationary occupants. It **supplements motion**, rather than making the detector human-only. Its processing budget requires a longer absence window: with the default enabled-recognition limits, the validated minimum is 208 seconds. The example uses 240 seconds; neither setting guarantees detection of a stationary person.

When requested recognition is unavailable, `PresenceAutomation` defaults to accepting motion and adding 120 seconds of grace to a pending present-to-absent transition. It never delays `unknown` or error handling. The alternative `.pauseUntilRecovered` policy requires recognition to be enabled and reports `unknown` activity while recognition is unavailable; your application decides how to respond. Despite its name, that policy does not itself pause anything in your app.

[`PresenceConfiguration`](Sources/PresenceKit/Configuration.swift) also exposes the camera selection, image region, motion thresholds, lighting thresholds, recognition compute mode, and timing limits. Set these before constructing the source or monitor. Use the [fallback guide](docs/UNATTENDED.md) for recognition degradation and recovery behavior.

Motion and recognition have separate elapsed-time scheduling budgets. Overdue work is skipped rather than queued. These are **not CPU percentages, wattage limits, or guaranteed detection latencies**. Camera conditions, stationary occupants, and recognition failures need testing in the intended environment.

Camera-backed sensing requires the Mac to remain awake, even when its display is asleep. Waking a fully sleeping Mac in response to occupancy requires an independent sensor. A low-compute preset is not evidence of net energy savings; see the [power acceptance guide](docs/POWER.md).

## Optional playback example

The repository also demonstrates how an application can act on presence events. Neither of these components is required for core sensing:

**`PresencePlayback`** is an optional library for connecting presence decisions to playback and display power. Add that product only for this integration. `PresencePlayerController` is the macOS `AVPlayer` entry point; the [complete example](Examples/PlayerPresence.swift) shows controller ownership and error handling. Custom outputs can implement `PresencePlaybackOutput` and use `PresencePlaybackController`.

**`PresenceAgent`** is a windowed local-media player with menu-bar status and diagnostics, built on that public integration. To try it on a Mac:

```sh
git clone https://github.com/jmonster/PresenceKit.git
cd PresenceKit
bash scripts/build-app.sh
open build/PresenceAgent.app --args --media "/absolute/path/movie.mp4"
```

Replace the path with a readable, playable local movie and grant camera access. Accepted presence resumes playback; absence pauses it. Media plays once unless you add `--loop`. Quit the running app before relaunching with different arguments. This is a locally built reference app, not a notarized end-user download.

`--manage-display` and `--keep-awake` separately opt into display control and idle-system-sleep prevention. Unknown sensing pauses media without forcing display sleep. See the [player integration guide](docs/UNATTENDED.md) for all options, login installation, local-input grace, and power behavior.

## Development

From the repository root:

```sh
swift test
swift test -c release
swift run --package-path Examples/PackageClient -c release PackageClient
```

The [CI workflow](.github/workflows/ci.yml) defines Intel and Apple-silicon tests, app packaging, integration-example typechecking, and portable Linux tests. Linux coverage exercises portable logic, not camera capture or the macOS app. Native tests use synthetic sensors and mock power outputs. Check CI artifacts for actual results; passing software tests does not establish hardware detection accuracy or energy savings.

```text
Sources/PresenceKit/       Sensing, events, configuration, recovery, source interfaces
Sources/PresencePlayback/  Optional playback, display power, lifecycle integration
Sources/PresenceAgent/     Reference media-player app
Examples/                 Host integration and an external package consumer
Tests/                    Sensing and playback tests
scripts/                  App packaging, login installation, release tooling
```

| Read next | What you will find |
| --- | --- |
| [Architecture](docs/ARCHITECTURE.md) | Capture, observation freshness, scheduling, concurrency, and source ownership. |
| [Recovery and integration](docs/UNATTENDED.md) | Retry and fallback policies, lifecycle contracts, and the optional player. |
| [macOS validation](docs/MACOS_VALIDATION.md) | What validation evidence covers and what still needs hardware testing. |
| [Power acceptance](docs/POWER.md) | How to measure complete-system energy rather than just processing time. |
| [Release contract](docs/RELEASE_CONTRACT.md) and [changelog](CHANGELOG.md) | Prerelease guarantees, migration notes, and changes between versions. |

## License

[MIT](LICENSE).
