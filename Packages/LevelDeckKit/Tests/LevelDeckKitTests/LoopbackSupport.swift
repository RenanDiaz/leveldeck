import Foundation
@preconcurrency import Network
import Testing
@testable import LevelDeckKit

// Support for the loopback integration tests (SPEC §11): in-memory agent, message queue
// with bounded waits, and connecting a client to the server's dynamic port.

/// Fixed test keys for the TLS-PSK transport.
enum TestKeys {
    static let phone = (identity: "phone-test-identity", key: key(1))
    static let pad = (identity: "pad-test-identity", key: key(2))

    static func key(_ byte: UInt8) -> PresharedKey {
        PresharedKey(Data(repeating: byte, count: PresharedKey.byteCount))!
    }

    /// Server set with the two test devices.
    static var serverSet: PresharedKeySet {
        PresharedKeySet([phone.identity: phone.key, pad.identity: pad.key])
    }

    static func client(_ device: (identity: String, key: PresharedKey)) -> TransportSecurity {
        .tlsPSK(.single(identity: device.identity, key: device.key))
    }
}

/// Waits for the server's port and connects a client to 127.0.0.1.
@MainActor
func connect(
    to server: LevelDeckServer, security: TransportSecurity, name: String = "Test",
    deviceID: String? = nil, helloVersion: Int = ProtocolVersion.current,
    hello: ((Data) -> ClientMessage?)? = nil
) async throws -> (LevelDeckClient, MessageRecorder) {
    try await waitUntil("el listener queda listo") { server.port != nil }
    let port = try #require(server.port.flatMap(NWEndpoint.Port.init(rawValue:)))
    let client = LevelDeckClient(
        endpoint: .hostPort(host: "127.0.0.1", port: port),
        security: security, deviceName: name, deviceID: deviceID, helloVersion: helloVersion
    )
    client.helloForTests = hello
    let recorder = MessageRecorder()
    client.onMessage = { recorder.record($0) }
    recorder.describeContext = { [weak client] in
        "cliente=\(client.map { "\($0.status)" } ?? "nil") servidor=\(server.status) "
            + "clientes=\(server.clients.map(\.deviceName)) eventos=\(server.connectionEvents)"
    }
    client.connect()
    return (client, recorder)
}

/// `true` when the connection will no longer reach `connected`: it failed or is waiting for the network.
@MainActor
func isRejected(_ client: LevelDeckClient) -> Bool {
    switch client.status {
    case .disconnected(.some), .waiting:
        true
    default:
        false
    }
}

/// In-memory agent: applies commands to the fixtures' snapshot.
///
/// `catalog` holds the state of every device that can be selected with `setDefaultDevice`;
/// only one that is also in `snapshot.devices` (connected) can be selected.
@MainActor
final class FakeAgent: LevelDeckServerDelegate {
    var snapshot = Fixtures.snapshot
    var catalog: [String: ChannelState] = [
        Fixtures.headphones.deviceId: Fixtures.headphones,
    ]
    private(set) var commands: [ClientMessage] = []

    /// Connects a device, as the agent would see it when plugged in.
    func plug(_ channel: ChannelState, scope: Scope) {
        catalog[channel.deviceId] = channel
        snapshot.devices[scope].append(DeviceInfo(id: channel.deviceId, name: channel.deviceName))
    }

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
        case let .setDefaultDevice(scope, deviceId):
            guard snapshot.devices[scope].contains(where: { $0.id == deviceId }),
                  let channel = deviceId == snapshot[scope]?.deviceId ? snapshot[scope] : catalog[deviceId]
            else {
                return AgentError(.deviceNotFound, "No existe el dispositivo \(deviceId).")
            }
            snapshot[scope] = channel
        }
        return nil
    }
}

struct TimeoutError: Error, CustomStringConvertible {
    let description: String
}

/// Queue of received messages with bounded waits.
@MainActor
final class MessageRecorder {
    private var buffer: [AgentMessage] = []
    /// Client and server state for the timeout message.
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

    /// Discards `state` until the first one that meets the condition. An `error` along the way fails.
    func nextState(where condition: (StateSnapshot) -> Bool) async throws -> StateSnapshot {
        while true {
            let state = try await nextState()
            if condition(state) { return state }
        }
    }

    /// The next message must be an `error` with that code.
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
