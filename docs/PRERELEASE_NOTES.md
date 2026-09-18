# PresenceKit 0.1.0-beta.2

An importable Swift 6 / macOS 13+ sensing library and unattended player integration.

- `PresenceKit`: low-cost motion, optional additive Vision, typed state/status events, cancellation and exclusive source-session ownership.
- New `PresenceAutomation`: capped exponential recovery for transient camera failures, explicit permanent errors, healthy-session backoff reset and configurable recognition-fallback policy.
- New `PresencePlayback`: `PresencePlayerController` combines automation, AVPlayer pause/resume, optional scoped power assertions, display-feedback suppression, ordered display transitions and media/output-failure handling.
- PresenceAgent uses the same public controller, validates its arguments, loads local media asynchronously, loops by default, reports failures in its menu and supports restart without overlapping sessions.
- Per-user installation restarts crashes with launchd throttling; intentional quit and terminal camera faults do not cause permission-prompt loops.
- Native Intel/Apple-silicon debug/release, packaging, command-line checks, public integration typecheck and external package consumer are release gates. Linux also tests portable scheduling and output ordering. None of these tests opens a physical camera or forces display sleep.

Compatibility: existing PresenceMonitor callbacks remain unchanged. Exhaustive PresenceError switches must handle the new terminal cameraConfigurationUnsupported case. Import PresencePlayback for the high-level controller; PresenceKit itself never plays media or changes power settings.

This is a source prerelease, not a notarized application or a 1.0 API-stability commitment. Detection is evidence-based, and processing duty targets do not guarantee net whole-system energy savings. Display-off camera sensing keeps the system awake when explicitly requested. Sleeping-computer wake needs independent sensing.
