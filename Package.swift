// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PresenceKit",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "PresenceKit", targets: ["PresenceKit"]),
        .library(name: "PresencePlayback", targets: ["PresencePlayback"]),
        .executable(name: "PresenceAgent", targets: ["PresenceAgent"])
    ],
    targets: [
        .target(name: "PresenceKit"),
        .target(name: "PresencePlayback", dependencies: ["PresenceKit"]),
        .executableTarget(name: "PresenceAgent", dependencies: ["PresenceKit", "PresencePlayback"]),
        .testTarget(name: "PresenceKitTests", dependencies: ["PresenceKit"]),
        .testTarget(name: "PresencePlaybackTests", dependencies: ["PresencePlayback", "PresenceKit"])
    ],
    swiftLanguageModes: [.v6]
)
