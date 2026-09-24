import Foundation
import Security

/// Pairing key: 32 random bytes that an iPhone and the Mac share out of band
/// (the QR) and use as the PSK in the TLS handshake (SPEC §7). It never travels over the network.
public struct PresharedKey: Hashable, Sendable {
    public static let byteCount = 32

    public let data: Data

    /// `nil` if `data` is not exactly 32 bytes.
    public init?(_ data: Data) {
        guard data.count == Self.byteCount else { return nil }
        self.data = data
    }

    /// New key from `SecRandomCopyBytes`. If the system generator fails (it shouldn't),
    /// falls back to Swift's cryptographic generator.
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
    /// In JSON (the QR and the Keychain) it travels as base64url.
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

/// Keys an endpoint accepts in the handshake, by identity (SPEC §5.3).
///
/// The server passes one entry per paired device (plus the pending one during
/// pairing); the client passes only its own. The identity is the `deviceId` the Mac
/// assigned when pairing.
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
    /// URL-safe Base64 without padding (RFC 4648 §5).
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
