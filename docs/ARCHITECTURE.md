# PresenceKit architecture

## Ownership and execution

The library is Swift 6 / macOS 13+. `PresenceMonitor` is an actor, but synchronous AVFoundation work does not run on the cooperative executor or MainActor. Capture configuration, frame processing, runtime-error handling, and state owned by `CameraPresenceSource` are confined to one utility serial queue. Vision has a separate utility serial queue and at most one owned frame copy/request in flight.

`CameraPresenceSource` is narrowly `@unchecked Sendable` for this queue-confinement invariant. `OwnedPixelBuffer` is the immutable privately owned image-copy boundary. The callback bridge's small `CallbackLatch` is `@unchecked Sendable` for its NSLock-protected one-shot result/continuation state. No user callback or continuation is invoked while that lock is held. No camera-pool image crosses into Swift tasks. Source-to-monitor samples are immutable Sendable value snapshots.

A source reserves its UUID lease before permission waiting. It rejects another start without touching the existing lease. Startup failure unwinds only its own reservation/resources. On success it returns `PresenceSession`, containing the sample stream and lease-specific async cleanup. The monitor does not have access to a global source stop.

`PresenceSession.stop()` is actor-serialized and idempotent. Concurrent calls await one cleanup using continuations, not detached tasks. The camera retains the reservation through session stop, Vision-queue drain, and completion-callback drain. Only then may another session start. A stopped lease cannot stop its replacement. Direct source users must stop their acquired session; use `PresenceMonitor.run()` for lifecycle-managed cleanup.

## Structured run and startup races

A run first delivers initial unknown and starting status. A structured task group races source startup against the injected clock's startup deadline. Every outcome is drained: if timeout/cancellation wins while startup simultaneously returns a successful lease, that losing lease is still stopped. Failed startup with no lease is never followed by an unowned stop. Cancellation-aware sources must return promptly from suspendable startup and clean up their own partial state.

Apple camera permission uses `CallbackLatch`: cancellation can resolve the Swift continuation even if the OS permission prompt remains unanswered. Cancellation-before-install, synchronous success, late replies, and duplicate replies are all safe. Resuming a cancelled prompt cannot later configure a camera. A synchronous driver API cannot be forcibly killed; deadlines do not make non-cooperative code preemptible.

After startup a run owns three child tasks: sample consumption, a tolerant monotonic watchdog, and ordered event delivery. A failed child closes admissions and invalidates the reducer before task-group drain. Old samples cannot restore presence during shutdown. After the consumer returns, terminal unknown/status callbacks run before awaited session cleanup. `running` remains true through cleanup, preventing overlapping restarts. Only then does run throw its error or CancellationError.

Callbacks must remain short and cooperate with cancellation. Blocking forever in a callback prevents subsequent ordered notifications and structured completion. The library does not pretend it can force arbitrary host code to return.

## Three different freshness concepts

1. `capturedAt`: a newly delivered camera frame/heartbeat. The watchdog detects frame-delivery silence, not skipped analysis.
2. `analyzedAt`: the newest usable motion analysis or completed Vision frame, with its original acquisition time. Negative completed recognition is also an observation. Stale analysis means unknown, without stopping a still-delivering camera.
3. `motionAt` and `SemanticEvidence.capturedAt`: original positive-evidence times. Cached positives count once; they do not refresh inactivity on every heartbeat. `lightMeasuredAt` similarly prevents cached brightness from advancing dwell.

The camera publishes a cheap heartbeat at most once per min(watchdogInterval, one second), as frames permit, as well as fresh motion-analysis samples. This happens outside the motion gate. No heartbeat is generated merely because inference finishes: inference completion is not camera delivery. There is no additional polling task for frame health.

Input uses bufferingNewest(1) to bound backlog. Each snapshot retains the newest observation and original evidence times, so replacing a sample with a heartbeat does not erase or duplicate its positive evidence. It can still lose distinct rapid observations when a consumer cannot keep up; the contract does not claim lossless frame analysis. Warmup withholds occupancy evidence, while heartbeats keep delivery health observable.

Output transitions use a separate bounded FIFO. Overflow throws slowConsumer; it never silently drops application state transitions. The terminal unknown is based on the last presence state actually delivered, not the last buffered event. Operational statuses are deduplicated by category, not emitted every frame.

## Budgets and recognition cadence

Motion and recognition have independent admission gates. For operation duration d and duty b, the next admission is max(start + minimumInterval, end + d*(1/b - 1)). Missed admissions are skipped. Motion status reports rate throttling, while camera statistics expose measured effective intervals.

Recognition's measured elapsed duration includes frame copying and queue delay. Validation requires absenceDelay >= 2*max(Vision minimumInterval, maximumInferenceDuration / maximumDutyCycle) + sensorTimeout. The default enabled-recognition settings require 208 seconds; the agent/example chooses 240. A completed over-budget request disables subsequent recognition and emits typed failure. There is no preemption guarantee for a running request.

Each active recognizer advertises a result deadline: current acquisition + duration limit + sensorTimeout while in flight, or next budgeted admission + duration limit + sensorTimeout after completion. Missing it produces cadenceExceeded. At an expired absence decision, an overdue active recognizer yields unknown, not absent. Explicit thermal/failure statuses are a documented motion-only fallback. The application can reject that fallback if stationary-occupant coverage is essential.

Duty is elapsed-time scheduling, not CPU/GPU utilization or a power meter. It excludes substantial whole-system loads and cannot prove net energy savings. See POWER.md.

## Deterministic testing

The reducer receives time explicitly. `PresenceClock` erases a monotonic now/sleep implementation without introducing generic types into the application API. Production uses ContinuousClock; tests use a lock-protected virtual clock with cancellation-aware sleepers. The camera can receive the same clock dependency.

The suite tests the original five audit failures as acceptance tests, not reproductions of buggy behavior. Added boundaries include cancelling before callback registration, late/duplicate permission replies, a successful start losing a timeout race, a stopped lease used after replacement, state invalidation while a callback remains suspended, and cached evidence across an observation gap. Synchronization polling in tests only lets scheduled tasks run; virtual advancement determines timing outcomes. Pixel-buffer tests are macOS-only.
