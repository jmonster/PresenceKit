# Prerelease API and release contract

This document defines the 0.1 prerelease API, including the supervised host integration introduced by 0.1.0-beta.2. The earlier source prerelease v0.1.0-beta.1 was published on September 18, 2026 at commit d3ae546dd0e25e4820e240b4fb13b825250cb882. This is not a 1.0 stability promise, notarized application distribution, or target-hardware acceptance claim. A candidate branch is not published merely because VERSION names a release; use its inspected full commit until the matching tag/release exists.

## Application-facing guarantees

- One concurrent run per monitor. Ordered, awaited callbacks; initial unknown before startup; later presence callbacks only on state changes. Operational notifications have their own typed event.
- Unknown is not absence. No fresh frame delivery is an error; deliberately skipped analysis is not. Stale observations invalidate presence without stopping a delivering camera.
- Active recognition missing its result deadline cannot silently produce an absent decision. Explicitly disabled, failed, or thermally paused recognition is a notified motion-only fallback.
- Logical failure invalidation precedes callback/driver drain. Terminal notifications precede awaited driver cleanup. Cancellation-aware callbacks are a precondition for ordered completion.
- Only successfully acquired leases are stopped. Failed starts unwind themselves. Concurrent/repeated lease stop calls share one cleanup; old handles cannot stop new sessions.
- Startup timeout defaults to 60 seconds. It includes permission waiting, but cannot forcibly interrupt synchronous driver code or an arbitrary non-cooperative custom source.
- No maximum detection-latency, recognition-accuracy, or wattage guarantee. Minimum sampling intervals are admission targets, not real-time deadlines.

## Migration from revision 19f0367

Normal `PresenceMonitor.camera(configuration:)` and `run(onEvent:)` integration is unchanged. Exhaustive switches over PresenceEvent must handle `.statusChanged`. Switches over PresenceReason should handle analysisUnavailable and recognitionUnavailable; PresenceError adds startupTimedOut.

Custom sources must migrate from `start() -> AsyncThrowingStream` plus a global `stop()` to `start() -> PresenceSession`. Return the stream and a lease-specific stop closure only after successful startup:

```swift
return PresenceSession(samples: stream) {
    await backend.close(sessionID: acquiredID)
}
```

The source itself must atomically reject overlapping starts, unwind partial resources on failure, and cooperate with cancellation. Do not make the closure close whichever session happens to be current. Direct callers must await lease.stop(); monitor callers get that ownership automatically.

Existing sources that analyze every sample can keep constructing `PresenceSample(capturedAt:motion:semantic:light:)`. Sources emitting delivery-only heartbeats must use the snapshot initializer and preserve analyzedAt, motionAt, semantic capture time, and lightMeasuredAt. Never relabel cached observations with the current time. All source/monitor times must use the same clock domain.

Enabled Vision configurations must satisfy the new budget-aware absence bound. With default Vision limits use absenceDelay = .seconds(240), not the former 180-second example. The motion-only default remains 120 seconds. A smaller completed-inference limit or a larger permitted duty can justify a smaller absence window; validation explains the computed minimum.

## Versioning and release gate

The supervised host integration uses the next version, 0.1.0-beta.2; v0.1.0-beta.1 remains untouched. A tag must point at a revision that passed Intel and Apple-silicon macOS debug/release tests, camera/agent compilation, app packaging, and integration-example typechecking. The portable Linux debug/release suite must pass too. Workflow configuration by itself is not evidence that checks completed.

Record the commit, compiler/SDK versions, check results, API changes, and known limitations in release notes. Never move a published version tag to a different commit. Breaking prerelease source-protocol changes must be called out explicitly, as above. Do not infer hardware/power claims from these software release checks.

## Supervised host migration and defaults

The low-level monitor does not retry. `PresenceAutomation` is opt-in; `PresencePlayback` composes it with public media/power adapters and lifecycle ownership. See [UNATTENDED.md](UNATTENDED.md) for complete failure, fallback, deadline and assertion semantics.

Exhaustive PresenceError switches add `captureFailure(CaptureFailureReason)` and `cameraConfigurationUnsupported`; RecognitionStatus adds `warmingUp`. New automation-event switches handle `modeChanged`; recovery includes healthy `recovered` and lifecycle `suspended`. Arbitrary cameraUnavailable messages are terminal: custom sources must explicitly identify retryable interruption, disconnection, device-in-use or media-service reset reasons. Startup timeout never automatically reopens authorization. Retry reset is earned by fresh analysis over a sustained interval; time spent waiting or draining does not count.

Display management and keeping the system awake are independent, false-by-default options. No assertions are kept during startup/backoff, unavailable strict policy, stale sensing, suspension or final stop. Explicit system sleep is not prevented. Unknown pauses/hides and releases holds without forced display sleep. Local input defers a single cancellable recheck. Agent playback defaults to once; `--loop` and **Reload media and restart** are explicit actions. Ordinary recovery retains the existing player.

The package manifest requires Swift tools 6.0 and macOS 13 or newer. Native CI compiles at the macOS 13 deployment target on the runner's recorded OS/Xcode/Swift version; that is not execution evidence for every older macOS/compiler or patched Intel camera driver. Portable Linux Swift 6.0/6.2 coverage is a separate claim.

## Publication idempotence and repository enforcement

`VERSION` and `scripts/publish-prerelease.sh` are the authoritative version inputs. Publication runs only on main pushes after Release gate. It creates a missing version tag at the exact tested main commit and verifies it before creating a prerelease. If a tag already targets that commit, release creation is idempotent. If a later successful main build has the same VERSION but a different commit, publication explains the mismatch and skips instead of moving the tag or failing unrelated validation. Bump VERSION for the next release. The eight network-free publication-safety tests cover these branches, API failures and tag races.

Workflow gating is not branch protection or GitHub-enforced immutable releases. The GitHub integration used for this handoff returned HTTP 403 for branch-protection inspection and excludes administration access; no protection setting was applied. An administrator must protect main with the exact required status **Release gate**, preserving existing owner/administrator access and any stronger rules. No workflow token is granted administration rights as a workaround.
