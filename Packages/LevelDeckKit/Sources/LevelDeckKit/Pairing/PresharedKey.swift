import Foundation
import Security

/// Clave de emparejamiento: 32 bytes aleatorios que un iPhone y la Mac comparten fuera de
/// banda (el QR) y usan como PSK en el handshake TLS (SPEC §7). Nunca viaja por la red.
public struct PresharedKey: Hashable, Sendable {
    public static let byteCount = 32

    public let data: Data

    /// `nil` si `data` no tiene exactamente 32 bytes.
    public init?(_ data: Data) {
        guard data.count == Self.byteCount else { return nil }
        self.data = data
    }

    /// Clave nueva con `SecRandomCopyBytes`. Si el generador del sistema falla (no debería),
    /// cae al generador criptográfico de Swift.
    public static func random() -> PresharedKey {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            var generator = SystemRandomNumberGenerator()
            for index in bytes.indices {
                bytes[index] = UInt8.random(in: .min ... .max, using: &generator)
            }
        }
        return PresharedKey(bytes: bytes)
    }

    private init(bytes: [UInt8]) {
        data = Data(bytes)
    }
}

extension PresharedKey: Codable {
    /// En JSON (el QR y el Keychain) viaja como base64url.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let data = Data(base64URLEncoded: text), let key = PresharedKey(data) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "La clave debe ser base64url de 32 bytes."
            )
        }
        self = key
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(data.base64URLEncodedString())
    }
}

/// Claves que un extremo acepta en el handshake, por identidad (SPEC §5.3).
///
/// El servidor pasa una entrada por dispositivo emparejado (más la pendiente durante el
/// emparejamiento); el cliente pasa solo la suya. La identidad es el `deviceId` que la Mac
/// asignó al emparejar.
public struct PresharedKeySet: Equatable, Sendable {
    public private(set) var keys: [String: PresharedKey]

    public init(_ keys: [String: PresharedKey] = [:]) {
        self.keys = keys
    }

    public static func single(identity: String, key: PresharedKey) -> PresharedKeySet {
        PresharedKeySet([identity: key])
    }

    public var isEmpty: Bool { keys.isEmpty }
    public var count: Int { keys.count }
    public var identities: [String] { keys.keys.sorted() }

    public subscript(identity: String) -> PresharedKey? {
        get { keys[identity] }
        set { keys[identity] = newValue }
    }
}

extension Data {
    /// Base64 URL-safe sin relleno (RFC 4648 §5).
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded text: String) {
        var base64 = text
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 {
            base64.append("=")
        }
        self.init(base64Encoded: base64)
    }
}
