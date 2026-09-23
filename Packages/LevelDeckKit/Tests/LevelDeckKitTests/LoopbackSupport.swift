import Foundation
@preconcurrency import Network
import Testing
@testable import LevelDeckKit

// Apoyo para los tests de integración en loopback (SPEC §11): agente en memoria, cola de
// mensajes con espera acotada y conexión de un cliente al puerto dinámico del servidor.

/// Claves fijas de prueba para el transporte TLS-PSK.
enum TestKeys {
    static let phone = (identity: "phone-test-identity", key: key(1))
    static let pad = (identity: "pad-test-identity", key: key(2))

    static func key(_ byte: UInt8) -> PresharedKey {
        PresharedKey(Data(repeating: byte, count: PresharedKey.byteCount))!
    }

    /// Conjunto del servidor con los dos dispositivos de prueba.
    static var serverSet: PresharedKeySet {
        PresharedKeySet([phone.identity: phone.key, pad.identity: pad.key])
    }

    static func client(_ device: (identity: String, key: PresharedKey)) -> TransportSecurity {
        .tlsPSK(.single(identity: device.identity, key: device.key))
    }
}

/// Espera el puerto del servidor y conecta un cliente a 127.0.0.1.
@MainActor
func connect(
    to server: LevelDeckServer, security: TransportSecurity, name: String = "Test",
    deviceID: String? = nil, helloVersion: Int = ProtocolVersion.current
) async throws -> (LevelDeckClient, MessageRecorder) {
    try await waitUntil("el listener queda listo") { server.port != nil }
    let port = try #require(server.port.flatMap(NWEndpoint.Port.init(rawValue:)))
    let client = LevelDeckClient(
        endpoint: .hostPort(host: "127.0.0.1", port: port),
        security: security, deviceName: name, deviceID: deviceID, helloVersion: helloVersion
    )
    let recorder = MessageRecorder()
    client.onMessage = { recorder.record($0) }
    recorder.describeContext = { [weak client] in
        "cliente=\(client.map { "\($0.status)" } ?? "nil") servidor=\(server.status) "
            + "clientes=\(server.clients.map(\.deviceName)) eventos=\(server.connectionEvents)"
    }
    client.connect()
    return (client, recorder)
}

/// `true` cuando la conexión ya no va a llegar a `connected`: falló o quedó esperando la red.
@MainActor
func isRejected(_ client: LevelDeckClient) -> Bool {
    switch client.status {
    case .disconnected(.some), .waiting:
        true
    default:
        false
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
    /// Estado de cliente y servidor para el mensaje de timeout.
    var describeContext: (@MainActor () -> String)?
    private var waiter: (id: UUID, continuation: CheckedContinuation<AgentMessage, any Error>)?

    var isEmpty: Bool { buffer.isEmpty }

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
        waiter.continuation.resume(throwing: TimeoutError(
            description: "Sin mensaje en \(timeout); \(describeContext?() ?? "sin contexto")"
        ))
    }

    func nextState() async throws -> StateSnapshot {
        let message = try await next()
        guard case let .state(snapshot, _) = message else {
            throw TimeoutError(description: "Se esperaba state y llegó \(message)")
        }
        return snapshot
    }

    /// El siguiente mensaje debe ser un `error` con ese código.
    func nextError(_ code: ErrorCode) async throws {
        let message = try await next()
        guard case let .error(received, _) = message else {
            throw TimeoutError(description: "Se esperaba error \(code) y llegó \(message)")
        }
        #expect(received == code)
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
