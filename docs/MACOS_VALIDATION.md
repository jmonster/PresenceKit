# macOS software validation

## Capture setup

The camera graph is committed before choosing a device's advertised active format and frame duration. No session preset is assigned: inputPriority is not a macOS API, and a generic quality preset must not undo explicit low-resolution/low-rate settings. Output pixel format selection follows device format selection.

CaptureFormatPolicy tests resolution limits, rate bounds, malformed metadata, fixed-rate devices, and readback. Native CMTime range endpoints are preserved. Device settings are checked before and after startRunning and once per second during capture; delivered image dimensions are checked on every frame before image processing. An invalid or over-cap configuration ends monitoring rather than silently raising the configured budget. These checks validate driver-reported settings, not physical wattage or a dishonest driver's true delivery rate.

## CI coverage

The Swift workflow runs native Intel and Apple-silicon builds. Both run debug/release tests (including BGRA and NV12 pixel buffers), package and verify PresenceAgent, execute its no-camera self-test, typecheck PlayerPresence.swift at the macOS 13 deployment target, and run an external SwiftPM package against the public product. The external client checks ordered MainActor callbacks and lease teardown. No camera permission prompt or real display changes occur during CI.

Linux checks separately validate Swift 6.0 and 6.2, debug/release, and external-client execution. They supplement rather than replace macOS validation. Logs are uploaded as validation artifacts even after failure. The final Release gate succeeds only if both full platform matrices succeed.

The beta publication job can run only after that gate on a push to main. It creates a prerelease at the exact tested commit using VERSION and never moves an existing tag. Branch protection is a separate GitHub administrative setting: require the Release gate status to reject unvalidated merges. A workflow check alone does not enable branch protection.

## Local commands

```sh
swift test
swift test -c release
bash scripts/build-app.sh
build/PresenceAgent.app/Contents/MacOS/PresenceAgent --self-test
swiftc -swift-version 6 -typecheck -target "$(uname -m)-apple-macosx13.0" \
  -I "$(swift build --show-bin-path)/Modules" Examples/PlayerPresence.swift
swift run --package-path Examples/PackageClient -c release PackageClient
```

Successful software checks do not measure entry latency, false wakes, or total-system power on a particular machine. See POWER.md for those separate acceptance criteria.
