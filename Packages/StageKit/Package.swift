// swift-tools-version: 5.9
import PackageDescription

// The contract between the operator UI and the engine: models, commands, the state snapshot and the
// client protocol. Pure Swift (Foundation only). No AppKit, SwiftUI or Metal, and no dependency on
// Engine or AudioCore (and AudioCore must never depend on this package).
let package = Package(
    name: "StageKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "StageKit", targets: ["StageKit"]),
    ],
    targets: [
        .target(name: "StageKit"),
        .testTarget(name: "StageKitTests", dependencies: ["StageKit"]),
    ]
)
