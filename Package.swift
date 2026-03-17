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
    ]
)
