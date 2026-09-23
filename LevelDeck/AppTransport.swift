import LevelDeckKit

/// Transporte hacia el agente. Es el único lugar de la app que lo elige (SPEC §5.3).
enum AppTransport {
    /// TLS-PSK con la clave que esta Mac le dio a este iPhone al emparejar (SPEC §7).
    static func security(for agent: PairedAgent) -> TransportSecurity {
        agent.security
    }
}
