// swift-tools-version: 6.0
import PackageDescription

// An actual external consumer, not @testable import within the library package.
let package = Package(
    name: "PresenceKitClientSmoke",
    platforms: [.macOS(.v13)],
    dependencies: [.package(name: "PresenceKit", path: "../..")],
    targets: [
        .executableTarget(name: "PackageClient", dependencies: [
            .product(name: "PresenceKit", package: "PresenceKit"),
                .product(name: "PresencePlayback", package: "PresenceKit")
        ])
    ],
    swiftLanguageModes: [.v6]
)
