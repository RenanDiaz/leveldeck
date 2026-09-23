@preconcurrency import Network

/// Problema de red, tipado para que cada app muestre su propio mensaje localizado.
///
/// `LevelDeckKit` no genera textos de interfaz: el `localizedDescription` de `NWError`
/// mezcla una frase localizada con el detalle técnico en inglés. `detail` queda solo para
/// diagnóstico (logs, builds Debug).
public struct NetworkIssue: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// Sin permiso de red local (iOS) o política del sistema.
        case localNetworkDenied
        /// La conexión se cayó (abortada, reiniciada, timeout). En iOS pasa al suspender la app.
        case connectionLost
        /// El otro lado rechazó la conexión (p. ej. el agente no está corriendo).
        case refused
        /// No hay ruta hacia el otro lado.
        case unreachable
        /// No se pudo obtener la dirección del servicio Bonjour.
        case unresolved
        case other
    }

    public let kind: Kind
    /// Descripción técnica, sin localizar.
    public let detail: String

    public init(_ kind: Kind, detail: String) {
        self.kind = kind
        self.detail = detail
    }

    /// `kDNSServiceErr_PolicyDenied`: el sistema negó el acceso a la red local.
    private static let dnsPolicyDenied: Int32 = -65570

    public init(_ error: NWError) {
        detail = error.debugDescription
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
        default:
            kind = .other
        }
    }
}
