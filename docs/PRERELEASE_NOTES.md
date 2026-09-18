# PresenceKit 0.1.0-beta.1

Swift 6, macOS 13+, Intel and Apple silicon. Import the PresenceKit library product; PresenceAgent is a separate example application. No third-party package dependencies and no cloud image processing.

This prerelease includes the lifecycle/budget fixes, macOS-supported capture configuration, strict format/rate caps, typed status callbacks, ordered MainActor integration, exclusive session ownership, and cancellation-aware startup. See docs/RELEASE_CONTRACT.md for migration and callback semantics.

Publication requires successful native Intel/Apple-silicon debug and release tests, application packaging and signature verification, an agent smoke run, integration-example typechecking, external SwiftPM client execution, and Swift 6.0/6.2 Linux checks. Camera/permission/display hardware is not exercised by these CI tests.

Use an exact version dependency: `.package(url: "https://github.com/jmonster/PresenceKit.git", exact: "0.1.0-beta.1")`.

Known limits: monitoring requires an awake computer; motion can miss stationary occupants; optional recognition can fall back with typed notification; low processing duty is not a whole-system energy guarantee. The example app is not a notarized end-user distribution. This is a versioned beta, not a 1.0 API-stability claim.
