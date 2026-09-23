#if LEVELDECK_INSECURE_TRANSPORT
import Foundation
@preconcurrency import Network
import Testing
@testable import LevelDeckKit

/// El transporte en claro sigue existiendo solo en builds Debug de `LevelDeckKit`, para
/// inspeccionar el protocolo (SPEC §5.3). Las apps ya no lo usan.
@MainActor
@Suite("Transporte en claro (solo Debug)", .serialized)
struct PlaintextSmokeTests {
    @Test func helloIsAnsweredWithoutTLS() async throws {
        let agent = FakeAgent()
        let server = LevelDeckServer(security: .insecurePlaintext, advertise: false)
        server.delegate = agent
        server.start()
        defer { server.stop() }

        let (client, messages) = try await connect(to: server, security: .insecurePlaintext, name: "Debug")
        defer { client.disconnect() }
        #expect(try await messages.next() == .state(Fixtures.snapshot))
        #expect(server.clients.first?.deviceId == nil)
    }
}
#endif
