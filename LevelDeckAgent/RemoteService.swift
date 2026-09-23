import AgentAudio
import Foundation
import LevelDeckKit

/// Servicio de red del agente (SPEC §5.3, §7): publica el estado de audio, aplica los comandos
/// de los clientes y administra el emparejamiento. Los cambios de audio, vengan de donde
/// vengan, llegan por `AudioModel.onChange`.
@MainActor
final class RemoteService {
    let server: LevelDeckServer
    let pairing: PairingManager
    private let bridge: AudioServerBridge

    init(audio: AudioModel, store: any PairedDeviceStore) {
        bridge = AudioServerBridge(audio: audio)
        // Si el Keychain falla, el agente igual arranca con un ID de esta sesión; el error
        // aparece en el menú vía `PairingManager.storeError` al cargar los dispositivos.
        let agentID = (try? PairingManager.loadOrCreateAgentID(in: store)) ?? UUID().uuidString
        server = LevelDeckServer(security: AgentTransport.initialSecurity, agentID: agentID)
        server.delegate = bridge
        pairing = PairingManager(store: store, server: server, agentID: agentID)
        audio.onChange = { [weak server] in
            server?.stateDidChange()
        }
    }

    func start() {
        server.start()
    }

    /// Nombre con el que el iPhone verá a esta Mac en el QR: el anunciado por Bonjour, o el
    /// del equipo mientras el servicio arranca.
    var displayName: String {
        server.advertisedName ?? Host.current().localizedName ?? "Mac"
    }
}
