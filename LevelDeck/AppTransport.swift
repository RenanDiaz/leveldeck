import LevelDeckKit

/// Transport to the agent. This is the only place in the app that chooses it (SPEC §5.3).
enum AppTransport {
    /// TLS-PSK with the key this Mac gave this iPhone when pairing (SPEC §7).
    static func security(for agent: PairedAgent) -> TransportSecurity {
        agent.security
    }
}
