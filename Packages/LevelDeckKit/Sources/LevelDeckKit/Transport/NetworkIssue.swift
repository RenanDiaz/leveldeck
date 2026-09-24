@preconcurrency import Network

/// Network problem, typed so each app shows its own localized message.
///
/// `LevelDeckKit` doesn't produce UI text: `NWError`'s `localizedDescription` mixes a
/// localized sentence with technical detail in English. `detail` is only for
/// diagnostics (logs, Debug builds).
public struct NetworkIssue: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// No local network permission (iOS) or a system policy.
        case localNetworkDenied
        /// The connection dropped (aborted, reset, timeout). On iOS this happens when the app is suspended.
        case connectionLost
        /// The other side refused the connection (e.g. the agent isn't running).
        case refused
        /// There's no route to the other side.
        case unreachable
        /// Couldn't obtain the Bonjour service's address.
        case unresolved
        /// The TLS handshake failed: the Mac doesn't recognize this device's identity or key
        /// (it isn't paired or was revoked).
        case handshakeFailed
        /// The connection opened but the agent didn't complete `challenge` → `state` in time
        /// (e.g. it speaks another protocol version or hung).
        case noResponse
        case other
    }

    public let kind: Kind
    /// Technical description, not localized.
    public let detail: String

    public init(_ kind: Kind, detail: String) {
        self.kind = kind
        self.detail = detail
    }

    /// `kDNSServiceErr_PolicyDenied`: the system denied local network access.
    private static let dnsPolicyDenied: Int32 = -65570

    /// - Parameter path: the connection's path at the time of failure. If the system reports
    ///   local network denied, it takes precedence over the error code: when the permission is
    ///   removed with the connection open, iOS aborts it with the same `ECONNABORTED` as on suspend.
    public init(_ error: NWError, path: NWPath? = nil) {
        detail = error.debugDescription
        if path?.unsatisfiedReason == .localNetworkDenied {
            kind = .localNetworkDenied
            return
        }
        switch error {
        case let .posix(code):
            switch code {
            case .ECONNABORTED, .ECONNRESET, .EPIPE, .ETIMEDOUT, .ENOTCONN:
                kind = .connectionLost
            case .ECONNREFUSED:
                kind = .refused
            case .ENETUNREACH, .EHOSTUNREACH, .ENETDOWN, .EHOSTDOWN:
                kind = .unreachable
            default:
                kind = .other
            }
        case let .dns(code):
            kind = Int32(code) == Self.dnsPolicyDenied ? .localNetworkDenied : .unreachable
        case .tls:
            kind = .handshakeFailed
        default:
            kind = .other
        }
    }
}
