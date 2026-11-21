// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Engine",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Engine", targets: ["Engine"]),
        .library(name: "AudioCore", targets: ["AudioCore"]),
    ],
    targets: [
        .target(name: "Engine"),
        .testTarget(name: "EngineTests", dependencies: ["Engine"]),
        // Pure audio maths. Depends on nothing (no CoreAudio, no DeckLink, no NDI) so `swift test` runs anywhere.
        .target(name: "AudioCore"),
        .testTarget(
            name: "AudioCoreTests",
            dependencies: ["AudioCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
