import AgentAudio
import Foundation
import LevelDeckKit

/// The agent's network service (SPEC §5.3, §7): publishes the audio state, applies client
/// commands and manages pairing. Audio changes, wherever they come
/// from, arrive through `AudioModel.onChange`.
@MainActor
final class RemoteService {
    let server: LevelDeckServer
    let pairing: PairingManager
    private let bridge: AudioServerBridge

    init(audio: AudioModel, store: any PairedDeviceStore) {
        bridge = AudioServerBridge(audio: audio)
        // If the Keychain fails, the agent still starts with an ID for this session; the error
        // shows up in the menu via `PairingManager.storeError` when devices are loaded.
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

    /// Name under which the iPhone will see this Mac in the QR code: the one advertised over Bonjour,
    /// or the computer's name while the service is starting.
    var displayName: String {
        server.advertisedName ?? Host.current().localizedName ?? "Mac"
    }
}
