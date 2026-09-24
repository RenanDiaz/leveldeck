import CryptoKit
import Foundation
import Security

/// Challenge-response del `hello` (SPEC §5.3, §8).
///
/// Network.framework no expone la identidad PSK que negoció la conexión, así que el `deviceId`
/// del `hello` sería una declaración sin verificar: un dispositivo emparejado podría decir que
/// es otro y sobrevivir a su propia revocación en caliente. Para evitarlo, el agente manda un
/// `nonce` aleatorio al abrirse la sesión y el cliente responde en el `hello` con
///
///     proof = HMAC-SHA256(key, "leveldeck-hello-v3\0" ‖ nonce ‖ deviceId)
///
/// usando la clave de ese `deviceId`. Solo quien tiene la clave del dispositivo declarado puede
/// calcularla, y el `nonce` nuevo por conexión impide reusar una prueba vieja.
public enum HelloProof {
    /// Largo del `nonce`, en bytes.
    public static let nonceByteCount = 32

    /// Separa este uso de la clave de cualquier otro.
    private static let label = Data("leveldeck-hello-v3".utf8) + [0]

    /// `nonce` nuevo con `SecRandomCopyBytes`; si falla (no debería), con el generador de Swift.
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

    /// Comparación en tiempo constante.
    public static func verify(_ proof: Data, nonce: Data, deviceId: String, key: PresharedKey) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(
            proof, authenticating: message(nonce: nonce, deviceId: deviceId), using: symmetric(key)
        )
    }

    /// El `nonce` tiene largo fijo y el `deviceId` va al final, así que no hay ambigüedad.
    private static func message(nonce: Data, deviceId: String) -> Data {
        label + nonce + Data(deviceId.utf8)
    }

    private static func symmetric(_ key: PresharedKey) -> SymmetricKey {
        SymmetricKey(data: key.data)
    }
}
