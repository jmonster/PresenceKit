# macOS software validation

## Capture setup

The camera graph is committed before choosing a device's advertised active format and frame duration. No session preset is assigned: inputPriority is not a macOS API, and a generic quality preset must not undo explicit low-resolution/low-rate settings. Output pixel format selection follows device format selection.

CaptureFormatPolicy tests resolution limits, rate bounds, malformed metadata, fixed-rate devices, and readback. Native CMTime range endpoints are preserved. Device settings are checked before and after startRunning and once per second during capture; delivered image dimensions are checked on every frame before image processing. An invalid or over-cap configuration ends monitoring rather than silently raising the configured budget. These checks validate driver-reported settings, not physical wattage or a dishonest driver's true delivery rate.

## CI coverage

The Swift workflow runs native Intel (`macos-15-intel`) and Apple-silicon (`macos-15`) builds and asserts the actual architecture before validation. Both run debug/release tests (including BGRA and NV12 pixel buffers), package and verify PresenceAgent, execute its no-camera self-test, typecheck PlayerPresence.swift at the macOS 13 deployment target, and run an external SwiftPM package against the public product. The external client checks ordered MainActor callbacks, recovery, public output adapters, lifecycle ownership, lease teardown and actual native AVPlayer linkage. No camera permission prompt or real display changes occur during CI.

Linux checks separately validate Swift 6.0 and 6.2, debug/release, and external-client execution. They supplement rather than replace macOS validation. Logs are uploaded as validation artifacts even after failure. Each artifact records the checkout commit and source tree; Linux artifacts also retain the exact source archive. A PR merge-checkout SHA may differ from its branch head, so compare source trees before attributing results. The final Release gate succeeds only if both full platform matrices succeed.

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

## Handoff validation evidence

The published beta.1 baseline passed 61 portable / 69 native tests; its macOS builds used Xcode 26.6 / Apple Swift 6.3.3, targeting macOS 13. Those results do not validate later source changes.

On September 18, 2026, macOS 26 jobs for PR #4 (run 35403010200) and the initial PR #6 tree (run 35407162345) remained queued without runner assignment. The new workflow uses the supported macOS 15 pools for both architectures with unchanged debug/release, package, no-camera smoke, CLI, example and external-consumer checks. This does not remove a native path, loosen assertions, or treat a queued job as successful. Actual OS/toolchain details and native results must be read from the completed candidate run artifacts.

The current portable suite has 109 tests, including 24 additional recovery/lifecycle/deferred-effect regressions over the initial PR #4 tree. Local Linux Swift 6.2.1 debug/release and external-consumer execution passed; the eight publication-safety checks passed. Native-only tests are additional, and their count/result must come from native execution rather than this local Linux run. Command-line validation has 17 no-side-effect invocations on macOS.

No physical camera, display sleep, energy break-even or target-iMac acceptance was measured by these software tests. Issue #1 remains the separate physical acceptance work item.

Runner references: https://docs.github.com/en/actions/reference/runners/github-hosted-runners and https://docs.github.com/actions/reference/workflow-syntax-for-github-actions

The initial hardening candidate revealed a Swift 6.0 XCTest discovery incompatibility for synchronous MainActor test methods. Those tests now use asynchronous entry points with the same assertions; the Swift 6.0 lane remains required. Unknown-state cleanup also has an explicit regression showing that media/power safety does not wait behind slow camera suppression or teardown. Consult the latest candidate run, not an earlier tree, for the resulting compiler/platform status.
