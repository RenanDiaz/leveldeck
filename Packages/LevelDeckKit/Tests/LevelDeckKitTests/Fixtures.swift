import Foundation
import Testing
@testable import LevelDeckKit

enum Fixtures {
    /// El ejemplo de `state` de SPEC §8 con IDs concretos.
    static let stateJSON = Data("""
    {
      "type": "state",
      "v": 1,
      "output": { "deviceId": "BuiltInSpeakerDevice", "deviceName": "MacBook Pro Speakers",
                  "volume": 0.62, "muted": false, "settable": true },
      "input":  { "deviceId": "BuiltInMicrophoneDevice", "deviceName": "MacBook Pro Microphone",
                  "volume": 0.80, "muted": false, "settable": true },
      "devices": {
        "output": [{ "id": "BuiltInSpeakerDevice", "name": "MacBook Pro Speakers" }],
        "input":  [{ "id": "BuiltInMicrophoneDevice", "name": "MacBook Pro Microphone" }]
      }
    }
    """.utf8)

    static let snapshot = StateSnapshot(
        output: ChannelState(
            deviceId: "BuiltInSpeakerDevice", deviceName: "MacBook Pro Speakers",
            volume: 0.62, muted: false, settable: true
        ),
        input: ChannelState(
            deviceId: "BuiltInMicrophoneDevice", deviceName: "MacBook Pro Microphone",
            volume: 0.80, muted: false, settable: true
        ),
        devices: DeviceList(
            output: [DeviceInfo(id: "BuiltInSpeakerDevice", name: "MacBook Pro Speakers")],
            input: [DeviceInfo(id: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone")]
        )
    )

    /// Decodifica el JSON a un diccionario para inspeccionar la forma del mensaje en el cable.
    static func object(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
