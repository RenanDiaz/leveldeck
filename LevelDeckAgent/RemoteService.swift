import AgentAudio
import LevelDeckKit

/// Servicio de red del agente (SPEC §5.3): publica el estado de audio y aplica los comandos
/// de los clientes. Los cambios, vengan de donde vengan, llegan por `AudioModel.onChange`.
@MainActor
final class RemoteService {
    let server: LevelDeckServer
    private let bridge: AudioServerBridge

    init(audio: AudioModel, security: TransportSecurity) {
        bridge = AudioServerBridge(audio: audio)
        server = LevelDeckServer(security: security)
        server.delegate = bridge
        audio.onChange = { [weak server] in
            server?.stateDidChange()
        }
    }

    func start() {
        server.start()
    }
}
