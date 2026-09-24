import Foundation
@preconcurrency import Network
import Testing
@testable import LevelDeckKit

/// Challenge-response del `hello` (Fase 5, SPEC §8) en loopback con `PairingManager`: el
/// `deviceId` ya no es una declaración. Un dispositivo emparejado que dice ser otro se
/// rechaza, y por eso tampoco puede sobrevivir a su propia revocación en caliente.
@MainActor
@Suite("Challenge-response del hello", .serialized)
struct HelloAuthIntegrationTests {
    let agent = FakeAgent()
    let store = InMemoryPairedDeviceStore()
    let server: LevelDeckServer
    let pairing: PairingManager

    init() async throws {
        server = LevelDeckServer(
            security: .tlsPSK(PresharedKeySet()), advertise: false, helloTimeout: .milliseconds(500)
        )
        server.delegate = agent
        pairing = PairingManager(store: store, server: server, agentID: "agent-test", window: .seconds(10))
        server.start()
        let server = server
        try await waitUntil("el listener queda listo") { server.port != nil }
    }

    /// El iPhone pasa el handshake TLS con su propia clave, pero declara el `deviceId` del iPad
    /// y firma el `nonce` con lo único que tiene, su clave. El agente lo rechaza y el iPad
    /// sigue conectado.
    @Test func clientClaimingAnotherDeviceIdIsRejected() async throws {
        defer { server.stop() }
        let phone = try await pair(name: "iPhone")
        let pad = try await pair(name: "iPad")
        let (padClient, padMessages) = try await connect(with: pad, name: "iPad")
        defer { padClient.disconnect() }
        _ = try await padMessages.nextState()

        let (impostor, impostorMessages) = try await connect(with: phone, name: "Impostor") { nonce in
            .hello(
                deviceName: "Impostor", deviceId: pad.deviceID,
                proof: HelloProof.sign(nonce: nonce, deviceId: pad.deviceID, key: phone.key)
            )
        }
        defer { impostor.disconnect() }
        try await impostorMessages.nextError(.notPaired)
        try await waitUntil("el agente cierra al impostor") {
            if case .disconnected = impostor.status { true } else { false }
        }
        #expect(server.clients.map(\.deviceName) == ["iPad"])
        #expect(padClient.status == .connected)
        #expect(pairing.devices.first { $0.id == pad.deviceID }?.name == "iPad", "El nombre del iPad no cambió")
    }

    /// Antes del challenge, un iPhone revocado podía seguir conectado declarándose como el
    /// iPad. Ahora solo puede conectar como sí mismo, así que revocarlo lo desconecta.
    @Test func deviceCannotSurviveItsOwnRevocation() async throws {
        defer { server.stop() }
        let phone = try await pair(name: "iPhone")
        let pad = try await pair(name: "iPad")

        let (disguised, disguisedMessages) = try await connect(with: phone, name: "iPad") { nonce in
            .hello(
                deviceName: "iPad", deviceId: pad.deviceID,
                proof: HelloProof.sign(nonce: nonce, deviceId: pad.deviceID, key: phone.key)
            )
        }
        defer { disguised.disconnect() }
        try await disguisedMessages.nextError(.notPaired)

        let (phoneClient, phoneMessages) = try await connect(with: phone, name: "iPhone")
        defer { phoneClient.disconnect() }
        _ = try await phoneMessages.nextState()

        pairing.revoke(phone.deviceID)
        try await phoneMessages.nextError(.notPaired)
        try await waitUntil("no queda ninguna sesión del iPhone") { server.clients.isEmpty }
    }

    @Test func helloWithoutProofIsRejected() async throws {
        defer { server.stop() }
        let phone = try await pair(name: "iPhone")
        let (client, messages) = try await connect(with: phone, name: "Sin prueba") { _ in
            .hello(deviceName: "Sin prueba", deviceId: phone.deviceID, proof: nil)
        }
        defer { client.disconnect() }
        try await messages.nextError(.notPaired)
        #expect(server.clients.isEmpty)
    }

    /// Una prueba válida de una sesión anterior no sirve en otra: el `nonce` cambia.
    @Test func replayedProofIsRejected() async throws {
        defer { server.stop() }
        let phone = try await pair(name: "iPhone")
        var captured: ClientMessage?
        let (first, firstMessages) = try await connect(with: phone, name: "iPhone") { nonce in
            let hello = ClientMessage.hello(
                deviceName: "iPhone", deviceId: phone.deviceID,
                proof: HelloProof.sign(nonce: nonce, deviceId: phone.deviceID, key: phone.key)
            )
            captured = hello
            return hello
        }
        _ = try await firstMessages.nextState()
        first.disconnect()
        let replay = try #require(captured)

        let (second, secondMessages) = try await connect(with: phone, name: "iPhone") { _ in replay }
        defer { second.disconnect() }
        try await secondMessages.nextError(.notPaired)
    }

    /// Un cliente que pasa el TLS pero nunca responde el `challenge` no ocupa una sesión.
    @Test func silentClientIsClosedByTimeout() async throws {
        defer { server.stop() }
        let phone = try await pair(name: "iPhone")
        let (client, messages) = try await connect(with: phone, name: "Mudo") { _ in nil }
        defer { client.disconnect() }
        try await waitUntil("el agente cierra la sesión muda", timeout: .seconds(3)) {
            if case .disconnected = client.status { true } else { false }
        }
        #expect(messages.isEmpty)
        #expect(server.connectionEvents.contains("helloTimeout"))
    }

    // MARK: - Helpers

    private func pair(name: String) async throws -> PairingCode {
        let code = pairing.beginPairing(agentName: "Mac")
        let (client, messages) = try await connect(with: code, name: name)
        _ = try await messages.nextState()
        client.disconnect()
        let server = server
        try await waitUntil("el servidor olvida la sesión") { !server.clients.contains { $0.deviceId == code.deviceID } }
        return code
    }

    private func connect(
        with code: PairingCode, name: String, hello: ((Data) -> ClientMessage?)? = nil
    ) async throws -> (LevelDeckClient, MessageRecorder) {
        try await LevelDeckKitTests.connect(
            to: server, security: .tlsPSK(.single(identity: code.deviceID, key: code.key)),
            name: name, deviceID: code.deviceID, hello: hello
        )
    }
}
