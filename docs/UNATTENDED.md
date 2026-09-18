# Unattended operation

## Supported integration

Import the `PresencePlayback` product for a lifecycle-owned `PresencePlayerController`. It owns playback while `run()` is active. Retain it once, call `run()` from one task, and cancel/await that task on shutdown. Do not use the raw sensing events to independently control the same player: `activityChanged` is the fallback-adjusted output decision.

The lower-level `PresenceAutomation` actor is platform-independent and accepts a `PresenceSource`. It supplies ordered `activityChanged`, raw `sensing`, and `recovery` callbacks. The `PresenceMonitor` interface is unchanged for applications that implement their own policies.

## Failure and retry contract

Camera transport failure, missing frames and unexpected stream completion retry at 2, 4, 8, 16, 32, then 60 seconds by default. Delays stay capped; there are no catch-up bursts or overlapping capture sessions. Only 120 seconds of a running attempt resets the streak. Cancellation ends backoff immediately and does not schedule another attempt. A configurable maximum retry count can stop repeated failures.

Permission denial, invalid configuration, unsupported capture caps, a competing session, a slow callback consumer, an unanswered startup deadline and unknown custom errors are terminal. The menu remains visible with a diagnostic. Correct the problem and use **Restart monitoring**; rebuilding a session or granting permission never requires root. An unanswered permission dialog is not retried every minute.

The host pauses media and releases the display hold when sensing becomes unknown. It never calls unknown a vacancy or forcibly blanks the display on that basis. Explicit display management holds the system awake during transient recovery so normal idle sleep cannot strand the retry task. All its assertions are released on terminal exit/cancellation. It does not override intentional system sleep, log out, a lock screen, or another application's assertions.

AVPlayer and current-item failures are monitored using KVO. Output/power errors are terminal and visible; they do not trigger repeated camera reconnection. After failure the player is paused, display assertions are released, and capture cleanup is awaited. KVO callbacks and cancellation carry a run generation, preventing late notifications from affecting a replacement run. Application callbacks must remain short and cancellation-cooperative; Swift cannot forcibly kill arbitrary blocking application code.

## Recognition fallback

With recognition requested, the default fallback is motion-only with 120 seconds of **additional** absence grace. It applies only when an already-active player would become absent while the recognizer is degraded. Fresh movement cancels the pending off decision. Repeated absent samples cannot extend the grace forever. Unknown sensing bypasses the grace immediately.

`pauseUntilRecovered` instead pauses while requested recognition is disabled, failed, thermally paused or overdue. It resumes eligibility when recognition reports active. This checks recognition availability, NOT human identity or human-only detection. Motion still counts as presence.

Without recognition requested, there is no additional fallback grace. The motion-only absence default remains 120 seconds. Healthy recognition uses the configured budget-compatible absence delay (240 seconds by default in the agent). A stationary person can still be missed; neither mode proves physical absence.

## Display and playback ordering

On present: suppress camera motion feedback, acquire the display assertion and request wake, then reveal/play media. On absent: pause/hide immediately, suppress motion feedback, release the display hold and request display sleep. Recent keyboard/mouse input declines forced sleep; macOS's ordinary idle policy then controls it. On unknown/error/cancellation: pause/hide and release holds, but never force display sleep.

`manageDisplay` and `keepSystemAwake` default to false in the public controller. Choosing display management implies keeping the system awake. The standalone command line requires `--manage-display` to opt in. Power management uses scoped IOKit assertions, never persistent pmset configuration. The sleep command is a fixed executable/argument, not a shell string; failures and its bounded termination attempt are surfaced. Cancelling while an output transition is suspended cannot later start playback.

## Local player and login installation

```
bash scripts/build-app.sh
open build/PresenceAgent.app --args --media /absolute/path/movie.mp4 --manage-display
bash scripts/install-agent.sh --media /absolute/path/movie.mp4 --manage-display
```

Local, finite-duration media is validated before camera access. The agent loops by default through AVPlayerLooper; `--no-loop` plays once. Its duration is loaded asynchronously before loop construction. Media visibility and player actions are MainActor-isolated. It is not a screen unlocker or a full-screen kiosk lockdown.

The installed LaunchAgent uses `RunAtLoad`, crash-only `KeepAlive` and a 30-second launch throttle. Intentional quit exits successfully and stays stopped. Terminal sensing/media errors leave the menu-bar application running for attention instead of crashing/re-prompting. `bash scripts/uninstall-agent.sh` removes the login agent. Installation validates all arguments before changing an existing installation.

## Acceptance and release scope

Portable tests cover backoff, permanent errors, retry exhaustion, healthy reset, fallback grace, stale notifications, output order and cancellation during suspended output or driver cleanup. Native tests also instantiate the real AVPlayer-backed controller with synthetic sensors; they do not access a camera, microphone, screen capture or real display power. CI validates the packaged app, its arguments, both architectures and a separate consumer package.

The version tag is published only after all main-branch checks pass. Repository branch protection requires a separate GitHub administration-write capability; publishing a workflow is not evidence of enforcing it. No CI token is granted administration privileges here. See `docs/POWER.md` for the whole-system energy condition; successful tests do not measure watts or occupancy accuracy.

Apple references: https://developer.apple.com/documentation/avfoundation/avplayerlooper
https://developer.apple.com/documentation/iokit/1557134-iopmassertioncreatewithname
https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/
