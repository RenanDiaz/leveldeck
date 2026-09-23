// swift-tools-version: 6.0
import PackageDescription

/// Transporte en claro de la Fase 2: existe solo en builds Debug (SPEC §5.3).
/// En Release el flag no se define y el código correspondiente no se compila.
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
