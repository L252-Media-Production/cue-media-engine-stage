// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Engine",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Engine", targets: ["Engine"]),
    ],
    targets: [
        .target(name: "Engine"),
        .testTarget(name: "EngineTests", dependencies: ["Engine"]),
    ]
)
