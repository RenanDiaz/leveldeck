import AgentAudio
import AudioToolbox
import CoreAudio
import Dispatch
import LevelDeckKit

/// `AudioControlling` real sobre CoreAudio (SPEC §5.2).
///
/// Los listeners se registran en la cola principal, así que `onChange` siempre se entrega
/// en el main actor. Al cambiar el dispositivo por defecto de un scope, los listeners de
/// ese scope se mueven al dispositivo nuevo.
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
    /// Listeners vigentes. Un bloque que la HAL todavía entregue después de quitarlo
    /// (p. ej. porque el dispositivo ya no existía) se ignora.
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

    public func startObserving(_ onChange: @escaping @MainActor (Scope) -> Void) {
        stopObserving()
        self.onChange = onChange
        for scope in Scope.allCases {
            let defaultDevice = HAL.address(scope.defaultDeviceSelector)
            if let listener = addListener(HAL.systemObject, defaultDevice, scope: scope, defaultDeviceChanged: true) {
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

    private func handleChange(_ scope: Scope, defaultDeviceChanged: Bool, listener: UInt64) {
        guard onChange != nil, activeListeners.contains(listener) else { return }
        if defaultDeviceChanged {
            subscribeToDefaultDevice(scope)
        }
        onChange?(scope)
    }

    /// Escucha volumen y mute del dispositivo por defecto actual del scope.
    private func subscribeToDefaultDevice(_ scope: Scope) {
        unsubscribeFromDevice(scope)
        guard let device = try? HAL.defaultDevice(scope) else { return }
        let mute = HAL.address(kAudioDevicePropertyMute, scope: scope.halScope)
        let addresses = VolumeControl.resolve(device, scope).addresses + (HAL.has(device, mute) ? [mute] : [])
        deviceListeners[scope] = addresses.compactMap {
            addListener(device, $0, scope: scope, defaultDeviceChanged: false)
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
        scope: Scope, defaultDeviceChanged: Bool
    ) -> Listener? {
        nextListenerID += 1
        let id = nextListenerID
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.handleChange(scope, defaultDeviceChanged: defaultDeviceChanged, listener: id)
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
        // Falla si el dispositivo ya desapareció (p. ej. se desconectó); no hay nada que limpiar.
        _ = AudioObjectRemovePropertyListenerBlock(listener.object, &address, DispatchQueue.main, listener.block)
    }
}
