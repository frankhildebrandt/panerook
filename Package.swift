// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PaneRook",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "PaneRook", targets: ["PaneRook"])],
    targets: [
        .target(name: "PaneRookCore"),
        .executableTarget(name: "PaneRook", dependencies: ["PaneRookCore"]),
        .testTarget(name: "PaneRookCoreTests", dependencies: ["PaneRookCore"])
    ]
)
