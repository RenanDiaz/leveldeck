// swift-tools-version: 6.0
import PackageDescription

// macOS only: the agent's audio logic (SPEC §5.2).
let package = Package(
    name: "LevelDeckAgentKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AgentAudio", targets: ["AgentAudio"]),
        .library(name: "AgentCoreAudio", targets: ["AgentCoreAudio"]),
    ],
    dependencies: [
        .package(path: "../LevelDeckKit"),
    ],
    targets: [
        // State logic, without CoreAudio. Tested with a mock of `AudioControlling`.
        .target(name: "AgentAudio", dependencies: ["LevelDeckKit"]),
        // Real implementation. Verified by hand against the hardware (SPEC §11).
        .target(name: "AgentCoreAudio", dependencies: ["AgentAudio", "LevelDeckKit"]),
        .testTarget(name: "AgentAudioTests", dependencies: ["AgentAudio", "LevelDeckKit"]),
    ]
)
