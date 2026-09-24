import AgentAudio
import AudioToolbox
import CoreAudio
import LevelDeckKit

/// How a device's volume is controlled in a scope (SPEC §5.2).
///
/// Order of preference: virtual main volume, `VolumeScalar` on the main element
/// and, lastly, per-channel `VolumeScalar`. The first settable option is used; if
/// none is, the first one that exists is kept as read-only.
struct VolumeControl {
    /// Properties that represent the volume. With several (one per channel), they are read
    /// averaged and all written with the same value.
    let addresses: [AudioObjectPropertyAddress]
    let isSettable: Bool

    static let none = VolumeControl(addresses: [], isSettable: false)

    static func resolve(_ device: AudioObjectID, _ scope: Scope) -> VolumeControl {
        let halScope = scope.halScope
        let channelCount = HAL.channelCount(device, scope)
        let candidates: [[AudioObjectPropertyAddress]] = [
            [HAL.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: halScope)],
            [HAL.address(kAudioDevicePropertyVolumeScalar, scope: halScope)],
            channelCount > 0
                ? (1...channelCount).map {
                    HAL.address(kAudioDevicePropertyVolumeScalar, scope: halScope, element: UInt32($0))
                }
                : [],
        ]
        .filter { !$0.isEmpty && $0.allSatisfy { HAL.has(device, $0) } }

        if let settable = candidates.first(where: { $0.allSatisfy { HAL.isSettable(device, $0) } }) {
            return VolumeControl(addresses: settable, isSettable: true)
        }
        if let readOnly = candidates.first {
            return VolumeControl(addresses: readOnly, isSettable: false)
        }
        return .none
    }

    /// Normalized volume. A device without a volume control reports 0.
    func read(_ device: AudioObjectID) throws(AudioControlError) -> Float {
        guard !addresses.isEmpty else { return 0 }
        var total: Float32 = 0
        for address in addresses {
            total += try HAL.get(device, address, initial: Float32(0))
        }
        return min(max(total / Float32(addresses.count), 0), 1)
    }

    func write(_ value: Float, to device: AudioObjectID) throws(AudioControlError) {
        for address in addresses {
            try HAL.set(device, address, Float32(value))
        }
    }
}
