// swift-tools-version: 5.9
import PackageDescription

// Placeholder: this target is Swift only for now. When the Blackmagic DeckLink SDK is
// placed in vendor/DeckLinkSDK (see docs/sdk-setup.md), an Objective-C++ target that
// wraps the DeckLink API is added next to it, and DeckLinkOutputSink calls into it.
let package = Package(
    name: "DeckLinkBridge",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DeckLinkBridge", targets: ["DeckLinkBridge"]),
    ],
    dependencies: [
        .package(path: "../Engine"),
    ],
    targets: [
        .target(
            name: "DeckLinkBridge",
            dependencies: [.product(name: "Engine", package: "Engine")]
        ),
    ]
)
