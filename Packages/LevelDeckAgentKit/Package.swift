// swift-tools-version: 6.0
import PackageDescription

// Solo macOS: lógica de audio del agente (SPEC §5.2).
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
        // Lógica de estado, sin CoreAudio. Se prueba con un mock de `AudioControlling`.
        .target(name: "AgentAudio", dependencies: ["LevelDeckKit"]),
        // Implementación real. Se verifica a mano contra el hardware (SPEC §11).
        .target(name: "AgentCoreAudio", dependencies: ["AgentAudio", "LevelDeckKit"]),
        .testTarget(name: "AgentAudioTests", dependencies: ["AgentAudio", "LevelDeckKit"]),
    ]
)
