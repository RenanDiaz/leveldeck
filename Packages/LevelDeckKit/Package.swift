// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LevelDeckKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "LevelDeckKit", targets: ["LevelDeckKit"]),
    ],
    targets: [
        .target(name: "LevelDeckKit"),
        .testTarget(name: "LevelDeckKitTests", dependencies: ["LevelDeckKit"]),
    ]
)
