import AgentAudio
import AudioToolbox
import CoreAudio
import LevelDeckKit

/// Envoltorio mínimo sobre la API de propiedades de `AudioObject`.
enum HAL {
    static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func has(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        return AudioObjectHasProperty(object, &address)
    }

    static func isSettable(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(object, &address, &settable) == noErr && settable.boolValue
    }

    static func get<T>(
        _ object: AudioObjectID, _ address: AudioObjectPropertyAddress, initial: T
    ) throws(AudioControlError) -> T {
        var address = address
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        guard status == noErr else { throw .coreAudio(status: status) }
        return value
    }

    static func set<T>(
        _ object: AudioObjectID, _ address: AudioObjectPropertyAddress, _ value: T
    ) throws(AudioControlError) {
        var address = address
        var value = value
        let status = AudioObjectSetPropertyData(
            object, &address, 0, nil, UInt32(MemoryLayout<T>.size), &value
        )
        guard status == noErr else { throw .coreAudio(status: status) }
    }

    /// Propiedad `CFString` (nombre, UID). Quien la pide es dueño de la referencia.
    static func string(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector
    ) throws(AudioControlError) -> String {
        let value: Unmanaged<CFString>? = try get(object, address(selector), initial: nil)
        guard let value else { throw .coreAudio(status: Int32(kAudioHardwareUnspecifiedError)) }
        return value.takeRetainedValue() as String
    }

    /// Dispositivo por defecto del scope, o `nil` si no hay ninguno.
    static func defaultDevice(_ scope: Scope) throws(AudioControlError) -> AudioObjectID? {
        let device = try get(systemObject, address(scope.defaultDeviceSelector), initial: AudioObjectID(0))
        return device == AudioObjectID(kAudioObjectUnknown) ? nil : device
    }

    /// Número total de canales del dispositivo en el scope, según su configuración de streams.
    static func channelCount(_ device: AudioObjectID, _ scope: Scope) -> Int {
        var streams = address(kAudioDevicePropertyStreamConfiguration, scope: scope.halScope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &streams, 0, nil, &size) == noErr, size > 0 else {
            return 0
        }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &streams, 0, nil, &size, raw) == noErr else { return 0 }
        let buffers = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}

extension Scope {
    var halScope: AudioObjectPropertyScope {
        switch self {
        case .output: kAudioObjectPropertyScopeOutput
        case .input: kAudioObjectPropertyScopeInput
        }
    }

    var defaultDeviceSelector: AudioObjectPropertySelector {
        switch self {
        case .output: kAudioHardwarePropertyDefaultOutputDevice
        case .input: kAudioHardwarePropertyDefaultInputDevice
        }
    }
}
