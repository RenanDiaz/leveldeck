#if LEVELDECK_INSECURE_TRANSPORT
import Foundation
@preconcurrency import Network
import Testing
@testable import LevelDeckKit

/// The plaintext transport still exists only in Debug builds of `LevelDeckKit`, to
/// inspect the protocol (SPEC §5.3). The apps no longer use it.
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
