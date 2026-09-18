# Architecture and concurrency contract

## Layers

`CameraPresenceSource` -> bounded newest-value sample stream -> `PresenceMonitor` actor -> bounded ordered transition stream -> one async callback consumer -> host media/display policy.

`PresenceConfiguration` is a validated Sendable value. `PresenceReducer` is a deterministic state machine with externally supplied monotonic instants. `PresenceSource` is injectable: tests replace the camera without permissions, images, or sleeping to simulate minutes of room activity.

The library uses Swift 6 language mode. The main actor owns UI and AVPlayer only in the example application. No blanket `@MainActor` is applied to acquisition or detection.

## Structured ownership

One caller-owned `run` invocation owns a throwing task group with exactly three children: sample consumption, a watchdog, and callback consumption. Cancelling the parent cancels all three; failures cancel siblings. The scope waits for all children before closing the source. Source startup failure also unwinds resources. Running twice on the same monitor is rejected; after cleanup, a new run is permitted.

The watchdog sleeps on `ContinuousClock` with tolerance, then schedules from the current time rather than performing overdue catch-up iterations. Camera sampling and Vision admission are frame-driven rate gates, not additional polling timers.

The callback is Sendable and async. Its isolation is the host's choice. A MainActor callback is awaited, not dispatched in an unbounded chain. Because producer and consumer have distinct tasks, slow UI work does not directly block the camera callback. The event queue is bounded; overflow throws `slowConsumer` from the producer and stops monitoring. It does NOT silently drop entry/exit edges. A final unknown transition invalidates the last delivered known state.

The sample queue intentionally keeps only the newest immutable sample. It may miss very brief movement under load; there is no claim that every frame is analyzed. Cached positive semantic evidence carries its own timestamp and is included in later samples until replaced, preventing a single slow actor hop from losing it. The reducer processes each semantic timestamp only once.

## Legacy framework boundary

`AVCaptureSession.startRunning`, configuration, stop, delegate callbacks, motion state, rate gates, and camera statistics are all confined to one utility GCD queue. They do not block MainActor or the cooperative Swift executor. Async methods bridge to the queue with checked continuations. No Swift task is allocated per camera frame.

`CameraPresenceSource` is narrowly `@unchecked Sendable` because the compiler cannot prove legacy queue confinement. Its mutable state is never accessed outside that queue. `OwnedPixelBuffer` is another audited escape hatch: it owns a copied pixel buffer, never mutates it after handoff, and is read only by the Vision queue. These are implementation details, not a general invitation to mark camera buffers Sendable.

One inference runs at a time. The source marks admission before enqueueing work, then receives an immutable result on the capture queue. A generation number rejects results from a previous session. `stop()` invalidates the generation, disconnects capture, finishes the stream, drains the Vision queue, and drains its completion callback. It waits for synchronous Vision; a duration budget is not a hard real-time cancellation primitive.

## Semantics and failure

Motion confirmations debounce entry, not refreshes while already present. Isolated unconfirmed motion cannot postpone initial absence forever. Accepted motion refreshes presence; periodic human/face evidence can do so without movement. Absence is timed from the last accepted evidence, or the first fresh sample when no evidence has ever been accepted.

Stale camera data wins over a vacancy deadline: no observations means unknown. A watchdog error shuts down capture. The host chooses whether and how to retry. Backoff is a host concern; the example backs off non-permission errors to a maximum of 60 seconds. It does not blindly spin on denied camera access.

Light classification has separate state, source-specific thresholds, and a dwell. Crossing back into the dead band cancels an unconfirmed candidate. A source change or missing reading invalidates light state; it does not alter presence.

Camera frame timestamps mean delegate acquisition time. They are monotonic but are not synchronized hardware exposure timestamps. The AVFoundation late-frame discard policy limits pipeline backlog; this is not a hard real-time capture guarantee.

## Host obligations

Provide camera usage description/entitlements and obtain consent. Own the run in an appropriate task. Keep callbacks bounded/cooperative. Cancel and await monitoring on relevant app/session lifecycle changes. Establish system/display power policy explicitly. Feed display changes back through `suppressMotion` to reduce illumination feedback. Ensure the media player actually pauses decoding/rendering while inactive. Do not equate unknown sensing with a proven empty room.

## Primary references

- Apple, AVCaptureSession.startRunning: https://developer.apple.com/documentation/avfoundation/avcapturesession/startrunning()
- Apple, Handling Frame Drops with AVCaptureVideoDataOutput (TN2445): https://developer.apple.com/library/archive/technotes/tn2445/_index.html
- Swift, ContinuousClock: https://developer.apple.com/documentation/swift/continuousclock
- Swift, AsyncStream: https://developer.apple.com/documentation/swift/asyncstream
- Apple, VNDetectHumanRectanglesRequest: https://developer.apple.com/documentation/vision/vndetecthumanrectanglesrequest
- Apple, VNDetectFaceRectanglesRequest: https://developer.apple.com/documentation/vision/vndetectfacerectanglesrequest
- Apple, preferBackgroundProcessing: https://developer.apple.com/documentation/vision/vnrequest/preferbackgroundprocessing
- Apple, usesCPUOnly: https://developer.apple.com/documentation/vision/vnrequest/usescpuonly
