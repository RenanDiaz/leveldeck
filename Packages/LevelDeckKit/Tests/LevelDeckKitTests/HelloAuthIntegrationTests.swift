import Foundation
@preconcurrency import Network
import Testing
@testable import LevelDeckKit

/// `hello` challenge-response (Phase 5, SPEC §8) over loopback with `PairingManager`: the
/// `deviceId` is no longer just a claim. A paired device claiming to be another one is
/// rejected, and so it also can't survive its own live revocation.
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

    /// The iPhone passes the TLS handshake with its own key, but claims the iPad's `deviceId`
    /// and signs the `nonce` with the only thing it has, its own key. The agent rejects it and the
    /// iPad stays connected.
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

    /// Before the challenge, a revoked iPhone could stay connected by claiming to be the
    /// iPad. Now it can only connect as itself, so revoking it disconnects it.
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

    /// A valid proof from a previous session doesn't work in another: the `nonce` changes.
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

    /// A client that passes TLS but never answers the `challenge` doesn't hold a session.
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
