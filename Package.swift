// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PresenceKit",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "PresenceKit", targets: ["PresenceKit"]),
        .executable(name: "PresenceAgent", targets: ["PresenceAgent"])
    ],
    targets: [
        .target(name: "PresenceKit"),
        .executableTarget(name: "PresenceAgent", dependencies: ["PresenceKit"]),
        .testTarget(name: "PresenceKitTests", dependencies: ["PresenceKit"])
    ],
    swiftLanguageModes: [.v6]
)
