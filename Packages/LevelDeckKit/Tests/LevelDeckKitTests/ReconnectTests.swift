import Foundation
@preconcurrency import Network
import Testing
@testable import LevelDeckKit

/// Reconnection with backoff (Phase 5, SPEC §6.2) with a manual clock: the test advances time and
/// checks that each attempt fires exactly when its wait expires, without actually sleeping.
/// The only real-time wait is for the attempt to fail or connect on loopback.
@MainActor
@Suite("Reconexión con backoff", .serialized)
struct ReconnectTests {
    let clock = ManualClock()

    @Test func retriesFollowBackoffIntervals() async throws {
        let client = try makeClient(port: unusedLoopbackPort())
        defer { client.disconnect() }
        client.connect()

        let expected: [Int] = [1, 2, 4, 8, 10, 10]
        for (index, seconds) in expected.enumerated() {
            let failures = index + 1
            try await waitForRetry(client, afterFailures: failures)
            #expect(client.scheduledRetryDelay == .seconds(seconds), "Espera tras \(failures) fallos")
            #expect(client.attempts == failures)

            // An instant before expiry, no attempt fires.
            clock.advance(by: .seconds(seconds) - .milliseconds(1))
            await settle()
            #expect(client.attempts == failures, "Reintentó antes de tiempo tras \(failures) fallos")

            clock.advance(by: .milliseconds(1))
            try await waitUntil("sale el intento \(failures + 1)") { client.attempts == failures + 1 }
        }
    }

    @Test func reconnectNowSkipsTheWaitAndResetsTheBackoff() async throws {
        let client = try makeClient(port: unusedLoopbackPort())
        defer { client.disconnect() }
        client.connect()
        try await waitForRetry(client, afterFailures: 1)
        clock.advance(by: .seconds(1))
        try await waitForRetry(client, afterFailures: 2)
        #expect(client.scheduledRetryDelay == .seconds(2))

        // Back to the foreground: immediate attempt, without advancing the clock.
        client.reconnectNow()
        #expect(client.attempts == 3)
        #expect(client.scheduledRetryDelay == nil)
        try await waitForRetry(client, afterFailures: 1)
        #expect(client.scheduledRetryDelay == .seconds(1), "Los fallos se cuentan de nuevo desde cero")
        #expect(clock.sleeperCount == 1, "La espera anterior se canceló")
    }

    /// The agent isn't there; it shows up on its port and the client connects on its own on the next
    /// attempt. If it goes away afterwards, the backoff starts again from 1 s.
    @Test func recoversWhenTheAgentComesBack() async throws {
        let port = try unusedLoopbackPort()
        let client = makeClient(port: port)
        let recorder = MessageRecorder()
        client.onMessage = { recorder.record($0) }
        defer { client.disconnect() }
        client.connect()
        try await waitForRetry(client, afterFailures: 1)
        clock.advance(by: .seconds(1))
        try await waitForRetry(client, afterFailures: 2)

        let agent = FakeAgent()
        let server = LevelDeckServer(security: .tlsPSK(TestKeys.serverSet), advertise: false, port: port)
        server.delegate = agent
        server.start()
        defer { server.stop() }
        try await waitUntil("el listener queda listo") { server.port != nil }

        clock.advance(by: .seconds(2))
        _ = try await recorder.nextState()
        #expect(client.status == .connected)
        #expect(client.attempts == 3)

        server.stop()
        try await waitForRetry(client, afterFailures: 1)
        #expect(client.scheduledRetryDelay == .seconds(1), "Conectar reinicia el backoff")
    }

    /// A revoked device doesn't retry: its key no longer works.
    @Test func doesNotRetryAfterNotPaired() async throws {
        let agent = FakeAgent()
        let server = LevelDeckServer(security: .tlsPSK(TestKeys.serverSet), advertise: false)
        server.delegate = agent
        server.start()
        defer { server.stop() }
        try await waitUntil("el listener queda listo") { server.port != nil }
        let client = try makeClient(port: #require(server.port.flatMap(NWEndpoint.Port.init(rawValue:))))
        let recorder = MessageRecorder()
        client.onMessage = { recorder.record($0) }
        defer { client.disconnect() }
        client.connect()
        _ = try await recorder.nextState()

        server.disconnect(deviceId: TestKeys.phone.identity)
        try await recorder.nextError(.notPaired)
        try await waitUntil("el cliente queda desconectado") {
            if case .disconnected = client.status { true } else { false }
        }
        await settle()
        #expect(client.scheduledRetryDelay == nil)
        #expect(clock.sleeperCount == 0)
        #expect(client.attempts == 1)
    }

    // MARK: - Helpers

    private func makeClient(port: NWEndpoint.Port) -> LevelDeckClient {
        LevelDeckClient(
            endpoint: .hostPort(host: "127.0.0.1", port: port), security: TestKeys.client(TestKeys.phone),
            deviceName: "iPhone", deviceID: TestKeys.phone.identity,
            reconnect: ReconnectPolicy(), clock: clock
        )
    }

    /// Waits for the in-flight attempt to fail and the next one to be scheduled.
    private func waitForRetry(_ client: LevelDeckClient, afterFailures failures: Int) async throws {
        let clock = clock
        try await waitUntil("queda programado el reintento tras \(failures) fallos") {
            guard case let .reconnecting(attempt, _) = client.status else { return false }
            return attempt == failures && client.scheduledRetryDelay != nil && clock.sleeperCount == 1
        }
    }
}
