@preconcurrency import Network

#if LEVELDECK_INSECURE_TRANSPORT && !DEBUG
#error("LEVELDECK_INSECURE_TRANSPORT solo se permite en builds Debug (SPEC §5.3).")
#endif

/// Cómo se protege la conexión entre el agente y el cliente.
///
/// Es lo único que cambia entre un transporte y otro: servidor, cliente y apps solo
/// reciben un valor de este tipo. La Fase 3 agrega `tlsPSK` y el resto no cambia.
public enum TransportSecurity: Sendable {
    #if LEVELDECK_INSECURE_TRANSPORT
    /// TCP + WebSocket sin cifrar. Solo existe en builds Debug; en Release este caso no se
    /// compila y ninguna app puede construir un transporte en claro (SPEC §5.3, Fase 2).
    case insecurePlaintext
    #endif
}

extension TransportSecurity {
    func makeParameters() -> NWParameters {
        switch self {
        #if LEVELDECK_INSECURE_TRANSPORT
        case .insecurePlaintext:
            return .levelDeck(tls: nil)
        #endif
        }
    }
}

extension NWParameters {
    /// TCP (+ TLS cuando lo haya) + WebSocket, que da el framing de mensajes (SPEC §5.3).
    static func levelDeck(tls: NWProtocolTLS.Options?) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        // Mensajes chicos e interactivos: sin Nagle, cada frame sale en cuanto se envía.
        tcp.noDelay = true
        let parameters = NWParameters(tls: tls, tcp: tcp)
        let webSocket = NWProtocolWebSocket.Options()
        webSocket.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        return parameters
    }
}

/// Constantes del servicio en la red local.
public enum LevelDeckService {
    /// Tipo de servicio Bonjour. Debe coincidir con `NSBonjourServices` del cliente iOS.
    public static let bonjourType = "_leveldeck._tcp"
}
