import Foundation
@preconcurrency import Network
import Testing
@testable import LevelDeckKit

@MainActor
@Suite("URL del WebSocket del cliente")
struct WebSocketURLTests {
    @Test func ipv4() {
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: 8080)
        #expect(LevelDeckClient.webSocketURL(for: endpoint)?.absoluteString == "ws://127.0.0.1:8080/")
    }

    @Test func hostName() {
        let endpoint = NWEndpoint.hostPort(host: "mac-mini.local", port: 51000)
        #expect(LevelDeckClient.webSocketURL(for: endpoint)?.absoluteString == "ws://mac-mini.local:51000/")
    }

    @Test func ipv6IsBracketed() throws {
        let endpoint = NWEndpoint.hostPort(host: .ipv6(try #require(IPv6Address("::1"))), port: 9000)
        #expect(LevelDeckClient.webSocketURL(for: endpoint)?.absoluteString == "ws://[::1]:9000/")
    }

    @Test func urlPassesThrough() throws {
        let url = try #require(URL(string: "ws://example.local:1/"))
        #expect(LevelDeckClient.webSocketURL(for: .url(url)) == url)
    }
}
