import Foundation
@preconcurrency import Network
import Testing
@testable import LevelDeckKit

/// Ciclo completo sobre la red real en loopback (SPEC §11): servidor y cliente de
/// LevelDeckKit, `hello` → `state`, `setVolume` → `state`, errores y varios clientes.
///
/// Usa TLS-PSK con claves fijas de prueba (Fase 3). Sin Bonjour: el cliente conecta directo
/// al puerto dinámico del listener. El servidor no tiene `authorizer`: acepta cualquier `hello`
/// que haya pasado el handshake; el emparejamiento se prueba en `PairingIntegrationTests`.
@MainActor
@Suite("Integración en loopback", .serialized)
struct LoopbackIntegrationTests {
    let agent = FakeAgent()
    let server: LevelDeckServer

    init() async throws {
        // El cliente conecta a 127.0.0.1; el listener no se restringe a la interfaz de loopback.
        server = LevelDeckServer(security: .tlsPSK(TestKeys.serverSet), advertise: false)
        server.delegate = agent
        server.start()
        let server = server
        try await waitUntil("el listener queda listo") { server.port != nil }
    }

    @Test func helloIsAnsweredWithState() async throws {
        defer { server.stop() }
        let (client, messages) = try await connect(name: "iPhone de prueba")
        defer { client.disconnect() }

        #expect(try await messages.next() == .state(Fixtures.snapshot))
        #expect(client.status == .connected)
        let server = server
        try await waitUntil("el servidor registra al cliente") {
            server.clients.map(\.deviceName) == ["iPhone de prueba"]
        }
        #expect(server.clients.first?.deviceId == TestKeys.phone.identity)
    }

    @Test("setVolume produce un state con el valor nuevo", arguments: Scope.allCases)
    func setVolumeBroadcastsState(scope: Scope) async throws {
        defer { server.stop() }
        let (client, messages) = try await connect()
        defer { client.disconnect() }
        _ = try await messages.next()

        #expect(client.send(.setVolume(scope: scope, value: 0.25)))
        let state = try await messages.nextState()
        #expect(state[scope]?.volume == 0.25)
        #expect(agent.commands == [.setVolume(scope: scope, value: 0.25)])
    }

    @Test func setMuteBroadcastsState() async throws {
        defer { server.stop() }
        let (client, messages) = try await connect()
        defer { client.disconnect() }
        _ = try await messages.next()

        client.send(.setMute(scope: .input, muted: true))
        let state = try await messages.nextState()
        #expect(state.input?.muted == true)
    }

    /// Una ráfaga de comandos se agrupa (máx. 30/s), pero el último valor siempre llega.
    @Test func burstEndsOnFinalValue() async throws {
        defer { server.stop() }
        let (client, messages) = try await connect()
        defer { client.disconnect() }
        _ = try await messages.next()

        for step in 1...20 {
            client.send(.setVolume(scope: .output, value: Float(step) / 20))
        }
        var received = 0
        var state = try await messages.nextState()
        received += 1
        while state.output?.volume != 1 {
            state = try await messages.nextState()
            received += 1
        }
        #expect(received < 20, "Los state se agrupan en vez de salir uno por comando")
    }

    /// Dos clientes con claves distintas, conectados a la vez: el servidor elige la PSK por
    /// la identidad de cada handshake.
    @Test func everyClientReceivesChanges() async throws {
        defer { server.stop() }
        let (phone, phoneMessages) = try await connect(name: "iPhone")
        let (pad, padMessages) = try await connect(TestKeys.pad, name: "iPad")
        defer {
            phone.disconnect()
            pad.disconnect()
        }
        _ = try await phoneMessages.next()
        _ = try await padMessages.next()

        phone.send(.setVolume(scope: .output, value: 0.4))
        #expect(try await padMessages.nextState().output?.volume == 0.4)
        #expect(try await phoneMessages.nextState().output?.volume == 0.4)
        #expect(Set(server.clients.compactMap(\.deviceId)) == [TestKeys.phone.identity, TestKeys.pad.identity])
    }

    @Test func unsupportedVersionIsRejectedAndClosed() async throws {
        defer { server.stop() }
        let (client, messages) = try await connect(helloVersion: 99)

        try await messages.nextError(.unsupportedVersion)
        try await waitUntil("el agente cierra la conexión") {
            if case .disconnected = client.status { true } else { false }
        }
    }

    @Test func outOfRangeVolumeIsRejected() async throws {
        defer { server.stop() }
        let (client, messages) = try await connect()
        defer { client.disconnect() }
        _ = try await messages.next()

        client.sendRaw(Data(#"{"type":"setVolume","scope":"output","value":1.5}"#.utf8))
        try await messages.nextError(.invalidValue)
        #expect(agent.commands.isEmpty)
        #expect(client.status == .connected, "Un mensaje inválido no cierra la conexión")
    }

    @Test func agentErrorsReachTheClient() async throws {
        defer { server.stop() }
        let (client, messages) = try await connect()
        defer { client.disconnect() }
        _ = try await messages.next()

        client.send(.setDefaultDevice(scope: .output, deviceId: "HDMI"))
        try await messages.nextError(.notSettable)
        #expect(client.lastError?.code == .notSettable)
    }

    // MARK: - Helpers

    private func connect(
        _ device: (identity: String, key: PresharedKey) = TestKeys.phone,
        name: String = "Test", helloVersion: Int = ProtocolVersion.current
    ) async throws -> (LevelDeckClient, MessageRecorder) {
        try await LevelDeckKitTests.connect(
            to: server, security: TestKeys.client(device), name: name,
            deviceID: device.identity, helloVersion: helloVersion
        )
    }
}
