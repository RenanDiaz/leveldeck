import Foundation
@preconcurrency import Network
import Testing
@testable import LevelDeckKit

/// Phase 3 criteria (SPEC §9) over the real network on loopback: a paired device
/// connects, an unknown key is rejected in the handshake, and a revoked one loses its
/// active connection. The server runs `PairingManager` with an in-memory `store`.
@MainActor
@Suite("TLS-PSK y emparejamiento en loopback", .serialized)
struct PairingIntegrationTests {
    let agent = FakeAgent()
    let store = InMemoryPairedDeviceStore()
    let server: LevelDeckServer
    let pairing: PairingManager

    init() async throws {
        server = LevelDeckServer(security: .tlsPSK(PresharedKeySet()), advertise: false)
        server.delegate = agent
        pairing = PairingManager(store: store, server: server, agentID: "agent-test", window: .seconds(10))
        server.start()
        let server = server
        try await waitUntil("el listener queda listo") { server.port != nil }
    }

    @Test func pairedDeviceConnects() async throws {
        defer { server.stop() }
        let code = pairing.beginPairing(agentName: "Mac de prueba")
        #expect(pairing.pending?.code == code)
        #expect(code.agentID == "agent-test")

        let (client, messages) = try await connect(with: code, name: "iPhone de Renan")
        defer { client.disconnect() }
        #expect(try await messages.next() == .state(Fixtures.snapshot))
        #expect(client.status == .connected)

        #expect(pairing.pending == nil, "El QR es de un solo uso: se consume en el primer hello")
        #expect(pairing.devices.map(\.name) == ["iPhone de Renan"])
        #expect(pairing.devices.first?.id == code.deviceID)
        #expect(pairing.lastPaired?.id == code.deviceID)
        #expect(try store.loadDevices().map(\.key) == [code.key], "La clave queda en el store de la Mac")
        let pairing = pairing
        try await waitUntil("el dispositivo figura conectado") { pairing.isConnected(code.deviceID) }
    }

    @Test func pairedDeviceReconnectsWithoutPairingAgain() async throws {
        defer { server.stop() }
        let code = try await pair(name: "iPhone")
        let (client, messages) = try await connect(with: code, name: "iPhone renombrado")
        defer { client.disconnect() }
        _ = try await messages.nextState()
        #expect(pairing.devices.map(\.name) == ["iPhone renombrado"], "El nombre se actualiza en cada hello")
        #expect(pairing.devices.count == 1)
    }

    @Test func unknownIdentityIsRejectedInHandshake() async throws {
        defer { server.stop() }
        _ = try await pair(name: "iPhone")
        let stranger = PairingCode(agentID: "agent-test", agentName: "Mac", deviceID: "intruso", key: .random())

        let (client, messages) = try await connect(with: stranger, name: "Intruso")
        defer { client.disconnect() }
        try await waitUntil("el handshake falla") { isRejected(client) }
        #expect(messages.isEmpty, "Ningún mensaje del protocolo pasa sin handshake")
        #expect(server.clients.isEmpty)
        #expect(pairing.devices.count == 1)
    }

    @Test func wrongKeyForKnownIdentityIsRejectedInHandshake() async throws {
        defer { server.stop() }
        let code = try await pair(name: "iPhone")
        var forged = code
        forged.key = .random()

        let (client, messages) = try await connect(with: forged, name: "Impostor")
        defer { client.disconnect() }
        try await waitUntil("el handshake falla") { isRejected(client) }
        #expect(messages.isEmpty)
        #expect(server.clients.isEmpty)
    }

    @Test func helloWithoutDeviceIdIsRefused() async throws {
        defer { server.stop() }
        let code = try await pair(name: "iPhone")
        let (client, messages) = try await LevelDeckKitTests.connect(
            to: server, security: .tlsPSK(.single(identity: code.deviceID, key: code.key)),
            name: "Sin identidad", deviceID: nil
        )
        try await messages.nextError(.notPaired)
        try await waitUntil("el agente cierra la conexión") {
            if case .disconnected = client.status { true } else { false }
        }
        #expect(server.clients.isEmpty)
    }

    @Test func revokedDeviceLosesActiveConnection() async throws {
        defer { server.stop() }
        let phoneCode = try await pair(name: "iPhone")
        let padCode = try await pair(name: "iPad")
        let (phone, phoneMessages) = try await connect(with: phoneCode, name: "iPhone")
        let (pad, padMessages) = try await connect(with: padCode, name: "iPad")
        defer {
            phone.disconnect()
            pad.disconnect()
        }
        _ = try await phoneMessages.nextState()
        _ = try await padMessages.nextState()
        #expect(pairing.devices.count == 2)

        pairing.revoke(padCode.deviceID)

        try await padMessages.nextError(.notPaired)
        #expect(pad.lastError?.code == .notPaired)
        try await waitUntil("el iPad queda desconectado") {
            if case .disconnected = pad.status { true } else { false }
        }
        #expect(pairing.devices.map(\.id) == [phoneCode.deviceID])
        #expect(try store.loadDevices().map(\.device.id) == [phoneCode.deviceID])

        // The iPhone stays connected and keeps receiving changes even though the listener restarted.
        #expect(phone.status == .connected)
        agent.snapshot.output?.volume = 0.33
        server.stateDidChange()
        #expect(try await phoneMessages.nextState().output?.volume == 0.33)

        // The iPad can't come back: its key was removed from the listener.
        let (padAgain, padAgainMessages) = try await connect(with: padCode, name: "iPad")
        defer { padAgain.disconnect() }
        try await waitUntil("el handshake del revocado falla") { isRejected(padAgain) }
        #expect(padAgainMessages.isEmpty)
        #expect(server.clients.map(\.deviceName) == ["iPhone"])
    }

    @Test func cancelledPairingCodeIsUseless() async throws {
        defer { server.stop() }
        let code = pairing.beginPairing(agentName: "Mac")
        pairing.cancelPairing()
        #expect(pairing.pending == nil)

        let (client, messages) = try await connect(with: code, name: "Tarde")
        defer { client.disconnect() }
        try await waitUntil("el handshake falla") { isRejected(client) }
        #expect(messages.isEmpty)
        #expect(pairing.devices.isEmpty)
    }

    @Test func activeSessionSurvivesANewPairingWindow() async throws {
        defer { server.stop() }
        let code = try await pair(name: "iPhone")
        let (client, messages) = try await connect(with: code, name: "iPhone")
        defer { client.disconnect() }
        _ = try await messages.nextState()

        // Starting a pairing restarts the listener with the pending key.
        pairing.beginPairing(agentName: "Mac")
        let server = server
        try await waitUntil("el listener vuelve a estar listo") { server.port != nil }
        agent.snapshot.input?.muted = true
        server.stateDidChange()
        #expect(try await messages.nextState().input?.muted == true)
        #expect(client.status == .connected)
    }

    // MARK: - Helpers

    /// Pairs a device end to end and disconnects it. Returns its code.
    private func pair(name: String) async throws -> PairingCode {
        let code = pairing.beginPairing(agentName: "Mac")
        let (client, messages) = try await connect(with: code, name: name)
        _ = try await messages.nextState()
        client.disconnect()
        let server = server
        try await waitUntil("el servidor olvida la sesión") { !server.clients.contains { $0.deviceId == code.deviceID } }
        return code
    }

    private func connect(with code: PairingCode, name: String) async throws -> (LevelDeckClient, MessageRecorder) {
        try await LevelDeckKitTests.connect(
            to: server, security: .tlsPSK(.single(identity: code.deviceID, key: code.key)),
            name: name, deviceID: code.deviceID
        )
    }
}

/// The QR expires on its own: its key leaves the listener and the code stops working.
@MainActor
@Suite("Vencimiento del QR", .serialized)
struct PairingExpiryTests {
    @Test func expiredCodeIsRemovedFromListener() async throws {
        let agent = FakeAgent()
        let server = LevelDeckServer(security: .tlsPSK(PresharedKeySet()), advertise: false)
        server.delegate = agent
        let pairing = PairingManager(
            store: InMemoryPairedDeviceStore(), server: server, agentID: "agent-test", window: .milliseconds(300)
        )
        server.start()
        defer { server.stop() }

        let code = pairing.beginPairing(agentName: "Mac")
        #expect(pairing.pending != nil)
        try await waitUntil("el QR vence", timeout: .seconds(3)) { pairing.pending == nil }

        let (client, messages) = try await connect(
            to: server, security: .tlsPSK(.single(identity: code.deviceID, key: code.key)),
            name: "Tarde", deviceID: code.deviceID
        )
        defer { client.disconnect() }
        try await waitUntil("el handshake falla") { isRejected(client) }
        #expect(messages.isEmpty)
        #expect(pairing.devices.isEmpty)
    }
}
