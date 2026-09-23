import LevelDeckKit

#if LEVELDECK_INSECURE_TRANSPORT && !DEBUG
#error("LEVELDECK_INSECURE_TRANSPORT solo se permite en builds Debug (SPEC §5.3).")
#endif

/// Transporte hacia el agente. Es el único lugar de la app que lo elige.
enum AppTransport {
    /// Fase 2: en claro, solo en Debug. En Release no hay transporte hasta la Fase 3 (TLS-PSK).
    static var security: TransportSecurity? {
        #if LEVELDECK_INSECURE_TRANSPORT
        return .insecurePlaintext
        #else
        return nil
        #endif
    }
}
