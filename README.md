# PresenceKit

Local, budgeted room-presence sensing for macOS. **Swift 6, macOS 13+, Intel and Apple silicon, no third-party package dependencies.** Motion is the default; Apple Vision human/face rectangles are optional, additive evidence. The library does not identify people, record images, upload frames, install a daemon, play media, or change power policy.

This is a prerelease package. The lifecycle/budget hardening revision addresses the five findings in the source audit; see [CHANGELOG](CHANGELOG.md) and the [release contract](docs/RELEASE_CONTRACT.md). A green software test suite is not a claim of detection accuracy or measured whole-system energy savings.

## Add to an application

In Xcode add `https://github.com/jmonster/PresenceKit` and select the `PresenceKit` library product. Until a release tag is published, choose `main` and commit `Package.resolved`, or pin an inspected commit using `.revision(...)`.

```swift
// Package dependencies:
.package(url: "https://github.com/jmonster/PresenceKit.git", branch: "main")

// Application target dependencies:
.product(name: "PresenceKit", package: "PresenceKit")
```

Add `NSCameraUsageDescription` to the host application's Info.plist. Enable its camera entitlement when sandboxing/hardened-runtime settings require it. The camera indicator remains visible during capture. Permission is requested from your application when monitoring starts; the package cannot grant permission or bypass the lock screen.

## Drive a media player

Call this from SwiftUI `.task`, or another task whose lifetime matches the feature. Cancelling that task stops monitoring; no independent subscription/timer needs cancellation.

```swift
import AVFoundation
import PresenceKit

@MainActor
func followPresence(player: AVPlayer) async throws {
    var config = PresenceConfiguration.lowPower
    config.absenceDelay = .seconds(120)
    let monitor = try PresenceMonitor.camera(configuration: config)

    try await monitor.run { @MainActor event in
        switch event {
        case .presenceChanged(let change):
            switch change.current {
            case .present: player.play()
            case .absent: player.pause()
            case .unknown:
                // Application policy: pause when sensing is unreliable.
                // Unknown is NOT a claim that the room is empty.
                player.pause()
            }
        case .statusChanged(let status):
            // Surface degradation/failure in your UI or structured logging.
            print("PresenceKit status: \(status)")
        case .lightingChanged(_, let current):
            print("Room lighting: \(current)")
        }
    }
}
```

Handle `CancellationError` as normal shutdown and other errors visibly. The complete [`PlayerPresence`](Examples/PlayerPresence.swift) example does this. Keep callbacks short and cancellation-cooperative. They are awaited in order by one consumer, independently of camera capture; they do not implicitly run on MainActor. Do not launch a detached task on every event.

### Presence and operational events

An initial `unknown` snapshot is delivered before startup. After that, presence events are changes of state, not periodic "still present" callbacks. Positive evidence refreshes the absence timer without repeatedly starting the player.

| State | Meaning |
| --- | --- |
| `present` | Accepted motion or a positive human/face result. |
| `absent` | No accepted evidence for `absenceDelay`, with fresh observations and no overdue active recognition contract. |
| `unknown` | Startup, unavailable/stale analysis, an overdue recognizer at the absence decision, or invalidated state after failure/cancellation. |

`PresenceEvent.statusChanged` is separate from occupancy. It reports `.starting`, `.running`, `.stopped`, `.failed(PresenceError)`, `.analysis(AnalysisStatus)`, or `.recognition(RecognitionStatus)`. Analysis status distinguishes warmup, active, throttled, and stale. Recognition status distinguishes disabled, active, thermal pressure, a missed cadence, and typed failure reasons (frame-copy failure, inference error, duration budget exceeded). Repeated identical analysis/recognition statuses are suppressed.

An explicitly failed or thermally paused recognizer falls back to motion-only, with a status event. Stationary-occupant protection is then unavailable. Applications requiring that protection should handle the status instead of assuming every `absent` decision used a functioning recognizer. A recognizer advertised as active but missing its result deadline instead reports `cadenceExceeded`; an expired presence decision becomes unknown rather than a silent departure.

## Low-compute defaults

Motion uses a 96 x 72 luminance grid with a nominal 500 ms sample interval. The camera requests 5 fps and refuses formats above 640 x 480 or 10 fps by default. Unsupported low-rate formats fail explicitly rather than silently exceeding the caps. Entry requires two positive samples within two seconds; absence defaults to 120 seconds. Warmup is three seconds. Approximately 1–2 seconds of continuing visible motion after warmup is a design target, not a maximum-latency guarantee.

Each work gate skips overdue work instead of catching up. Next admission is no earlier than both the minimum interval and `completion + cost * (1 / duty - 1)`. Motion defaults to a 2% measured elapsed-time duty target; optional Vision defaults to 1%. These are NOT CPU percentages or watts. Camera transport, framework parallelism, hardware power, and the host player must still be considered.

A lightweight frame-delivery heartbeat is independent of analysis admission. Lowering the compute budget therefore cannot masquerade as a dead camera. If analysis becomes too stale, presence becomes unknown and analysis status becomes stale, but a delivering camera remains running and can recover. Cached evidence and lighting retain their original timestamps: heartbeats cannot manufacture confirmations or refresh an old positive result.

## Optional human or face evidence

```swift
var config = PresenceConfiguration.lowPower
config.vision.mode = .humanRectangles   // or .faceRectangles
config.vision.compute = .automatic     // .cpuOnly is a compatibility option
config.absenceDelay = .seconds(240)
```

Recognition is admitted independently of motion, so a motion budget cooldown does not prevent periodic stationary-person checks. At most one request is in flight. Automatic compute lets Vision select supported execution; a Neural Engine is not required. CPU-only is not assumed to use less energy.

Configuration validation accounts for the **budgeted**, not merely nominal, recognition interval:

```text
worst interval = max(minimumInterval, maximumInferenceDuration / maximumDutyCycle)
required absence delay = 2 * worst interval + sensorTimeout
```

With the default one-second maximum duration and 1% duty target, the minimum accepted delay is 208 seconds; 240 seconds is the example policy. A 20-second absence delay with those budgets is rejected with a useful error. The bound reserves two recognition opportunities, plus observation-freshness allowance; it is not a promise that the model recognizes every person.

Measured Vision cost includes the frame copy and queue delay. A request exceeding the completed-duration ceiling disables later Vision work for that run and emits a typed failure. The in-progress synchronous request cannot be forcibly preempted. The runtime result deadline catches unexpected cadence overruns. Serious/critical thermal pressure pauses new requests with explicit fallback status.

## Lifecycle and ownership

`run()` suspends until cancellation or failure. A second concurrent run on the same monitor throws `alreadyRunning`. A monitor can restart after its previous run and cleanup finish. The default `startupTimeout` is 60 seconds and includes permission waiting.

The permission bridge releases its Swift waiter on cancellation or startup timeout and ignores late/duplicate callbacks. This does not dismiss Apple's permission dialog. Startup deadlines are cooperative: a synchronous driver operation or custom source that never returns cannot be safely killed. Such work is drained before the owning task returns.

On failure, `currentState` is invalidated as soon as the coordinator observes it, before waiting for a blocked callback. Once that callback cooperates, the terminal unknown/status events are delivered **before** camera/inference cleanup is awaited. Cleanup can take time; the application is not left with a known-present state solely because cleanup is slow. A callback that never returns still prevents ordered delivery and structured shutdown.

Custom sources now return an exclusive `PresenceSession` from `start()` rather than a stream plus a global `stop()` method. Only a successfully acquired session is stopped. Failed starts must unwind their own partial resources. Session stop is idempotent and concurrent callers await the same cleanup. See the migration details in the [release contract](docs/RELEASE_CONTRACT.md).

`PresenceClock` can be injected into a monitor and camera source; use one clock domain for source timestamps and deadlines. The tests include a cancellation-aware virtual clock. The [architecture guide](docs/ARCHITECTURE.md) documents confinement, buffering, and startup races.

## Light and power integration

`lightingChanged` uses hysteresis and continuous sampled dwell. Camera luminance is a heuristic, not a lux measurement. Automatic exposure, scene composition, and the display itself affect it. Setting `light.legacyCalibration` opts into the undocumented `AppleLMUController` backend; use measured raw `darkBelow`/`brightAbove` values for your machine. Without that calibration it is not probed. Camera brightness is the fallback. Light alone never asserts occupancy.

Keep a `CameraPresenceSource` reference when diagnostics or suppression are needed:

```swift
let source = try CameraPresenceSource(configuration: config)
let monitor = try PresenceMonitor(source: source, configuration: config)
// After the host changes its display/backlight:
await source.suppressMotion(for: .seconds(3))
// Inspect configured format, measured intervals, and typed recognition status:
let statistics = await source.statistics()
```

The host owns display/system-sleep policy. Monitoring needs an awake computer; a sleeping iMac cannot analyze its camera. Display sleep is separate. Pausing media should also stop unnecessary decoding/rendering. **No software setting proves this costs less than leaving the display on.** The [power acceptance procedure](docs/POWER.md) defines the whole-system break-even calculation; the scheduler does not enforce a wattage limit.

## Standalone demonstration

The separate `PresenceAgent` product demonstrates a menu-bar app, local movie pause/resume, optional display management, and retry backoff. It is not required when importing the library.

```sh
bash scripts/build-app.sh
open build/PresenceAgent.app --args --media /absolute/path/movie.mp4 --manage-display
# Optional recognition (sets a 240-second absence policy unless overridden):
open build/PresenceAgent.app --args --human --manage-display
```

`--manage-display` opts into keeping the system awake and controlling display sleep. `--keep-awake` keeps the system awake without display control. Recent user input provides a grace check before forced display sleep. There is no screen unlocker or looping-kiosk implementation. Run as your normal user, not root. The scripts also provide installation/removal of a per-user login agent.

## Tests and release checks

```sh
swift test
swift test -c release
```

The portable suite contains 50 tests, including the five audit regressions, virtual-clock watchdog/startup tests, delayed-cleanup/callback ordering, session ownership, and stale-evidence rejection. macOS additionally exercises pixel-buffer sampling/copying and builds the camera/agent modules. CI runs Intel and Apple-silicon macOS builds, release tests, packaging, and integration-example typechecking, plus Linux core tests. Review the actual CI result for the revision being consumed; a workflow definition alone is not a passed build.

Apple API references: [camera authorization](https://developer.apple.com/documentation/avfoundation/avcapturedevice/requestaccess(for:completionhandler:)), [capture frame handling](https://developer.apple.com/library/archive/technotes/tn2445/_index.html), [human rectangles](https://developer.apple.com/documentation/vision/vndetecthumanrectanglesrequest), [face rectangles](https://developer.apple.com/documentation/vision/vndetectfacerectanglesrequest), [Swift cancellation](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/).
