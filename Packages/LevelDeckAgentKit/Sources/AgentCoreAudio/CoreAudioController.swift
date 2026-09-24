import AgentAudio
import AudioToolbox
import CoreAudio
import Dispatch
import LevelDeckKit

/// Real `AudioControlling` on top of CoreAudio (SPEC §5.2).
///
/// Listeners are registered on the main queue, so `onChange` is always delivered
/// on the main actor. When a scope's default device changes, that scope's listeners
/// move to the new device. A change in the device list (connecting or disconnecting
/// something) is notified for both scopes; if the active one disappears, the device macOS
/// picks arrives through the default listener. If `coreaudiod` restarts, all
/// listeners become invalid: `kAudioHardwarePropertyServiceRestarted` resubscribes
/// them and notifies both scopes.
@MainActor
public final class CoreAudioController: AudioControlling {
    private struct Listener {
        let id: UInt64
        let object: AudioObjectID
        let address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }

    private var onChange: (@MainActor (Scope) -> Void)?
    private var systemListeners: [Listener] = []
    private var deviceListeners: [Scope: [Listener]] = [:]
    /// Active listeners. A block the HAL still delivers after it has been removed
    /// (e.g. because the device no longer existed) is ignored.
    private var activeListeners: Set<UInt64> = []
    private var nextListenerID: UInt64 = 0

    public init() {}

    // MARK: - AudioControlling

    public func channel(_ scope: Scope) throws(AudioControlError) -> AudioChannel? {
        guard let device = try HAL.defaultDevice(scope) else { return nil }
        let volume = VolumeControl.resolve(device, scope)
        let mute = HAL.address(kAudioDevicePropertyMute, scope: scope.halScope)
        let hasMute = HAL.has(device, mute)
        var muted = false
        if hasMute {
            muted = try HAL.get(device, mute, initial: UInt32(0)) != 0
        }
        return AudioChannel(
            deviceId: try HAL.string(device, kAudioDevicePropertyDeviceUID),
            deviceName: try HAL.string(device, kAudioObjectPropertyName),
            volume: try volume.read(device),
            muted: muted,
            volumeSettable: volume.isSettable,
            muteSettable: hasMute && HAL.isSettable(device, mute)
        )
    }

    public func setVolume(_ value: Float, scope: Scope) throws(AudioControlError) {
        guard Volume.isValid(value) else { throw .invalidValue }
        guard let device = try HAL.defaultDevice(scope) else { throw .noDevice(scope) }
        let volume = VolumeControl.resolve(device, scope)
        guard volume.isSettable else { throw .notSettable(scope) }
        try volume.write(value, to: device)
    }

    public func setMute(_ muted: Bool, scope: Scope) throws(AudioControlError) {
        guard let device = try HAL.defaultDevice(scope) else { throw .noDevice(scope) }
        let mute = HAL.address(kAudioDevicePropertyMute, scope: scope.halScope)
        guard HAL.has(device, mute), HAL.isSettable(device, mute) else { throw .notSettable(scope) }
        try HAL.set(device, mute, UInt32(muted ? 1 : 0))
    }

    public func devices(_ scope: Scope) throws(AudioControlError) -> [DeviceInfo] {
        var devices: [DeviceInfo] = []
        for device in try HAL.allDevices() where Self.isSelectable(device, scope) {
            // A device that disappears mid-read is skipped; the list listener
            // notifies again right away.
            guard let uid = try? HAL.string(device, kAudioDevicePropertyDeviceUID),
                  let name = try? HAL.string(device, kAudioObjectPropertyName) else { continue }
            devices.append(DeviceInfo(id: uid, name: name))
        }
        return devices.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func setDefaultDevice(_ deviceId: String, scope: Scope) throws(AudioControlError) {
        guard let device = try HAL.device(forUID: deviceId), Self.isSelectable(device, scope) else {
            throw .deviceNotFound(scope)
        }
        try HAL.setDefaultDevice(device, scope)
    }

    /// Visible and with streams in the scope (SPEC §5.2). Virtual ones (BlackHole, Zoom, Teams)
    /// pass if they meet that.
    private static func isSelectable(_ device: AudioObjectID, _ scope: Scope) -> Bool {
        HAL.hasStreams(device, scope) && !HAL.isHidden(device)
    }

    public func startObserving(_ onChange: @escaping @MainActor (Scope) -> Void) {
        stopObserving()
        self.onChange = onChange
        if let listener = addServiceRestartedListener() {
            systemListeners.append(listener)
        }
        // The device list is system-wide and affects both scopes.
        if let listener = addListener(
            HAL.systemObject, HAL.address(kAudioHardwarePropertyDevices),
            scopes: Scope.allCases, defaultDeviceChanged: false
        ) {
            systemListeners.append(listener)
        }
        for scope in Scope.allCases {
            let defaultDevice = HAL.address(scope.defaultDeviceSelector)
            if let listener = addListener(HAL.systemObject, defaultDevice, scopes: [scope], defaultDeviceChanged: true) {
                systemListeners.append(listener)
            }
            subscribeToDefaultDevice(scope)
        }
    }

    public func stopObserving() {
        for listener in systemListeners {
            remove(listener)
        }
        systemListeners = []
        for scope in Scope.allCases {
            unsubscribeFromDevice(scope)
        }
        onChange = nil
    }

    // MARK: - Listeners

    private func handleChange(_ scopes: [Scope], defaultDeviceChanged: Bool, listener: UInt64) {
        guard onChange != nil, activeListeners.contains(listener) else { return }
        for scope in scopes {
            if defaultDeviceChanged {
                subscribeToDefaultDevice(scope)
            }
            onChange?(scope)
        }
    }

    /// `coreaudiod` restarted: the old listeners no longer exist on the HAL side.
    private func serviceRestarted(listener: UInt64) {
        guard let onChange, activeListeners.contains(listener) else { return }
        startObserving(onChange)
        for scope in Scope.allCases {
            onChange(scope)
        }
    }

    private func addServiceRestartedListener() -> Listener? {
        nextListenerID += 1
        let id = nextListenerID
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.serviceRestarted(listener: id)
            }
        }
        var address = HAL.address(kAudioHardwarePropertyServiceRestarted)
        guard AudioObjectAddPropertyListenerBlock(HAL.systemObject, &address, DispatchQueue.main, block) == noErr else {
            return nil
        }
        activeListeners.insert(id)
        return Listener(id: id, object: HAL.systemObject, address: address, block: block)
    }

    /// Listens to volume and mute on the scope's current default device.
    private func subscribeToDefaultDevice(_ scope: Scope) {
        unsubscribeFromDevice(scope)
        guard let device = try? HAL.defaultDevice(scope) else { return }
        let mute = HAL.address(kAudioDevicePropertyMute, scope: scope.halScope)
        let addresses = VolumeControl.resolve(device, scope).addresses + (HAL.has(device, mute) ? [mute] : [])
        deviceListeners[scope] = addresses.compactMap {
            addListener(device, $0, scopes: [scope], defaultDeviceChanged: false)
        }
    }

    private func unsubscribeFromDevice(_ scope: Scope) {
        for listener in deviceListeners[scope] ?? [] {
            remove(listener)
        }
        deviceListeners[scope] = nil
    }

    private func addListener(
        _ object: AudioObjectID, _ address: AudioObjectPropertyAddress,
        scopes: [Scope], defaultDeviceChanged: Bool
    ) -> Listener? {
        nextListenerID += 1
        let id = nextListenerID
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.handleChange(scopes, defaultDeviceChanged: defaultDeviceChanged, listener: id)
            }
        }
        var address = address
        guard AudioObjectAddPropertyListenerBlock(object, &address, DispatchQueue.main, block) == noErr else {
            return nil
        }
        activeListeners.insert(id)
        return Listener(id: id, object: object, address: address, block: block)
    }

    private func remove(_ listener: Listener) {
        activeListeners.remove(listener.id)
        var address = listener.address
        // Fails if the device is already gone (e.g. it was disconnected); nothing to clean up.
        _ = AudioObjectRemovePropertyListenerBlock(listener.object, &address, DispatchQueue.main, listener.block)
    }
}
