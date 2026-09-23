import LevelDeckKit

/// Conecta el `AudioModel` con el servidor de red (SPEC §5.2–5.3): arma el `state` y aplica
/// los comandos de los clientes con las mismas reglas que el menú.
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
            // El selector de dispositivo llega en la Fase 4; hasta entonces las listas van vacías.
            devices: DeviceList(output: [], input: [])
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
        case .setDefaultDevice:
            return AgentError(.notSettable, "Cambiar el dispositivo por defecto llega en la Fase 4.")
        }
        // `AudioModel` fija `lastError` en todos los caminos: `nil` si la escritura se aplicó.
        return audio.lastError.map(Self.agentError)
    }

    static func agentError(_ error: AudioControlError) -> AgentError {
        switch error {
        case let .noDevice(scope):
            AgentError(.deviceNotFound, "No hay dispositivo de \(scope.displayName) por defecto.")
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
    /// Proyección al protocolo del canal que ve el agente.
    public init(_ channel: AudioChannel) {
        self.init(
            deviceId: channel.deviceId, deviceName: channel.deviceName,
            volume: channel.volume, muted: channel.muted,
            settable: channel.volumeSettable, muteSettable: channel.muteSettable
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
