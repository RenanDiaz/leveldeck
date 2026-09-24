import Foundation
import Testing
@testable import LevelDeckKit

@Suite("ClientMessage")
struct ClientMessageTests {
    static let allMessages: [ClientMessage] = [
        .hello(deviceName: "iPhone de Renan"),
        .hello(deviceName: "iPhone", deviceId: "8E0B2C1A-0000-4000-8000-000000000001"),
        .hello(deviceName: "iPhone", deviceId: "dev-1", proof: Data(repeating: 7, count: 32)),
        .setVolume(scope: .output, value: 0.5),
        .setVolume(scope: .input, value: 0),
        .setVolume(scope: .output, value: 1),
        .setMute(scope: .output, muted: true),
        .setMute(scope: .input, muted: false),
        .setDefaultDevice(scope: .output, deviceId: "BuiltInSpeakerDevice"),
    ]

    @Test("Ida y vuelta", arguments: allMessages)
    func roundTrip(message: ClientMessage) throws {
        let data = try ProtocolCoder.encode(message)
        #expect(try ProtocolCoder.decode(ClientMessage.self, from: data) == message)
    }

    @Test func helloIncludesTypeAndVersion() throws {
        let object = try Fixtures.object(ProtocolCoder.encode(ClientMessage.hello(deviceName: "iPhone")))
        #expect(object["type"] as? String == "hello")
        #expect(object["v"] as? Int == ProtocolVersion.current)
        #expect(object["deviceName"] as? String == "iPhone")
    }

    @Test func helloOmitsDeviceIdWhenAbsent() throws {
        let object = try Fixtures.object(ProtocolCoder.encode(ClientMessage.hello(deviceName: "iPhone")))
        #expect(object["deviceId"] == nil)
        let paired = try Fixtures.object(ProtocolCoder.encode(ClientMessage.hello(deviceName: "iPhone", deviceId: "dev-1")))
        #expect(paired["deviceId"] as? String == "dev-1")
    }

    @Test func helloCarriesProofAsBase64URL() throws {
        let proof = Data([0xFB, 0xFF, 0x00, 0x3E])
        let object = try Fixtures.object(ProtocolCoder.encode(
            ClientMessage.hello(deviceName: "iPhone", deviceId: "dev-1", proof: proof)
        ))
        #expect(object["proof"] as? String == "-_8APg")
        let bare = try Fixtures.object(ProtocolCoder.encode(ClientMessage.hello(deviceName: "iPhone")))
        #expect(bare["proof"] == nil)
    }

    @Test func rejectsHelloWithMalformedProof() {
        let json = Data(#"{"type":"hello","v":3,"deviceName":"iPhone","deviceId":"d","proof":"no es base64!"}"#.utf8)
        #expect(throws: DecodingError.self) {
            try ProtocolCoder.decode(ClientMessage.self, from: json)
        }
    }

    @Test func decodesHelloWithoutDeviceId() throws {
        // Un `hello` de la Fase 2 (sin deviceId) sigue siendo válido; el authorizer decide.
        let json = Data(#"{"type":"hello","v":2,"deviceName":"iPhone"}"#.utf8)
        #expect(try ProtocolCoder.decode(ClientMessage.self, from: json) == .hello(deviceName: "iPhone", version: 2, deviceId: nil))
    }

    @Test func commandsHaveFlatPayloadWithoutVersion() throws {
        let object = try Fixtures.object(ProtocolCoder.encode(ClientMessage.setMute(scope: .input, muted: true)))
        #expect(object["type"] as? String == "setMute")
        #expect(object["scope"] as? String == "input")
        #expect(object["muted"] as? Bool == true)
        #expect(object["v"] == nil)
    }

    @Test func decodesLiteralJSON() throws {
        let json = Data(#"{"type":"setDefaultDevice","scope":"output","deviceId":"USB-DAC"}"#.utf8)
        #expect(try ProtocolCoder.decode(ClientMessage.self, from: json)
            == .setDefaultDevice(scope: .output, deviceId: "USB-DAC"))
    }

    @Test func decodesHelloWithOtherVersion() throws {
        // La decodificación no valida la versión: eso le toca al agente, que responde `unsupportedVersion`.
        let json = Data(#"{"type":"hello","v":1,"deviceName":"iPhone"}"#.utf8)
        #expect(try ProtocolCoder.decode(ClientMessage.self, from: json) == .hello(deviceName: "iPhone", version: 1))
    }

    @Test("Rechaza volumen fuera de 0–1", arguments: ["-0.01", "1.01", "42"])
    func rejectsOutOfRangeVolume(value: String) {
        let json = Data(#"{"type":"setVolume","scope":"output","value":\#(value)}"#.utf8)
        #expect(throws: DecodingError.self) {
            try ProtocolCoder.decode(ClientMessage.self, from: json)
        }
    }

    @Test("No codifica volumen inválido", arguments: [Float(-0.5), 1.5, .nan, .infinity])
    func refusesToEncodeInvalidVolume(value: Float) {
        #expect(throws: EncodingError.self) {
            try ProtocolCoder.encode(ClientMessage.setVolume(scope: .output, value: value))
        }
    }

    @Test func rejectsUnknownType() {
        let json = Data(#"{"type":"reboot"}"#.utf8)
        #expect(throws: DecodingError.self) {
            try ProtocolCoder.decode(ClientMessage.self, from: json)
        }
    }

    @Test func rejectsMissingField() {
        let json = Data(#"{"type":"setVolume","value":0.5}"#.utf8)
        #expect(throws: DecodingError.self) {
            try ProtocolCoder.decode(ClientMessage.self, from: json)
        }
    }

    @Test func rejectsUnknownScope() {
        let json = Data(#"{"type":"setMute","scope":"both","muted":true}"#.utf8)
        #expect(throws: DecodingError.self) {
            try ProtocolCoder.decode(ClientMessage.self, from: json)
        }
    }
}
