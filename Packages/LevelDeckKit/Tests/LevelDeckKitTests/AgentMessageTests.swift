import Foundation
import Testing
@testable import LevelDeckKit

@Suite("AgentMessage")
struct AgentMessageTests {
    @Test func decodesSpecExample() throws {
        let message = try ProtocolCoder.decode(AgentMessage.self, from: Fixtures.stateJSON)
        #expect(message == .state(Fixtures.snapshot, version: 2))
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

    @Test func volumeSettableFalseSurvivesRoundTrip() throws {
        var snapshot = Fixtures.snapshot
        snapshot.output?.volumeSettable = false
        let data = try ProtocolCoder.encode(AgentMessage.state(snapshot))
        guard case let .state(decoded, _) = try ProtocolCoder.decode(AgentMessage.self, from: data) else {
            Issue.record("Se esperaba un mensaje state")
            return
        }
        #expect(decoded.output?.volumeSettable == false)
        #expect(decoded.output?.muteSettable == true)
    }

    @Test func channelUsesVolumeSettableKey() throws {
        let object = try Fixtures.object(ProtocolCoder.encode(AgentMessage.state(Fixtures.snapshot)))
        let output = try #require(object["output"] as? [String: Any])
        #expect(output["volumeSettable"] as? Bool == true)
        #expect(output["muteSettable"] as? Bool == true)
        #expect(output["settable"] == nil)
    }

    /// Los flags son independientes: mute sin volumen y volumen sin mute viajan tal cual.
    @Test("Flags de configurabilidad independientes", arguments: [(true, false), (false, true), (false, false)])
    func independentSettableFlagsSurviveRoundTrip(volume: Bool, mute: Bool) throws {
        var snapshot = Fixtures.snapshot
        snapshot.input?.volumeSettable = volume
        snapshot.input?.muteSettable = mute
        let data = try ProtocolCoder.encode(AgentMessage.state(snapshot))
        #expect(try ProtocolCoder.decode(AgentMessage.self, from: data) == .state(snapshot))
    }

    @Test func muteSettableSurvivesRoundTrip() throws {
        var snapshot = Fixtures.snapshot
        snapshot.input?.muteSettable = false
        let data = try ProtocolCoder.encode(AgentMessage.state(snapshot))
        #expect(try ProtocolCoder.decode(AgentMessage.self, from: data) == .state(snapshot))
    }

    @Test func absentChannelIsEncodedAsNull() throws {
        var snapshot = Fixtures.snapshot
        snapshot.input = nil
        let data = try ProtocolCoder.encode(AgentMessage.state(snapshot))
        let object = try Fixtures.object(data)
        #expect(object.keys.contains("input"))
        #expect(object["input"] is NSNull)
        #expect(try ProtocolCoder.decode(AgentMessage.self, from: data) == .state(snapshot))
    }

    @Test func rejectsStateWithoutChannelKey() throws {
        var object = try Fixtures.object(Fixtures.stateJSON)
        object.removeValue(forKey: "input")
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) {
            try ProtocolCoder.decode(AgentMessage.self, from: data)
        }
    }

    @Test func rejectsChannelWithoutMuteSettable() {
        let json = Data("""
        {"type":"state","v":2,"input":null,"devices":{"output":[],"input":[]},
         "output":{"deviceId":"a","deviceName":"b","volume":0.5,"muted":false,"volumeSettable":true}}
        """.utf8)
        #expect(throws: DecodingError.self) {
            try ProtocolCoder.decode(AgentMessage.self, from: json)
        }
    }

    /// La clave de la v1 (`settable`) ya no vale: sin `volumeSettable` no se decodifica.
    @Test func rejectsChannelWithLegacySettableKey() {
        let json = Data("""
        {"type":"state","v":1,"input":null,"devices":{"output":[],"input":[]},
         "output":{"deviceId":"a","deviceName":"b","volume":0.5,"muted":false,
                   "settable":true,"muteSettable":true}}
        """.utf8)
        #expect(throws: DecodingError.self) {
            try ProtocolCoder.decode(AgentMessage.self, from: json)
        }
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
