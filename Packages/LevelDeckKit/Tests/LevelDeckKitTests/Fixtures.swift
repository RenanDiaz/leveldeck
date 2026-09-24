import Foundation
import Testing
@testable import LevelDeckKit

enum Fixtures {
    /// The `state` example from SPEC §8 with concrete IDs.
    static let stateJSON = Data("""
    {
      "type": "state",
      "v": 3,
      "output": { "deviceId": "BuiltInSpeakerDevice", "deviceName": "MacBook Pro Speakers",
                  "volume": 0.62, "muted": false, "volumeSettable": true, "muteSettable": true },
      "input":  { "deviceId": "BuiltInMicrophoneDevice", "deviceName": "MacBook Pro Microphone",
                  "volume": 0.80, "muted": false, "volumeSettable": true, "muteSettable": true },
      "devices": {
        "output": [{ "id": "BuiltInSpeakerDevice", "name": "MacBook Pro Speakers" }],
        "input":  [{ "id": "BuiltInMicrophoneDevice", "name": "MacBook Pro Microphone" }]
      }
    }
    """.utf8)

    static let snapshot = StateSnapshot(
        output: ChannelState(
            deviceId: "BuiltInSpeakerDevice", deviceName: "MacBook Pro Speakers",
            volume: 0.62, muted: false, volumeSettable: true, muteSettable: true
        ),
        input: ChannelState(
            deviceId: "BuiltInMicrophoneDevice", deviceName: "MacBook Pro Microphone",
            volume: 0.80, muted: false, volumeSettable: true, muteSettable: true
        ),
        devices: DeviceList(
            output: [DeviceInfo(id: "BuiltInSpeakerDevice", name: "MacBook Pro Speakers")],
            input: [DeviceInfo(id: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone")]
        )
    )

    /// USB headphones: volume without mute, to test independent flags.
    static let headphones = ChannelState(
        deviceId: "AppleUSBAudioEngine:Headset", deviceName: "USB Headset",
        volume: 0.3, muted: false, volumeSettable: true, muteSettable: false
    )

    /// Decodes the JSON into a dictionary to inspect the message's shape on the wire.
    static func object(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
