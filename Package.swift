// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PaneRook",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "PaneRook", targets: ["PaneRook"])],
    targets: [
        .systemLibrary(name: "CArchive"),
        .target(name: "PaneRookCore", dependencies: ["CArchive"]),
        .executableTarget(name: "PaneRook", dependencies: ["PaneRookCore"]),
        .testTarget(name: "PaneRookCoreTests", dependencies: ["PaneRookCore"])
    ]
)
