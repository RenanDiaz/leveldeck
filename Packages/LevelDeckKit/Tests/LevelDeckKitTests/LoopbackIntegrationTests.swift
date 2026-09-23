#if LEVELDECK_INSECURE_TRANSPORT
import Foundation
@preconcurrency import Network
import Testing
@testable import LevelDeckKit

/// Ciclo completo sobre la red real en loopback (SPEC §11): servidor y cliente de
/// LevelDeckKit, `hello` → `state`, `setVolume` → `state`, errores y varios clientes.
///
/// Usa el transporte en claro de la Fase 2; la Fase 3 lo cambia por TLS-PSK con una clave
/// de prueba. Sin Bonjour: el cliente conecta directo al puerto dinámico del listener.
@MainActor
@Suite("Integración en loopback", .serialized)
struct LoopbackIntegrationTests {
    let agent = FakeAgent()
    let server: LevelDeckServer

    init() async throws {
        server = LevelDeckServer(
            security: .insecurePlaintext, advertise: false, requiredInterfaceType: .loopback
        )
        server.delegate = agent
        server.start()
        let server = server
        try await waitUntil("el listener queda listo") { server.port != nil }
    }

    @Test func helloIsAnsweredWithState() async throws {
        defer { server.stop() }
        let (client, messages) = try connect(name: "iPhone de prueba")
        defer { client.disconnect() }

        #expect(try await messages.next() == .state(Fixtures.snapshot))
        #expect(client.status == .connected)
        let server = server
        try await waitUntil("el servidor registra al cliente") {
            server.clients.map(\.deviceName) == ["iPhone de prueba"]
        }
    }

    @Test("setVolume produce un state con el valor nuevo", arguments: Scope.allCases)
    func setVolumeBroadcastsState(scope: Scope) async throws {
        defer { server.stop() }
        let (client, messages) = try connect()
        defer { client.disconnect() }
        _ = try await messages.next()

        #expect(client.send(.setVolume(scope: scope, value: 0.25)))
        let state = try await messages.nextState()
        #expect(state[scope]?.volume == 0.25)
        #expect(agent.commands == [.setVolume(scope: scope, value: 0.25)])
    }

    @Test func setMuteBroadcastsState() async throws {
        defer { server.stop() }
        let (client, messages) = try connect()
        defer { client.disconnect() }
        _ = try await messages.next()

        client.send(.setMute(scope: .input, muted: true))
        let state = try await messages.nextState()
        #expect(state.input?.muted == true)
    }

    /// Una ráfaga de comandos se agrupa (máx. 30/s), pero el último valor siempre llega.
    @Test func burstEndsOnFinalValue() async throws {
        defer { server.stop() }
        let (client, messages) = try connect()
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

    @Test func everyClientReceivesChanges() async throws {
        defer { server.stop() }
        let (phone, phoneMessages) = try connect(name: "iPhone")
        let (pad, padMessages) = try connect(name: "iPad")
        defer {
            phone.disconnect()
            pad.disconnect()
        }
        _ = try await phoneMessages.next()
        _ = try await padMessages.next()

        phone.send(.setVolume(scope: .output, value: 0.4))
        #expect(try await padMessages.nextState().output?.volume == 0.4)
        #expect(try await phoneMessages.nextState().output?.volume == 0.4)
    }

    @Test func unsupportedVersionIsRejectedAndClosed() async throws {
        defer { server.stop() }
        let (client, messages) = try connect(helloVersion: 99)

        guard case let .error(code, _) = try await messages.next() else {
            Issue.record("Se esperaba un error")
            return
        }
        #expect(code == .unsupportedVersion)
        try await waitUntil("el agente cierra la conexión") {
            if case .disconnected = client.status { true } else { false }
        }
    }

    @Test func outOfRangeVolumeIsRejected() async throws {
        defer { server.stop() }
        let (client, messages) = try connect()
        defer { client.disconnect() }
        _ = try await messages.next()

        client.sendRaw(Data(#"{"type":"setVolume","scope":"output","value":1.5}"#.utf8))
        guard case let .error(code, _) = try await messages.next() else {
            Issue.record("Se esperaba un error")
            return
        }
        #expect(code == .invalidValue)
        #expect(agent.commands.isEmpty)
        #expect(client.status == .connected, "Un mensaje inválido no cierra la conexión")
    }

    @Test func agentErrorsReachTheClient() async throws {
        defer { server.stop() }
        let (client, messages) = try connect()
        defer { client.disconnect() }
        _ = try await messages.next()

        client.send(.setDefaultDevice(scope: .output, deviceId: "HDMI"))
        guard case let .error(code, _) = try await messages.next() else {
            Issue.record("Se esperaba un error")
            return
        }
        #expect(code == .notSettable)
        #expect(client.lastError?.code == .notSettable)
    }

    // MARK: - Helpers

    private func connect(
        name: String = "Test", helloVersion: Int = ProtocolVersion.current
    ) throws -> (LevelDeckClient, MessageRecorder) {
        let port = try #require(server.port.flatMap(NWEndpoint.Port.init(rawValue:)))
        let client = LevelDeckClient(
            endpoint: .hostPort(host: "127.0.0.1", port: port),
            security: .insecurePlaintext, deviceName: name, helloVersion: helloVersion
        )
        let recorder = MessageRecorder()
        client.onMessage = { recorder.record($0) }
        client.connect()
        return (client, recorder)
    }
}

/// Agente en memoria: aplica los comandos sobre el snapshot de los fixtures.
@MainActor
final class FakeAgent: LevelDeckServerDelegate {
    var snapshot = Fixtures.snapshot
    private(set) var commands: [ClientMessage] = []

    func currentState() -> StateSnapshot {
        snapshot
    }

    func handle(_ command: ClientMessage) -> AgentError? {
        commands.append(command)
        switch command {
        case .hello:
            return nil
        case let .setVolume(scope, value):
            snapshot[scope]?.volume = value
        case let .setMute(scope, muted):
            snapshot[scope]?.muted = muted
        case .setDefaultDevice:
            return AgentError(.notSettable, "Llega en la Fase 4.")
        }
        return nil
    }
}

struct TimeoutError: Error, CustomStringConvertible {
    let description: String
}

/// Cola de mensajes recibidos con espera acotada.
@MainActor
final class MessageRecorder {
    private var buffer: [AgentMessage] = []
    private var waiter: (id: UUID, continuation: CheckedContinuation<AgentMessage, any Error>)?

    func record(_ message: AgentMessage) {
        if let waiter {
            self.waiter = nil
            waiter.continuation.resume(returning: message)
        } else {
            buffer.append(message)
        }
    }

    func next(timeout: Duration = .seconds(5)) async throws -> AgentMessage {
        if !buffer.isEmpty {
            return buffer.removeFirst()
        }
        let id = UUID()
        Task { [weak self] in
            try? await Task.sleep(for: timeout)
            self?.expire(id, after: timeout)
        }
        return try await withCheckedThrowingContinuation { continuation in
            waiter = (id, continuation)
        }
    }

    private func expire(_ id: UUID, after timeout: Duration) {
        guard let waiter, waiter.id == id else { return }
        self.waiter = nil
        waiter.continuation.resume(throwing: TimeoutError(description: "Sin mensaje en \(timeout)"))
    }

    func nextState() async throws -> StateSnapshot {
        let message = try await next()
        guard case let .state(snapshot, _) = message else {
            throw TimeoutError(description: "Se esperaba state y llegó \(message)")
        }
        return snapshot
    }
}

@MainActor
func waitUntil(
    _ what: String, timeout: Duration = .seconds(5), _ condition: () -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else {
            throw TimeoutError(description: "Timeout esperando que \(what)")
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}
#endif
