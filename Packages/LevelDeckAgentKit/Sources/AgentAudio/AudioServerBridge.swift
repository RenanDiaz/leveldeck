import LevelDeckKit

/// Connects the `AudioModel` to the network server (SPEC §5.2–5.3): builds the `state` and
/// applies client commands with the same rules as the menu.
@MainActor
public final class AudioServerBridge: LevelDeckServerDelegate {
    private let audio: AudioModel

    public init(audio: AudioModel) {
        self.audio = audio
    }

    public func currentState() -> StateSnapshot {
        StateSnapshot(
            output: audio.channel(.output).map { ChannelState($0) },
            input: audio.channel(.input).map { ChannelState($0) },
            devices: DeviceList(output: audio.devices(.output), input: audio.devices(.input))
        )
    }

    public func handle(_ command: ClientMessage) -> AgentError? {
        switch command {
        case .hello:
            return nil
        case let .setVolume(scope, value):
            audio.setVolume(value, scope: scope)
        case let .setMute(scope, muted):
            audio.setMute(muted, scope: scope)
        case let .setDefaultDevice(scope, deviceId):
            audio.setDefaultDevice(deviceId, scope: scope)
        }
        // `AudioModel` sets `lastError` on every path: `nil` if the write was applied.
        return audio.lastError.map(Self.agentError)
    }

    static func agentError(_ error: AudioControlError) -> AgentError {
        switch error {
        case let .noDevice(scope):
            AgentError(.deviceNotFound, "No hay dispositivo de \(scope.displayName) por defecto.")
        case let .deviceNotFound(scope):
            AgentError(.deviceNotFound, "El dispositivo de \(scope.displayName) pedido no está disponible.")
        case let .notSettable(scope):
            AgentError(.notSettable, "El dispositivo de \(scope.displayName) no permite ese cambio.")
        case .invalidValue:
            AgentError(.invalidValue, "El volumen debe estar en 0.0–1.0.")
        case let .coreAudio(status):
            AgentError(.notSettable, "CoreAudio rechazó el cambio (OSStatus \(status)).")
        }
    }
}

extension ChannelState {
    /// Protocol projection of the channel the agent sees.
    public init(_ channel: AudioChannel) {
        self.init(
            deviceId: channel.deviceId, deviceName: channel.deviceName,
            volume: channel.volume, muted: channel.muted,
            volumeSettable: channel.volumeSettable, muteSettable: channel.muteSettable
        )
    }
}

private extension Scope {
    var displayName: String {
        switch self {
        case .output: "salida"
        case .input: "entrada"
        }
    }
}
