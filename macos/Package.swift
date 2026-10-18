// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "iBridge",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "iBridgeHost", targets: ["iBridgeHost"]),
        .library(name: "IBridgeCore", targets: ["IBridgeCore"])
    ],
    targets: [
        .target(name: "IBridgeCore", resources: [.copy("Resources/operations.json"), .copy("Resources/Notes.applescript")]),
        .executableTarget(name: "iBridgeHost", dependencies: ["IBridgeCore"]),
        .testTarget(name: "IBridgeCoreTests", dependencies: ["IBridgeCore"])
    ]
)
