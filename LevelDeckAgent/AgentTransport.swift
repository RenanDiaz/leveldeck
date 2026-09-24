import LevelDeckKit

/// Network service transport. This is the only place in the app that chooses it (SPEC §5.3).
enum AgentTransport {
    /// TLS-PSK. The agent starts with no keys; `PairingManager` loads the paired devices' keys
    /// from the Keychain and applies them to the server (SPEC §7).
    static let initialSecurity: TransportSecurity = .tlsPSK(PresharedKeySet())
}
