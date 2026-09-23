import Foundation
@preconcurrency import Network
import Security

#if LEVELDECK_INSECURE_TRANSPORT && !DEBUG
#error("LEVELDECK_INSECURE_TRANSPORT solo se permite en builds Debug (SPEC §5.3).")
#endif

/// Cómo se protege la conexión entre el agente y el cliente.
///
/// Es lo único que cambia entre un transporte y otro: servidor, cliente y apps solo
/// reciben un valor de este tipo.
public enum TransportSecurity: Sendable {
    #if LEVELDECK_INSECURE_TRANSPORT
    /// TCP + WebSocket sin cifrar. Solo existe en builds Debug de `LevelDeckKit`, para
    /// inspeccionar el protocolo en tests; las apps no lo usan (SPEC §5.3).
    case insecurePlaintext
    #endif

    /// TLS 1.2 con pre-shared key (SPEC §5.3, §7). El servidor pasa una clave por dispositivo
    /// emparejado (más la pendiente durante el emparejamiento); el cliente, solo la suya. Una
    /// conexión cuya identidad o clave no está en el conjunto no pasa el handshake.
    case tlsPSK(PresharedKeySet)
}

extension TransportSecurity {
    /// `true` si el WebSocket va sobre TLS (`wss://`).
    var usesTLS: Bool {
        switch self {
        #if LEVELDECK_INSECURE_TRANSPORT
        case .insecurePlaintext:
            return false
        #endif
        case .tlsPSK:
            return true
        }
    }

    func makeParameters() -> NWParameters {
        switch self {
        #if LEVELDECK_INSECURE_TRANSPORT
        case .insecurePlaintext:
            return .levelDeck(tls: nil)
        #endif
        case let .tlsPSK(keys):
            return .levelDeck(tls: .presharedKeys(keys))
        }
    }
}

extension NWProtocolTLS.Options {
    /// `TLS_PSK_WITH_AES_128_GCM_SHA256` (RFC 5487), el ciphersuite PSK que Network.framework
    /// negocia. Es de TLS 1.2: Network.framework no ofrece PSK externas en TLS 1.3 (ahí las
    /// PSK son solo de reanudación), así que la versión se fija en 1.2 (SPEC §5.3).
    static let pskCiphersuite: UInt16 = 0x00A8

    /// TLS-PSK con las claves dadas. En el servidor, la identidad que manda el cliente en el
    /// handshake elige la clave; una identidad desconocida o una clave distinta lo abortan.
    static func presharedKeys(_ keys: PresharedKeySet) -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()
        let security = options.securityProtocolOptions
        for identity in keys.identities {
            guard let key = keys[identity] else { continue }
            sec_protocol_options_add_pre_shared_key(
                security, dispatchData(key.data), dispatchData(Data(identity.utf8))
            )
        }
        if let suite = tls_ciphersuite_t(rawValue: pskCiphersuite) {
            sec_protocol_options_append_tls_ciphersuite(security, suite)
        }
        sec_protocol_options_set_min_tls_protocol_version(security, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(security, .TLSv12)
        return options
    }

    private static func dispatchData(_ data: Data) -> __DispatchData {
        data.withUnsafeBytes { DispatchData(bytes: $0) } as __DispatchData
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
    /// Clave del registro TXT con el `agentId` de la Mac, para que el iPhone sepa qué clave
    /// usar sin depender del nombre (que puede cambiar o llevar sufijo).
    public static let txtAgentIDKey = "id"
}
