// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AIMeter",
    platforms: [
        .macOS(.v15)
    ],
    dependencies: [
        // swift-testing module isn't shipped with CommandLineTools — vendor it so
        // `swift test` works in a no-Xcode dev environment (CI still uses the system toolchain).
        .package(url: "https://github.com/swiftlang/swift-testing.git", from: "0.13.0"),
        // Sparkle auto-update framework (binary SPM target; the only runtime dep).
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.6.0"),
    ],
    targets: [
        .target(
            name: "AIMeterCore",
            path: "Sources/AIMeterCore"
        ),
        .executableTarget(
            name: "AIMeterApp",
            dependencies: [
                "AIMeterCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/AIMeterApp"
        ),
        .testTarget(
            name: "AIMeterCoreTests",
            dependencies: [
                .target(name: "AIMeterCore"),
                .product(name: "Testing", package: "swift-testing"),
            ],
            path: "Tests/AIMeterCoreTests",
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "AIMeterAppTests",
            dependencies: [
                .target(name: "AIMeterApp"),
                .product(name: "Testing", package: "swift-testing"),
            ],
            path: "Tests/AIMeterAppTests"
        )
    ]
)