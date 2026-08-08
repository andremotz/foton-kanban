// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "FotonKanbanCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FotonKanbanCore", targets: ["FotonKanbanCore"])
    ],
    targets: [
        .target(name: "FotonKanbanCore"),
        .testTarget(name: "FotonKanbanCoreTests", dependencies: ["FotonKanbanCore"]),
    ]
)
