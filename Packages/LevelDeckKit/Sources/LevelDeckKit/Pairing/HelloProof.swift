import CryptoKit
import Foundation
import Security

/// Challenge-response for `hello` (SPEC §5.3, §8).
///
/// Network.framework does not expose the PSK identity the connection negotiated, so the
/// `deviceId` in `hello` would be an unverified claim: a paired device could say it is
/// another one and survive its own live revocation. To prevent this, the agent sends a
/// random `nonce` when the session opens and the client answers in `hello` with
///
///     proof = HMAC-SHA256(key, "leveldeck-hello-v3\0" ‖ nonce ‖ deviceId)
///
/// using the key of that `deviceId`. Only whoever holds the key of the claimed device can
/// compute it, and the fresh per-connection `nonce` prevents reusing an old proof.
public enum HelloProof {
    /// Length of the `nonce`, in bytes.
    public static let nonceByteCount = 32

    /// Separates this use of the key from any other.
    private static let label = Data("leveldeck-hello-v3".utf8) + [0]

    /// Fresh `nonce` from `SecRandomCopyBytes`; if that fails (it shouldn't), from Swift's generator.
    public static func makeNonce() -> Data {
        var bytes = [UInt8](repeating: 0, count: nonceByteCount)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            var generator = SystemRandomNumberGenerator()
            for index in bytes.indices {
                bytes[index] = UInt8.random(in: .min ... .max, using: &generator)
            }
        }
        return Data(bytes)
    }

    public static func sign(nonce: Data, deviceId: String, key: PresharedKey) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: message(nonce: nonce, deviceId: deviceId), using: symmetric(key)))
    }

    /// Constant-time comparison.
    public static func verify(_ proof: Data, nonce: Data, deviceId: String, key: PresharedKey) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(
            proof, authenticating: message(nonce: nonce, deviceId: deviceId), using: symmetric(key)
        )
    }

    /// The `nonce` has a fixed length and the `deviceId` goes last, so there is no ambiguity.
    private static func message(nonce: Data, deviceId: String) -> Data {
        label + nonce + Data(deviceId.utf8)
    }

    private static func symmetric(_ key: PresharedKey) -> SymmetricKey {
        SymmetricKey(data: key.data)
    }
}
