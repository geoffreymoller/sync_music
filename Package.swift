// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SyncMusic",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "SyncMusicCore", targets: ["SyncMusicCore"]),
        .executable(name: "SyncMusic", targets: ["SyncMusicApp"]),
        .executable(name: "SyncMusicChecks", targets: ["SyncMusicChecks"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-testing.git", exact: "6.2.4"),
    ],
    targets: [
        .target(
            name: "SyncMusicCore"
        ),
        .executableTarget(
            name: "SyncMusicApp",
            dependencies: ["SyncMusicCore"]
        ),
        .executableTarget(
            name: "SyncMusicChecks",
            dependencies: ["SyncMusicCore"]
        ),
        .testTarget(
            name: "SyncMusicCoreTests",
            dependencies: [
                "SyncMusicCore",
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
    ]
)
