# PresenceKit

Local, budgeted room-presence sensing for **Swift 6 / macOS 13+**, on Intel and Apple silicon. No third-party package dependencies. Motion is the baseline; Apple Vision human/face rectangles are optional additive evidence, not identification. Images are not recorded or uploaded.

Two importable products separate sensing from action:

- **PresenceKit** provides `PresenceMonitor` for raw state changes and `PresenceAutomation` for supervised recovery and recognition-fallback decisions.
- **PresencePlayback** provides the public `PresencePlaybackOutput` adapter, `PresencePlaybackController`, `PresenceLifecycle`, and macOS `PresencePlayerController`, coordinating an AVPlayer with optional display power management, feedback suppression, recovery and failure cleanup.

`PresenceAgent` is the standalone menu-bar player built on the same public controller. This is a source prerelease, not a notarized end-user binary or a 1.0 API-stability promise.

## Add to an application

Add this repository in Xcode and select both library products for the player integration. The supervised player API is introduced by `0.1.0-beta.2`; the exact pin below requires that tagged release. PR checkouts are not releases. The published `v0.1.0-beta.1` remains the earlier sensing baseline and is never moved.

```swift
.package(url: "https://github.com/jmonster/PresenceKit.git", exact: "0.1.0-beta.2")

// Application target dependencies:
.product(name: "PresenceKit", package: "PresenceKit"),
.product(name: "PresencePlayback", package: "PresenceKit")
```

Before a candidate tag is published, pin its inspected full commit with `.package(url: ..., revision: "FULL_SHA")` instead. Version tags are created only after complete main-branch CI succeeds.

The host application needs `NSCameraUsageDescription` and the camera entitlement when its sandbox/hardened-runtime settings require it. Camera consent belongs to your app; the camera indicator remains visible. No root access is required.

## Unattended media playback

```swift
import AVFoundation
import PresenceKit
import PresencePlayback

@MainActor
func runPlayer(player: AVPlayer) async throws {
    var config = PresenceConfiguration.lowPower
    config.absenceDelay = .seconds(120)
    let controller = try PresencePlayerController(
        player: player,
        configuration: config,
        fallback: .motionOnly(additionalAbsenceDelay: .seconds(120)),
        manageDisplay: false,
        keepSystemAwake: false
    )
    try await controller.run { event in
        print(event) // Surface recovery/degradation in your application's UI.
    }
}
```

Run this from SwiftUI `.task` or one AppKit-owned task. Cancellation pauses playback, releases owned power assertions and awaits capture cleanup. Retain one controller; do not independently drive the same player while it owns playback. Construction itself opens no camera and changes no power setting. [The full example](Examples/PlayerPresence.swift) handles terminal errors.

Transient camera faults retry at 2, 4, 8, 16, 32, then 60 seconds by default. Sessions never overlap. 120 seconds of sustained fresh analysis resets backoff; merely starting a session does not. Permission/configuration errors, unsupported capture caps, an unanswered startup deadline, unclassified `cameraUnavailable` errors, consumer overload and media/power failures stop for correction rather than retrying forever. `PresenceRetryPolicy.maximumRetries` optionally limits transient retries.

On present: suppress motion feedback, wake/hold the display, then show/play media. On absent: suppress feedback before pause/hide, release the hold and optionally request display sleep. Recent local input owns one cancellable deadline/recheck; another absence event is not required. On unknown or failure: pause/hide and release display holds, but **never force the display off based on missing observations**. Power control is opt-in and uses scoped assertions, not persistent system settings. Display management and system-idle-sleep prevention are independent opt-ins. System holds are released during startup, backoff, stale/strict-unavailable sensing, failure and suspension. Explicit user sleep is never blocked; wake/session resumption waits for old teardown before monitoring again.

## Callback-only integration

```swift
let source = try CameraPresenceSource(configuration: config)
let automation = try PresenceAutomation(source: source, configuration: config)
try await automation.run { event in
    if case .activityChanged(let state) = event {
        // Hop to MainActor for UI work. Handle present, absent and unknown.
        print(state)
    }
}
```

Apply actions to `activityChanged`, the fallback-adjusted decision. `sensing` contains raw `PresenceEvent` values; `recovery` reports monitoring, healthy recovery, scheduled retries, stopped/suspended and terminal failure. `modeChanged` makes the actual fallback/degradation observable. Callbacks are serialized, bounded and asynchronous. They are not implicitly MainActor-isolated at this layer and must be short/cancellation-cooperative. No task is spawned per camera frame.

The original `PresenceMonitor.run` and its `PresenceEvent` callback remain available for fully custom policy. Presence events are transitions, not periodic "still present" messages. `present` means accepted evidence; `absent` means no accepted evidence within the configured delay while observations remain fresh; `unknown` means sensing is not currently reliable enough to decide. Absence is not proof of physical vacancy.

## Low-compute defaults and optional recognition

Motion compares a 96 x 72 luminance grid at a nominal 500 ms interval. The camera requests 5 fps and refuses formats above 640 x 480 or 10 fps. Entry needs two positive samples within two seconds; absence defaults to 120 seconds; warmup is three seconds. Roughly 1–2 seconds of continuing visible motion after warmup is a design target, not a guaranteed maximum latency.

```swift
config.vision.mode = .humanRectangles // or .faceRectangles
config.vision.compute = .automatic   // .cpuOnly is a compatibility escape hatch
config.absenceDelay = .seconds(240)
```

Recognition runs independently of motion, with one request in flight. It can refresh presence for stationary occupants. Configuration must allow two worst-budget recognition intervals plus the sensor timeout. With the default one-second accepted duration and 1% elapsed-time duty target, that minimum is 208 seconds; the example uses 240.

When requested recognition degrades, the default automation policy accepts motion but adds 120 seconds of grace to a pending absence transition. It never delays unknown/error handling. `.pauseUntilRecovered` requires enabled recognition and pauses through warmup until a successful result. Thermal recovery and missed cadence also require a new successful inference; copy/inference/duration-budget failures disable recognition for the session until explicit restart. This is an availability policy, not a human-only model. Status events expose thermal pauses, inference failure, duration-budget excess, stale analysis and missed cadence.

Motion and recognition use measured elapsed-time scheduling budgets (2% and 1% defaults), not CPU percentages or watts. Overdue work is skipped, never accumulated. Frame-delivery heartbeats are independent of analysis; cached evidence retains its original time. Synchronous system calls and Vision work cannot be forcibly preempted by a Swift deadline.

## Standalone player

```sh
bash scripts/build-app.sh
open build/PresenceAgent.app --args --media /absolute/path/movie.mp4 --manage-display
# Optional recognition and fallback policy:
open build/PresenceAgent.app --args --media /absolute/path/movie.mp4 --manage-display --human --fallback motion
# Run at login (normal user, not sudo):
bash scripts/install-agent.sh --media /absolute/path/movie.mp4 --manage-display
```

The player validates and loads local finite-duration media asynchronously and plays once by default; `--loop` explicitly enables looping. The menu displays raw sensed state, playback decision, recovery and actual recognition mode. **Restart monitoring** preserves media; **Reload media and restart** explicitly reloads it. **Show diagnostics** reports capture settings, effective processing intervals and retry/active/inactive counters. `--input-grace-seconds N` configures the local-input grace (60 seconds by default). `--keep-awake` separately opts into an idle-system-sleep hold while sensing is live. `--check-config` validates arguments without camera/display side effects. Installation checks arguments before replacing an existing agent. Crash-only launchd recovery is throttled; deliberate quit stays stopped, and permission/configuration errors remain visible without a restart/prompt loop. Uninstall with `bash scripts/uninstall-agent.sh`.

This is not a screen unlocker or kiosk lockdown. To change arguments, quit the running app first or reinstall its login configuration.

## Light and energy

Raw sensing includes hysteretic dark/bright events. Camera luminance is a heuristic, not lux. Calibrated `light.legacyCalibration` opts into the undocumented AppleLMUController backend; unavailable readings fall back to the camera. Light changes alone do not establish presence.

The host's display can sleep while the camera is monitored, but the computer must remain awake. Whole-system sleep with occupancy-triggered wake needs an independent sensor. **A processing-duty limit does not enforce an energy advantage over an always-on display.** [POWER.md](docs/POWER.md) gives the complete-system break-even condition.

## Validation and lifecycle contract

```sh
swift test
swift test -c release
swift run --package-path Examples/PackageClient -c release PackageClient
```

The suite contains 108 portable tests, plus platform-specific native tests. Actual results and tested source identities are recorded in CI artifacts, not inferred from workflow definitions. CI runs native Intel and Apple-silicon debug/release tests, the packaged-agent smoke test, command-line validation, the macOS-13-targeted integration typecheck and an external public-package consumer. Linux Swift 6.0/6.2 exercises portable scheduling, fallback, recovery and output coordination. Native tests use synthetic sensors and mock power outputs; they do not open a camera or force display sleep. Publication requires the full Release gate.

See [unattended operation](docs/UNATTENDED.md), [architecture](docs/ARCHITECTURE.md), [release contract](docs/RELEASE_CONTRACT.md) and [changelog](CHANGELOG.md). A green suite is not a measured detection-accuracy or energy benchmark. Repository branch protection needs administration access separate from the CI publication gate.
