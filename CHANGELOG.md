# Changelog

## 0.1.0-beta.1 — macOS build and release validation

- Removed the unavailable macOS capture preset. Native device format and frame durations are selected after graph configuration, with pre/post-start and periodic readback validation.
- Added per-frame output dimension caps and rejection of malformed driver metadata.
- Added 11 portable format regressions and 5 native macOS API/NV12 tests (61 portable / 69 native tests total).
- Added an external SwiftPM consumer, packaged-agent no-camera smoke check, signature validation, and native CI log artifacts.
- Added a Release gate covering both architectures, and beta publication only from a passing main commit. Publication never moves a tag and has eight network-free safety tests.
- No source-breaking public API changes relative to the lifecycle-hardening revision.

## Unreleased — 0.1 lifecycle and budget hardening

Addresses the source audit of revision 19f0367.

### Fixed

- Frame-delivery heartbeats are independent of budgeted analysis. Stale observations become unknown without misclassifying a delivering camera as dead.
- Recognition/absence validation uses the worst accepted budgeted interval. Runtime deadline misses are typed and cannot silently trigger departure.
- Logical invalidation and terminal notifications occur before waiting for driver/inference teardown.
- Authorization waits are cancellation-aware, ignore late/duplicate callbacks, and participate in a configurable startup timeout.
- Exclusive PresenceSession leases prevent failed/duplicate starts from stopping another run. Losing successful starts are drained after timeout/cancellation races.
- Cached motion, recognition, and light observations keep original timestamps; heartbeats cannot multiply confirmations, replay pre-gap evidence, or advance light dwell.

### Added

- Typed operational status events and effective-interval camera statistics.
- Injected monotonic clock and cancellation-aware virtual-clock tests.
- Seventeen new portable regression tests (50 portable tests total), covering the five audit defects and additional lifecycle races.
- Explicit source-protocol migration and prerelease contract. Enabled-recognition examples now use a 240-second absence policy with default budgets.

### Compatibility

Custom PresenceSource implementations must return PresenceSession instead of exposing global stop. Exhaustive PresenceEvent switches must handle statusChanged. See docs/RELEASE_CONTRACT.md. No tagged stable release or measured whole-system energy guarantee is implied.
