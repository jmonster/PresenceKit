# Prerelease API and release contract

This document defines the lifecycle/budget hardening revision of the 0.1 prerelease API. It is not a 1.0 stability claim and does not imply a Git tag already exists. Consume an inspected commit and commit Package.resolved until a tagged release is published.

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

The first tagged hardening build should be a prerelease, for example 0.1.0-beta.1. A tag must point at a revision that passed Intel and Apple-silicon macOS debug/release tests, camera/agent compilation, app packaging, and integration-example typechecking. The portable Linux debug/release suite must pass too. Workflow configuration by itself is not evidence that checks completed.

Record the commit, compiler/SDK versions, check results, API changes, and known limitations in release notes. Never move a published version tag to a different commit. Breaking prerelease source-protocol changes must be called out explicitly, as above. Do not infer hardware/power claims from these software release checks.
