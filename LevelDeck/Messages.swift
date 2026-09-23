import LevelDeckKit

// Textos localizados para lo que llega de LevelDeckKit o del agente. Nunca se muestra el
// `localizedDescription` del sistema ni el `message` del agente: mezclan idiomas.

extension NetworkIssue {
    var message: String {
        switch kind {
        case .localNetworkDenied:
            String(localized: "LevelDeck doesn't have Local Network access. Allow it in Settings › Privacy & Security › Local Network.")
        case .connectionLost:
            String(localized: "The connection to the Mac was lost.")
        case .refused:
            String(localized: "The Mac rejected the connection. Make sure LevelDeck Agent is running.")
        case .unreachable:
            String(localized: "Can't reach the Mac. Check that both devices are on the same Wi-Fi network and that Local Network access is allowed.")
        case .unresolved:
            String(localized: "Couldn't find the Mac's address.")
        case .other:
            String(localized: "Couldn't connect to the Mac.")
        }
    }
}

extension AgentError {
    var localizedMessage: String {
        switch code {
        case .notSettable:
            String(localized: "The Mac didn't allow that change.")
        case .deviceNotFound:
            String(localized: "The Mac has no default device for that channel.")
        case .invalidValue:
            String(localized: "The Mac rejected an invalid value.")
        case .unsupportedVersion:
            String(localized: "This version of LevelDeck isn't compatible with the agent on the Mac. Update both.")
        }
    }
}
