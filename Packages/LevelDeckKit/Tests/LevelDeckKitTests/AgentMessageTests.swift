import Foundation
import Testing
@testable import LevelDeckKit

@Suite("AgentMessage")
struct AgentMessageTests {
    @Test func decodesSpecExample() throws {
        let message = try ProtocolCoder.decode(AgentMessage.self, from: Fixtures.stateJSON)
        #expect(message == .state(Fixtures.snapshot, version: 1))
    }

    @Test func stateRoundTrip() throws {
        let message = AgentMessage.state(Fixtures.snapshot)
        let data = try ProtocolCoder.encode(message)
        #expect(try ProtocolCoder.decode(AgentMessage.self, from: data) == message)
    }

    @Test func stateHasFlatPayload() throws {
        let object = try Fixtures.object(ProtocolCoder.encode(AgentMessage.state(Fixtures.snapshot)))
        #expect(object["type"] as? String == "state")
        #expect(object["v"] as? Int == ProtocolVersion.current)
        #expect(Set(object.keys) == ["type", "v", "output", "input", "devices"])
    }

    @Test("Ida y vuelta de error", arguments: ErrorCode.allCases)
    func errorRoundTrip(code: ErrorCode) throws {
        let message = AgentMessage.error(code: code, message: "detalle")
        let data = try ProtocolCoder.encode(message)
        #expect(try ProtocolCoder.decode(AgentMessage.self, from: data) == message)
        #expect(try Fixtures.object(data)["code"] as? String == code.rawValue)
    }

    @Test func settableFalseSurvivesRoundTrip() throws {
        var snapshot = Fixtures.snapshot
        snapshot.output.settable = false
        let data = try ProtocolCoder.encode(AgentMessage.state(snapshot))
        guard case let .state(decoded, _) = try ProtocolCoder.decode(AgentMessage.self, from: data) else {
            Issue.record("Se esperaba un mensaje state")
            return
        }
        #expect(decoded.output.settable == false)
    }

    @Test func rejectsUnknownErrorCode() {
        let json = Data(#"{"type":"error","code":"kaboom","message":"x"}"#.utf8)
        #expect(throws: DecodingError.self) {
            try ProtocolCoder.decode(AgentMessage.self, from: json)
        }
    }

    @Test func rejectsStateWithoutVersion() {
        let json = Data(#"{"type":"state","output":{},"input":{},"devices":{}}"#.utf8)
        #expect(throws: DecodingError.self) {
            try ProtocolCoder.decode(AgentMessage.self, from: json)
        }
    }
}
