# PresenceKit

Local, low-overhead room-presence sensing for macOS, delivered as an importable Swift package. Replaces the RoomSense prototype with a library-first design and a separate example agent.

**Swift 6 language mode. macOS 13+. No third-party package dependencies.** Intel and Apple silicon use the same public API. The camera backend requires macOS; the deterministic core and lifecycle tests also run on Linux. The new minimum OS is intentional: native `ContinuousClock`, `Duration`, and cancellation-aware scheduling. This is not a macOS 11 drop-in replacement.

Motion is the default. Human or face rectangle detection through Apple Vision is an **optional, additive** source of positive evidence. Recognition does not identify people. Images are neither recorded nor uploaded by PresenceKit.

**No wattage guarantee:** a duty-cycle limit is not an energy meter. The camera, image pipeline, host application, and preventing system sleep can dominate power consumption. Validate the complete system using [the power acceptance procedure](docs/POWER.md) before unattended deployment.

## Add the package

In Xcode, add `https://github.com/jmonster/PresenceKit`, choose the `main` branch, and select the `PresenceKit` library product. There is not yet a tagged stable release. Commit `Package.resolved` in your application to pin the resolved revision.

```swift
// In your application's Package.swift:
.package(url: "https://github.com/jmonster/PresenceKit.git", branch: "main")

// In the consuming target's dependencies:
.product(name: "PresenceKit", package: "PresenceKit")
```

The library does not install a daemon, request root access, launch processes, play media, acquire power assertions, or change display settings. The camera source requests normal camera consent when monitoring starts.

## Drive a media player

Call `run()` from a task whose lifetime matches the feature. Cancelling that task tears down capture and waits for owned work to finish. The callback is asynchronous, Sendable, serialized, and independent of the capture producer.

```swift
import AVFoundation
import PresenceKit

@MainActor
func followPresence(player: AVPlayer) async throws {
    var config = PresenceConfiguration.lowPower
    config.absenceDelay = .seconds(120)

    let monitor = try PresenceMonitor.camera(configuration: config)

    try await monitor.run { @MainActor event in
        guard case .presenceChanged(let change) = event else { return }

        switch change.current {
        case .present:
            player.play()
        case .absent:
            player.pause()
        case .unknown:
            // Explicit host policy: pause on unavailable sensing.
            // Unknown is not proof that the room is empty.
            player.pause()
        }
    }
}
```

For SwiftUI, call this inside `.task { ... }`, catch `CancellationError` as normal shutdown, and handle other errors visibly. Do not launch a new unstructured task on every event. AppKit applications can retain one task and cancel/await it at shutdown, as the included agent does. See [Examples/PlayerPresence.swift](Examples/PlayerPresence.swift).

`run()` remains suspended until cancellation or failure. One monitor supports one concurrent run; a second call throws `alreadyRunning`. A completed monitor can be run again. Return quickly from callbacks; forward UI work to `MainActor` as above. A callback that ignores cancellation forever prevents structured shutdown—there is no safe forced termination of arbitrary Swift code.

### Event semantics

`PresenceEvent.presenceChanged` contains previous/current state, reason, and a monotonic timestamp. It emits an initial `unknown` snapshot, then only changes of state. Continuing motion does not spam `present` callbacks. A successful departure decision emits `absent` once, not on every frame. Shutdown/failure invalidates a previously delivered known state with one `unknown` transition.

`present` means accepted motion, human, or face evidence. `absent` means no accepted evidence for `absenceDelay` **while the source is delivering fresh samples**. It is not proof of physical absence. `unknown` covers startup and unavailable/unreliable sensing. A camera failure never becomes a fabricated departure.

The callback can also receive `lightingChanged(previous:current:)`. Use it for dark/bright actions. Light changes alone do not assert occupancy. Light classification uses threshold hysteresis and a continuous dwell, not a threshold-flapping timer.

## Defaults and responsiveness

| Policy | Default |
| --- | --- |
| Camera resolution cap | 640 x 480 |
| Requested camera rate / hard configured cap | 5 fps / 10 fps |
| Motion analysis | Every 500 ms, 96 x 72 grid |
| Entry confirmation | 2 positive motion samples within 2 seconds |
| Absence delay | 120 seconds |
| Camera warmup / stale-source timeout | 3 seconds / 8 seconds |
| Motion processing duty target | 2% measured wall-time duty |
| Vision | Disabled |
| Optional Vision interval / duty target | At least 10 seconds / 1% measured wall-time duty |
| Optional Vision maximum completed duration | 1 second |

After warmup, roughly 1–2 seconds of sustained, visible motion is a starting latency target, not a real-time guarantee. Setting `entryConfirmationCount = 1` trades false-positive resistance for lower latency. Configure the camera's normalized top-left-origin `region` to exclude windows, televisions, and irrelevant movement.

Stationary occupants can time out in motion-only mode. Pets, shadows, curtains, reflections, and displayed faces can create false evidence. Complete darkness, occlusion, subjects outside the field of view, exposure changes, and low-resolution images cause misses. This is not a security, life-safety, or reliable people-counting system.

## Optional Apple Vision

```swift
var config = PresenceConfiguration.lowPower
config.vision.mode = .humanRectangles // Or .faceRectangles, not face identity.
config.vision.compute = .automatic
config.vision.minimumInterval = .seconds(10)
config.vision.maximumDutyCycle = 0.01
config.vision.maximumInferenceDuration = .seconds(1)
config.absenceDelay = .seconds(180)
```

Vision performs independent periodic checks, including while someone is stationary; it is not gated solely on new motion. It can refresh presence or detect an already-seated person at startup. In that situation latency follows the Vision schedule, not the motion entry target.

Automatic compute lets Vision select supported execution resources; the package neither assumes nor requires a Neural Engine. `.cpuOnly` is a compatibility escape hatch for problematic patched Intel graphics, not an efficiency claim. It currently uses the older `usesCPUOnly` API deliberately for the macOS 13 deployment range; modern SDKs may emit its deprecation warning.

There is at most **one** inference in flight, on a dedicated utility queue, using a detached frame copy rather than holding a camera-pool buffer. Failure or an over-duration completed request disables Vision for that run; motion continues. Serious/critical thermal pressure suppresses new Vision requests. Backoff is based on measured inference wall time. The duration ceiling does not preempt a synchronous Vision call already executing, and shutdown waits for it.

Recognition always carries its original delegate-acquisition timestamp. A cached result cannot repeatedly extend the inactivity deadline; stale or old-session evidence is rejected. Negative recognition does not override positive motion. This release intentionally offers additive recognition rather than a human-only mode.

## Camera and light diagnostics

Keep the camera source when you need measurements or display-change feedback:

```swift
let config = PresenceConfiguration.lowPower
let camera = try CameraPresenceSource(configuration: config)
let monitor = try PresenceMonitor(source: camera, configuration: config)

// From another lifecycle-owned task, or in a short event handler:
let stats = await camera.statistics()
print(stats.configuredFPS, stats.lastMotionMilliseconds,
      stats.lastVisionMilliseconds, stats.visionStatus)

// Before changing display brightness/power, suppress feedback-triggered motion:
await camera.suppressMotion(for: .seconds(3))
```

Statistics report configured dimensions/rate, analyzed/dropped frames, last motion-path and inference wall times, brightness, and Vision status. They are not total CPU utilization or watts. The capture backend refuses formats above the configured caps rather than quietly falling back to 1080p/30 fps. Unsupported devices fail explicitly; raise caps only after measurement. Timestamps are taken when the capture delegate receives the sample, not claimed to be camera hardware exposure timestamps.

Light defaults to normalized camera luminance. This is a heuristic affected by auto-exposure and scene content, **not lux**. An optional, undocumented `AppleLMUController` reader can be enabled with measured raw thresholds:

```swift
// Replace these illustrative raw thresholds with measurements from your device.
config.light.legacyCalibration = .init(darkBelow: 20, brightAbove: 80)
```

The legacy reader is not universal across iMac models and is not an App Store compatibility promise. With no calibration it is not probed. When enabled but unavailable, camera luminance is used. SMC/HID backends are not implemented. Handle brightness events separately from presence; do not assume “dark” means “vacant.”

## Permissions and power

The **host application**, not the Swift package, must provide `NSCameraUsageDescription` in its `Info.plist`. A sandboxed/hardened host needs the appropriate camera entitlement (`com.apple.security.device.camera`) and normal user consent. No microphone, Accessibility, Full Disk Access, or root permission is required for sensing. The built-in camera indicator remains active during capture. Keep the application identity/signing stable; local ad-hoc rebuilds may require fresh consent.

The sensing library intentionally does not prevent App Nap or sleep on behalf of its host. Strict background responsiveness requires the host to establish an appropriate activity/power policy and accept its energy cost. No task can inspect camera frames while the whole computer is asleep. Display sleep and system sleep are different. A true-sleep design needs an independent sensor/controller and a separately verified wake mechanism.

For user-session changes, sleep/wake, and camera ownership changes, cancel and await the run, then restart when appropriate. The library stops and throws on a stale stream/runtime failure instead of retrying capture indefinitely behind your back. The sample agent retries non-permission failures with a bounded exponential backoff. It does not monitor before login or unlock the screen.

## Standalone agent / media demo

```sh
bash scripts/build-app.sh
open build/PresenceAgent.app
```

This shows a `PK` menu item and logs transitions without changing display power. To play a local movie only while present:

```sh
open build/PresenceAgent.app --args --media /absolute/path/movie.mp4
```

To opt into an awake-system / sleeping-display policy:

```sh
open build/PresenceAgent.app --args --manage-display --human \
  --absence-seconds 180 --media /absolute/path/movie.mp4
```

`--manage-display` implies `--keep-awake`. The former wakes/holds the display on for presence and requests display sleep after absence, unless keyboard/mouse input occurred in the last 60 seconds. Unknown releases the display hold without forcing sleep. The latter alone keeps monitoring responsive while ordinary display idle settings remain in control. Neither modifies persistent `pmset` settings. The video example pauses/resumes; it does not implement playlist looping, kiosk lock-down, or screen unlocking.

Optional per-user login installation, with arguments carried through into the LaunchAgent:

```sh
bash scripts/install-agent.sh --manage-display --media /absolute/path/movie.mp4
bash scripts/uninstall-agent.sh
```

Do not run installation as root. Authorize camera access to `PresenceAgent` in the logged-in session. The agent is not configured with launchd `KeepAlive`, so permission denial does not create a prompt loop. Do not run multiple copies of the app against the same camera.

Logs:

```sh
/usr/bin/log stream --style compact --level info \
  --predicate 'subsystem == "io.github.jmonster.PresenceKit"'
```

## Build, tests, and validation boundary

```sh
swift test
swift test -c release
bash scripts/build-app.sh # macOS only
```

The suite tests motion/noise rejection, occupancy and lighting transitions, confirmation windows, stale and repeated recognition, rate budgets, startup failures, cancellation, restarts, watchdog expiry, and slow-consumer handling. GitHub Actions is configured for Intel macOS, Apple-silicon macOS, and a Swift 6 Linux core build. Check the actual run result; a workflow's existence does not establish success.

Hardware camera permissions, actual Vision compatibility on OpenCore-patched graphics, detection accuracy, wake behavior, and wall power still require validation on the target machine. Passing deterministic tests cannot establish those properties.

Read [architecture and concurrency invariants](docs/ARCHITECTURE.md) and [power acceptance criteria](docs/POWER.md). MIT licensed; no model weights or captured images are included.
