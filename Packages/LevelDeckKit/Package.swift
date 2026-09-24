// swift-tools-version: 6.0
import PackageDescription

/// Phase 2 cleartext transport: exists only in Debug builds (SPEC §5.3).
/// In Release the flag is not defined and the corresponding code is not compiled.
let insecureTransport: [SwiftSetting] = [
    .define("LEVELDECK_INSECURE_TRANSPORT", .when(configuration: .debug)),
]

let package = Package(
    name: "LevelDeckKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "LevelDeckKit", targets: ["LevelDeckKit"]),
    ],
    targets: [
        .target(name: "LevelDeckKit", swiftSettings: insecureTransport),
        .testTarget(
            name: "LevelDeckKitTests",
            dependencies: ["LevelDeckKit"],
            swiftSettings: insecureTransport
        ),
    ]
)
