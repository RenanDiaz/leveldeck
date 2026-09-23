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

    /// Todos los dispositivos de la HAL, sin filtrar (`kAudioHardwarePropertyDevices`).
    static func allDevices() throws(AudioControlError) -> [AudioObjectID] {
        try array(systemObject, address(kAudioHardwarePropertyDevices))
    }

    /// `true` si el dispositivo tiene al menos un stream en el scope.
    static func hasStreams(_ device: AudioObjectID, _ scope: Scope) -> Bool {
        var streams = address(kAudioDevicePropertyStreams, scope: scope.halScope)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &streams, 0, nil, &size) == noErr && size > 0
    }

    /// `kAudioDevicePropertyIsHidden`. Si el dispositivo no la expone, se toma como visible.
    static func isHidden(_ device: AudioObjectID) -> Bool {
        let hidden = address(kAudioDevicePropertyIsHidden)
        guard has(device, hidden) else { return false }
        return ((try? get(device, hidden, initial: UInt32(0))) ?? 0) != 0
    }

    /// Dispositivo con ese UID, o `nil` si no existe (`kAudioHardwarePropertyTranslateUIDToDevice`).
    static func device(forUID uid: String) throws(AudioControlError) -> AudioObjectID? {
        var translate = address(kAudioHardwarePropertyTranslateUIDToDevice)
        // El calificador es el UID como `CFString`; Swift mantiene la referencia viva.
        var qualifier = uid as CFString
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &qualifier) { qualifierPointer in
            AudioObjectGetPropertyData(
                systemObject, &translate,
                UInt32(MemoryLayout<CFString>.size), qualifierPointer,
                &size, &device
            )
        }
        guard status == noErr else { throw .coreAudio(status: status) }
        return device == AudioObjectID(kAudioObjectUnknown) ? nil : device
    }

    static func setDefaultDevice(_ device: AudioObjectID, _ scope: Scope) throws(AudioControlError) {
        try set(systemObject, address(scope.defaultDeviceSelector), device)
    }

    /// Propiedad de tamaño variable con elementos de tipo `T`.
    private static func array<T>(
        _ object: AudioObjectID, _ address: AudioObjectPropertyAddress
    ) throws(AudioControlError) -> [T] {
        var address = address
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size)
        guard status == noErr else { throw .coreAudio(status: status) }
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        let buffer = UnsafeMutablePointer<T>.allocate(capacity: count)
        defer { buffer.deallocate() }
        status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, buffer)
        guard status == noErr else { throw .coreAudio(status: status) }
        // La lista pudo encogerse entre las dos llamadas: `size` trae lo que se escribió.
        return Array(UnsafeBufferPointer(start: buffer, count: Int(size) / MemoryLayout<T>.stride))
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
