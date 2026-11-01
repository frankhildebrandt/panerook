// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PaneRook",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "PaneRook", targets: ["PaneRook"])],
    targets: [
        .systemLibrary(name: "CArchive"),
        .target(name: "PaneRookTasks"),
        .target(name: "PaneRookRemote"),
        .target(name: "PaneRookCore", dependencies: ["CArchive", "PaneRookTasks"]),
        .target(name: "PaneRookPanels", dependencies: ["PaneRookCore"]),
        .target(name: "PaneRookApp", dependencies: ["PaneRookCore", "PaneRookTasks", "PaneRookRemote", "PaneRookPanels"]),
        .executableTarget(name: "PaneRook", dependencies: ["PaneRookApp"]),
        .testTarget(name: "PaneRookCoreTests", dependencies: ["PaneRookCore", "PaneRookTasks"]),
        .testTarget(name: "PaneRookTasksTests", dependencies: ["PaneRookTasks"]),
        .testTarget(name: "PaneRookRemoteTests", dependencies: ["PaneRookRemote"]),
        .testTarget(name: "PaneRookPanelsTests", dependencies: ["PaneRookPanels", "PaneRookCore"]),
        .testTarget(name: "PaneRookAppTests", dependencies: ["PaneRookApp"])
    ]
)
