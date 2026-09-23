import LevelDeckKit

/// Transporte del servicio de red. Es el único lugar de la app que lo elige (SPEC §5.3).
enum AgentTransport {
    /// TLS-PSK. El agente arranca sin claves; `PairingManager` carga las de los dispositivos
    /// emparejados desde el Keychain y las aplica al servidor (SPEC §7).
    static let initialSecurity: TransportSecurity = .tlsPSK(PresharedKeySet())
}
