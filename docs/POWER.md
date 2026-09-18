# Power acceptance, not a wattage promise

The acceptance criterion is lower **total system energy for the actual workload**, not a lower loop iteration count or an impressive inference benchmark. PresenceKit cannot infer display power, camera/ISP/USB power, GPU power, or the counterfactual system-sleep energy from its own wall-time measurements.

## What the implementation bounds

Motion defaults to a 96 x 72 luminance grid, two samples per second, no model inference, and an actual configured camera rate requested at 5 fps. The source refuses resolutions above 640 x 480 and rates above 10 fps by default. Unsupported low-rate hardware fails explicitly instead of silently running a higher-cost profile.

For measured work duration `d` and duty target `b`, the next admission is no earlier than `completion + d * (1/b - 1)`, also respecting the minimum interval. There are no catch-up bursts. Motion defaults to b = 0.02; optional Vision defaults to b = 0.01. These are separate measured wall-time schedules, not combined CPU percentages. Parallel execution inside frameworks, GPU/Neural Engine activity, camera capture, copying overhead outside inference, and host work are not all represented by those figures.

A 200 ms inference at a 1% duty target yields about a 20 second start-to-start interval, even when the configured minimum interval is 10 seconds. Recognition responsiveness degrades rather than consuming unlimited compute. An inference that takes more than the configured completed-duration ceiling disables future Vision work for that run. A request already running is not preempted. Thermal pressure also suppresses new requests.

Motion still runs when Vision is disabled. If motion budget throttling or a failing camera prevents fresh samples for the sensor timeout, the monitor becomes unknown and stops capture. The host can fail visibly or retry with backoff.

## Measure the real system

Use a wall-power meter on the iMac. Hold brightness, room lighting, network activity, media content, and test duration consistent. Exclude startup from steady-state averages, then account for repeated startup if the application regularly reconnects. Measure both a normal scene and a worst-case scene containing movement/noise. Test release builds, not only debug builds.

Record these whole-system averages:

| Symbol | Measurement |
| --- | --- |
| B | Existing baseline: display continuously on, normal content workload, no sensing |
| O | PresenceKit running with display/content active |
| V | PresenceKit running with display asleep and media paused/stopped |
| f | Real fraction of time the automated system stays in the active state |

Expected automated average power is `A = f * O + (1 - f) * V`. Deployment passes only when `A < B` by a useful margin larger than measurement variability. False positives and the absence delay increase f and must be included. A display that is almost always on may never repay the sensing overhead.

When O > V, the break-even active fraction is `(B - V) / (O - V)`. If V >= B and O >= B, this design cannot save energy for any occupancy fraction. If O <= B and V < B, it saves in both measured states, subject to transition costs and variability. These are arithmetic comparisons of your measurements, not predictions about an untested iMac.

A simpler component model—only when other loads truly cancel—is `sensing overhead < vacant fraction * avoided display/content power`. Do not use it when camera monitoring prevents system sleep that the baseline would otherwise permit.

Record the iMac model, CPU/GPU, OS and OpenCore patch versions, camera device/format/FPS, configuration, brightness, measured O/V/B, occupied fraction, p50/p95 entry latency, false wakes/hour, stationary-occupant dropouts, Vision disabled reasons, and measurement variability. Repeat after OS/patch changes.

## Decision order

Start with motion-only and a conservative absence delay. Verify that entry detection is useful and the player actually stops decoding/rendering. Add periodic Vision only if stationary occupants justify its measured cost. Compare automatic compute and CPU-only on the actual patched machine; neither is presumed cheapest. Raise capture caps only when necessary and remeasure.

The library's counters and Activity Monitor/Instruments can identify regressions, but they cannot certify the wall-energy comparison above. No default preset or code flag substitutes for those measurements.

If awake-plus-camera draw is too high, move occupancy sensing to an independent sensor and verify a wake mechanism separately. A fully sleeping iMac cannot keep running this camera detector. The application cannot promise both full system sleep and camera-based arrival detection within a few seconds.

## Hardware validation still required

CI can compile and test pure logic on Intel/Apple silicon. It cannot establish camera/TCC behavior, unsupported-driver behavior, thermal response, Vision accuracy, display wake, or power savings on an OpenCore-patched iMac. No hardware benchmark or battery/wall-power result is claimed by this repository.
