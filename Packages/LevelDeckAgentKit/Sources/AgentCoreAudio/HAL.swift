import AgentAudio
import AudioToolbox
import CoreAudio
import LevelDeckKit

/// Minimal wrapper over the `AudioObject` property API.
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

    /// `CFString` property (name, UID). The caller owns the reference.
    static func string(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector
    ) throws(AudioControlError) -> String {
        let value: Unmanaged<CFString>? = try get(object, address(selector), initial: nil)
        guard let value else { throw .coreAudio(status: Int32(kAudioHardwareUnspecifiedError)) }
        return value.takeRetainedValue() as String
    }

    /// The scope's default device, or `nil` if there is none.
    static func defaultDevice(_ scope: Scope) throws(AudioControlError) -> AudioObjectID? {
        let device = try get(systemObject, address(scope.defaultDeviceSelector), initial: AudioObjectID(0))
        return device == AudioObjectID(kAudioObjectUnknown) ? nil : device
    }

    /// All HAL devices, unfiltered (`kAudioHardwarePropertyDevices`).
    static func allDevices() throws(AudioControlError) -> [AudioObjectID] {
        try array(systemObject, address(kAudioHardwarePropertyDevices))
    }

    /// `true` if the device has at least one stream in the scope.
    static func hasStreams(_ device: AudioObjectID, _ scope: Scope) -> Bool {
        var streams = address(kAudioDevicePropertyStreams, scope: scope.halScope)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &streams, 0, nil, &size) == noErr && size > 0
    }

    /// `kAudioDevicePropertyIsHidden`. If the device doesn't expose it, it is treated as visible.
    static func isHidden(_ device: AudioObjectID) -> Bool {
        let hidden = address(kAudioDevicePropertyIsHidden)
        guard has(device, hidden) else { return false }
        return ((try? get(device, hidden, initial: UInt32(0))) ?? 0) != 0
    }

    /// Device with that UID, or `nil` if none (`kAudioHardwarePropertyTranslateUIDToDevice`).
    static func device(forUID uid: String) throws(AudioControlError) -> AudioObjectID? {
        var translate = address(kAudioHardwarePropertyTranslateUIDToDevice)
        // The qualifier is the UID as a `CFString`; Swift keeps the reference alive.
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

    /// Variable-size property with elements of type `T`.
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
        // The list may have shrunk between the two calls: `size` holds what was written.
        return Array(UnsafeBufferPointer(start: buffer, count: Int(size) / MemoryLayout<T>.stride))
    }

    /// Total number of the device's channels in the scope, per its stream configuration.
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
