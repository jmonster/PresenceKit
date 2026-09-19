# Unattended player integration

## Ownership and public entry points

`PresenceMonitor.run` remains a single, run-until-failure sensing operation. Opt into `PresenceAutomation` for recovery and presentation policy; opt into `PresencePlayback` for actions. The camera convenience initializer of `PresencePlayerController` shares all of this behavior between the agent and `Examples/PlayerPresence.swift`.

Retain one controller and await `run` from one lifecycle task. Cancel and **await** that task before replacing it. A run does not return until its capture lease, old inference, output operations and pending display deadline have drained. A failed competing start cannot stop the owner. After a terminal error, correct the cause and explicitly call `run` again; do not surround it with a second automatic retry loop.

Custom hosts can implement the public `PresencePlaybackOutput` protocol and use `PresencePlaybackController`. UI methods are MainActor-isolated; legacy power work belongs on a confined utility queue. The `permit` closure must be checked immediately before a queued wake/hold/sleep action, and cancellation must drain owned work. Cleanup methods must work even in a cancelled task. `PresenceLifecycle` combines independent host, system-sleep and inactive-session suspension reasons without polling or overlapping runs.

The camera-backed AVPlayer controller observes documented NSWorkspace sleep/wake and user-session notifications. Suspension pauses/hides and releases assertions; resumption waits for teardown and reacquires fresh observations. The custom-sensor initializer does not install workspace observers: its host can use `PresenceLifecycle` explicitly. Neither path unlocks a screen or overrides explicit user sleep.

## Retry and failure policy

Default transient backoff is 2, 4, 8, 16, 32, then 60 seconds, with a configurable ceiling and optional retry-count limit. Monotonic delays are cancellation-aware. Inject `PresenceClock` and `PresenceRetryPolicy.jitter` for deterministic testing; jitter defaults to identity and is clamped to 100 milliseconds through the configured ceiling.

Only typed `captureFailure` reasons (`interrupted`, `disconnected`, `deviceInUse`, `mediaServicesReset`), frame-delivery stalls and unexpected stream termination retry. The camera maps documented AVFoundation error domain/codes and interruption/disconnection notifications. An unmatched configured device is treated as disconnected; correct an erroneous device ID manually. Unclassified `cameraUnavailable(String)` is **terminal**, even when its text sounds transient. Custom sources must supply typed reasons rather than localized-message matching.

Permission denial, invalid settings, unsupported capture limits, duplicate ownership, slow consumers, unclassified errors and startup timeout are terminal. The startup deadline includes authorization waiting. It does not repeatedly open a permission dialog. An answer arriving after cancellation/timeout cannot revive an abandoned startup. A Swift timeout cannot forcibly interrupt arbitrary blocking driver or host code; its owner still awaits cleanup.

Backoff resets only after 120 seconds of sustained fresh analysis by default. The health interval advances with real analysis timestamps, not startup, cached heartbeats, silent time, callback delay or slow teardown. Stale analysis, gaps and unavailable requested recognition break the healthy interval. `monitoring` reports startup; `recovered` requires healthy analysis following a retry. Retrying, terminal, stopped and lifecycle-suspended states are separately observable.

AVPlayer/current-item failures and power-adapter errors are terminal. They do not repeatedly reconnect the camera. KVO callbacks carry a run generation; late callbacks from a prior run cannot affect a replacement.

## Recognition fallback and raw state

Apply playback actions to `activityChanged`. `sensing` retains the raw occupancy, lighting and operational events. Presentation decisions never rewrite raw occupancy or turn missing sensing into a confirmed vacant room. `modeChanged` reports motion-only, motion plus recognition, motion fallback with the exact degradation, or unavailable required recognition.

When recognition is requested, the default `.motionOnly(additionalAbsenceDelay: .seconds(120))` accepts motion-only evidence and adds that finite grace only to a present-to-absent decision while recognition is degraded. Repeated absence cannot extend it forever. Arrival cancels it. Unknown bypasses it immediately. Without recognition requested, no extra fallback grace applies.

`.pauseUntilRecovered` requires enabled recognition and pauses/hides while it is unavailable. This is an **availability policy**, not identity recognition or a human-only classifier: motion remains additive evidence when the recognizer works.

| Recognition state | Behavior and recovery |
| --- | --- |
| `warmingUp` | No successful inference yet, including after a thermal/cadence interruption. Strict policy remains unknown until a successful result. |
| `active` | A successful result is available within the source's cadence contract; it need not contain a person. Normal fallback policy resumes. |
| `thermalPressure` | Expensive inference is suspended, with motion still available. Thermal relief permits another budget-admitted inference; only success restores active recognition. |
| `cadenceExceeded` | A promised result is overdue. The raw reducer does not silently infer departure from that missing result. A fresh successful result restores availability. |
| `failed(durationBudgetExceeded)` | Recognition is disabled for this camera session, rather than repeatedly paying an excessive inference cost. Correct settings/conditions and explicitly restart monitoring. |
| `failed(inferenceFailed)` or `failed(frameCopyFailed)` | Recognition is disabled for the session; the selected fallback remains visible. Explicit restart retries recognition after correction. |

Motion-only fallback cannot reliably detect a stationary person. Neither raw absence nor a functioning recognizer proves that the physical room is empty. Nominal recognition frequency is not guaranteed cadence.

## Playback, display deadlines and power ownership

On presence, cancel and await pending vacancy work, suppress camera feedback **before** illumination-changing actions, optionally wake/hold the display, then show/resume the same AVPlayer. On confirmed absence, suppress feedback before hiding/pausing media, release the display assertion, and optionally request display sleep. Actions are idempotent across duplicate events.

Local keyboard/mouse input defers forced sleep for 60 seconds by default. Exactly one owned monotonic deadline rechecks the latest local input and current policy state. More input may defer that same task again; no second absence event is necessary. An arrival, unknown state, failure, suspension or stop invalidates the sleep permit. The utility worker rechecks it even when a newer presence callback is still buffered. Unknown input age safely declines forced sleep.

Unknown, failure and cancellation pause/hide and release display holds, **without forcing sleep**. Emergency invalidation makes media safe before potentially slow driver cleanup. Normal visibility/power changes are preceded by motion suppression. There are no per-frame subprocesses, busy-polling loops or persistent power-setting changes.

`manageDisplay` and `keepSystemAwake` are independent and both default to false. Display management does not implicitly prevent system sleep. The optional idle-system-sleep assertion exists only while sensing analysis is live and the chosen policy permits operation. It is absent during startup, stale/strict-unavailable sensing, backoff, terminal failure, lifecycle suspension and shutdown. The utility worker owns IOKit assertions and App Nap activity; all are released by awaited cleanup. Even with `keepSystemAwake`, explicit user sleep is not prevented. Without it, ordinary system idle sleep can suspend the camera and retry clock until an external wake; software cannot analyze frames on a sleeping computer.

The display command is the fixed `/usr/bin/pmset displaysleepnow`, never a user-supplied shell string. It has a bounded termination attempt, cancellation signaling, and awaited process teardown. OS wake/sleep requests and synchronous driver calls are not real-time guarantees.

## Launch a local movie

```sh
bash scripts/build-app.sh
open build/PresenceAgent.app --args --media /absolute/path/movie.mp4
# Explicit display control and independent system-idle hold:
open build/PresenceAgent.app --args --media /absolute/path/movie.mp4 --manage-display --keep-awake
# Explicit looping and semantic fallback:
open build/PresenceAgent.app --args --media /absolute/path/movie.mp4 --loop --human --fallback motion
```

Quit the running app before changing launch arguments. Grant camera access to the packaged app when prompted. Motion uses a 120-second absence delay; `--human` or `--face` selects a budget-compatible 240-second default. Use `--fallback pause` for strict recognition availability, `--input-grace-seconds N` for local-input grace, and `--check-config` to validate arguments without any camera/display effects.

The agent asynchronously validates local, readable, playable, finite-duration media. Playback is **once by default**; `--loop` explicitly enables AVPlayerLooper, and `--no-loop` remains accepted. This is a windowed reference player, not fullscreen kiosk lockdown. Ordinary presence transitions, reconnects and sleep/session resumptions preserve the player and playback position. **Restart monitoring** retains media; **Reload media and restart** explicitly replaces it (including replay after reaching the end or after a decoder error).

The menu displays raw sensed state, playback decision, actual recognition mode/degradation and recovery status. **Show diagnostics** obtains a one-shot snapshot of actual capture dimensions/rate, analyzed/dropped frames, effective processing intervals, attempts/retries and active/inactive sensing time. These are inexpensive scheduling diagnostics, not CPU percentages, latency guarantees or energy measurements.

For login startup:

```sh
bash scripts/install-agent.sh --media /absolute/path/movie.mp4 --manage-display --keep-awake
bash scripts/uninstall-agent.sh
```

The LaunchAgent runs as the normal user, validates arguments before replacing an installation, and uses crash-only KeepAlive with a 30-second launch throttle. Deliberate quit stays stopped. Terminal errors keep the menu available for explicit correction rather than crashing/re-prompting. There is no supplied separate media-app repository, so only this reusable integration and reference app are modified.

## Validation and references

Virtual-clock tests exercise retries, startup cancellation/timeout, teardown ownership, strict fallback and recovery, buffered-state safety, local-input rechecks, duplicate events and combined lifecycle interruptions. Native tests and the real external package consumer supplement the portable suite; they do not open a real camera or force display sleep. See [MACOS_VALIDATION.md](MACOS_VALIDATION.md) for the evidence contract and [POWER.md](POWER.md) for physical acceptance, tracked separately in issue #1.

Official API references used for the native integration:

- https://developer.apple.com/documentation/avfoundation/avcapturesession/wasinterruptednotification
- https://developer.apple.com/documentation/appkit/nsworkspace/willsleepnotification
- https://developer.apple.com/documentation/appkit/nsworkspace/sessiondidresignactivenotification
- https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPMultipleUsers/Concepts/FastUserSwitching.html
- https://developer.apple.com/documentation/coregraphics/cgeventsource/secondssincelasteventtype(_:eventtype:)
- https://developer.apple.com/documentation/iokit/1557134-iopmassertioncreatewithname
