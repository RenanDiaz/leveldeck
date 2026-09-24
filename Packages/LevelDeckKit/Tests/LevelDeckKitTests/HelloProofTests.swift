import Foundation
import Testing
@testable import LevelDeckKit

/// Challenge-response del `hello` (SPEC §8), sin red.
@Suite("HelloProof")
struct HelloProofTests {
    let key = TestKeys.key(1)
    let nonce = Data(repeating: 0x42, count: HelloProof.nonceByteCount)

    @Test func validProofVerifies() {
        let proof = HelloProof.sign(nonce: nonce, deviceId: "dev-1", key: key)
        #expect(proof.count == 32, "HMAC-SHA256")
        #expect(HelloProof.verify(proof, nonce: nonce, deviceId: "dev-1", key: key))
    }

    /// Vector fijo: cualquier cambio en la etiqueta, el orden o el algoritmo rompe la
    /// compatibilidad entre el agente y el cliente, y este test lo detecta.
    @Test func matchesKnownVector() {
        let proof = HelloProof.sign(nonce: nonce, deviceId: "dev-1", key: key)
        #expect(proof.base64URLEncodedString() == HelloProofTests.knownVector)
    }

    @Test func otherDeviceIdFails() {
        let proof = HelloProof.sign(nonce: nonce, deviceId: "dev-1", key: key)
        #expect(!HelloProof.verify(proof, nonce: nonce, deviceId: "dev-2", key: key))
    }

    @Test func otherKeyFails() {
        let proof = HelloProof.sign(nonce: nonce, deviceId: "dev-1", key: TestKeys.key(2))
        #expect(!HelloProof.verify(proof, nonce: nonce, deviceId: "dev-1", key: key))
    }

    @Test func otherNonceFails() {
        let proof = HelloProof.sign(nonce: nonce, deviceId: "dev-1", key: key)
        let fresh = Data(repeating: 0x43, count: HelloProof.nonceByteCount)
        #expect(!HelloProof.verify(proof, nonce: fresh, deviceId: "dev-1", key: key))
    }

    @Test func truncatedProofFails() {
        let proof = HelloProof.sign(nonce: nonce, deviceId: "dev-1", key: key)
        #expect(!HelloProof.verify(proof.prefix(16), nonce: nonce, deviceId: "dev-1", key: key))
        #expect(!HelloProof.verify(Data(), nonce: nonce, deviceId: "dev-1", key: key))
    }

    @Test func noncesAreRandomAndSized() {
        let first = HelloProof.makeNonce()
        let second = HelloProof.makeNonce()
        #expect(first.count == HelloProof.nonceByteCount)
        #expect(first != second)
    }

    /// HMAC-SHA256(0x01 × 32, "leveldeck-hello-v3\0" ‖ 0x42 × 32 ‖ "dev-1"), en base64url.
    static let knownVector = "0RKyAGbcABiekDbqXYy14MqAcYw9cwAsZmfdov6YuK4"
}
