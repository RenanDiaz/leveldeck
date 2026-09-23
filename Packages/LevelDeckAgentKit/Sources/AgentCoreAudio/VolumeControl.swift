import AgentAudio
import AudioToolbox
import CoreAudio
import LevelDeckKit

/// Cómo se controla el volumen de un dispositivo en un scope (SPEC §5.2).
///
/// Orden de preferencia: volumen virtual principal, `VolumeScalar` en el elemento principal
/// y, por último, `VolumeScalar` canal por canal. Se usa la primera opción configurable; si
/// ninguna lo es, la primera que exista queda como solo lectura.
struct VolumeControl {
    /// Propiedades que representan el volumen. Con varias (una por canal), se leen
    /// promediadas y se escriben todas con el mismo valor.
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

    /// Volumen normalizado. Un dispositivo sin control de volumen se reporta en 0.
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
