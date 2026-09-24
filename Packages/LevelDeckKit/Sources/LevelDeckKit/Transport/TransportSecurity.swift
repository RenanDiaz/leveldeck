import Foundation
@preconcurrency import Network
import Security

#if LEVELDECK_INSECURE_TRANSPORT && !DEBUG
#error("LEVELDECK_INSECURE_TRANSPORT solo se permite en builds Debug (SPEC §5.3).")
#endif

/// How the connection between the agent and the client is protected.
///
/// It's the only thing that differs between one transport and another: server, client and
/// apps just receive a value of this type.
public enum TransportSecurity: Sendable {
    #if LEVELDECK_INSECURE_TRANSPORT
    /// Unencrypted TCP + WebSocket. Only exists in Debug builds of `LevelDeckKit`, to
    /// inspect the protocol in tests; the apps don't use it (SPEC §5.3).
    case insecurePlaintext
    #endif

    /// TLS 1.2 with a pre-shared key (SPEC §5.3, §7). The server passes one key per paired
    /// device (plus the pending one during pairing); the client, only its own. A connection
    /// whose identity or key isn't in the set fails the handshake.
    case tlsPSK(PresharedKeySet)
}

extension TransportSecurity {
    /// `true` if the WebSocket runs over TLS (`wss://`).
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
    /// `TLS_PSK_WITH_AES_128_GCM_SHA256` (RFC 5487), the PSK ciphersuite Network.framework
    /// negotiates. It's a TLS 1.2 suite: Network.framework doesn't offer external PSKs in TLS 1.3
    /// (there PSKs are resumption-only), so the version is pinned to 1.2 (SPEC §5.3).
    static let pskCiphersuite: UInt16 = 0x00A8

    /// TLS-PSK with the given keys. On the server, the identity the client sends in the
    /// handshake picks the key; an unknown identity or a different key aborts it.
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
        // No session resumption or tickets: every connection does the full PSK handshake.
        // With resumption, a client in the same process that already had a valid session with that
        // host:port resumes it without proving the key again (caught by the loopback rejection
        // tests), and a revoked device could keep getting in while its ticket is alive.
        // Security must not depend on the port changing.
        sec_protocol_options_set_tls_resumption_enabled(security, false)
        sec_protocol_options_set_tls_tickets_enabled(security, false)
        return options
    }

    private static func dispatchData(_ data: Data) -> __DispatchData {
        data.withUnsafeBytes { DispatchData(bytes: $0) } as __DispatchData
    }
}

extension NWParameters {
    /// TCP (+ TLS when present) + WebSocket, which provides message framing (SPEC §5.3).
    static func levelDeck(tls: NWProtocolTLS.Options?) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        // Small, interactive messages: no Nagle, each frame goes out as soon as it's sent.
        tcp.noDelay = true
        // Keepalive: if the other side disappears without closing (the Mac went to sleep, Wi-Fi
        // was turned off), the connection is declared dead in ~11 s instead of minutes. Without
        // this, the iPhone doesn't start reconnecting and the Mac lists ghost clients (SPEC §5.3).
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        tcp.keepaliveInterval = 2
        tcp.keepaliveCount = 3
        let parameters = NWParameters(tls: tls, tcp: tcp)
        let webSocket = NWProtocolWebSocket.Options()
        webSocket.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        return parameters
    }
}

/// Constants for the service on the local network.
public enum LevelDeckService {
    /// Bonjour service type. Must match the iOS client's `NSBonjourServices`.
    public static let bonjourType = "_leveldeck._tcp"
    /// TXT record key holding the Mac's `agentId`, so the iPhone knows which key to use
    /// without relying on the name (which can change or get a suffix).
    public static let txtAgentIDKey = "id"
}
