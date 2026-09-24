import AgentAudio
import LevelDeckKit

/// Simulates the audio system: connected devices, the default device for each
/// scope and, like the real HAL, notifies of the change after each successful write.
@MainActor
final class MockAudioController: AudioControlling {
    struct VolumeCall: Equatable {
        let value: Float
        let scope: Scope
    }

    struct MuteCall: Equatable {
        let muted: Bool
        let scope: Scope
    }

    struct DefaultDeviceCall: Equatable {
        let deviceId: String
        let scope: Scope
    }

    /// A connected device, with its channel in each scope where it has streams.
    struct Device {
        var channels: [Scope: AudioChannel]

        var id: String { channels.values.first?.deviceId ?? "" }

        init(_ channels: [Scope: AudioChannel]) {
            self.channels = channels
        }
    }

    /// Default channel of the "system". No key = no default device.
    var system: [Scope: AudioChannel]
    /// Connected devices, in connection order.
    var connected: [Device]
    var readError: AudioControlError?
    var listError: AudioControlError?
    var writeError: AudioControlError?

    private(set) var volumeCalls: [VolumeCall] = []
    private(set) var muteCalls: [MuteCall] = []
    private(set) var defaultDeviceCalls: [DefaultDeviceCall] = []
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var onChange: (@MainActor (Scope) -> Void)?

    var isObserving: Bool { onChange != nil }

    /// By default, each channel in `system` is also a connected device in its scope.
    init(system: [Scope: AudioChannel] = [.output: .speakers, .input: .microphone], connected: [Device]? = nil) {
        self.system = system
        self.connected = connected ?? Scope.allCases.compactMap { scope in
            system[scope].map { Device([scope: $0]) }
        }
    }

    func channel(_ scope: Scope) throws(AudioControlError) -> AudioChannel? {
        if let readError { throw readError }
        return system[scope]
    }

    func devices(_ scope: Scope) throws(AudioControlError) -> [DeviceInfo] {
        if let listError { throw listError }
        return connected
            .compactMap { $0.channels[scope] }
            .map { DeviceInfo(id: $0.deviceId, name: $0.deviceName) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func setVolume(_ value: Float, scope: Scope) throws(AudioControlError) {
        volumeCalls.append(VolumeCall(value: value, scope: scope))
        if let writeError { throw writeError }
        system[scope]?.volume = value
        onChange?(scope)
    }

    func setMute(_ muted: Bool, scope: Scope) throws(AudioControlError) {
        muteCalls.append(MuteCall(muted: muted, scope: scope))
        if let writeError { throw writeError }
        system[scope]?.muted = muted
        onChange?(scope)
    }

    func setDefaultDevice(_ deviceId: String, scope: Scope) throws(AudioControlError) {
        defaultDeviceCalls.append(DefaultDeviceCall(deviceId: deviceId, scope: scope))
        if let writeError { throw writeError }
        guard let channel = connected.first(where: { $0.id == deviceId })?.channels[scope] else {
            throw .deviceNotFound(scope)
        }
        saveDefault(scope)
        system[scope] = channel
        onChange?(scope)
    }

    func startObserving(_ onChange: @escaping @MainActor (Scope) -> Void) {
        startCount += 1
        self.onChange = onChange
    }

    func stopObserving() {
        stopCount += 1
        onChange = nil
    }

    /// Change made outside the agent (keyboard, System Settings, another device).
    func simulateExternalChange(_ scope: Scope, _ change: (inout [Scope: AudioChannel]) -> Void) {
        change(&system)
        onChange?(scope)
    }

    /// A device is hot-plugged. macOS doesn't change the default because of it.
    func simulatePlug(_ device: Device) {
        connected.append(device)
        notifyListChanged()
    }

    /// A device is hot-unplugged. If it was the active one for a scope, macOS picks
    /// the first one still connected in that scope (or none).
    func simulateUnplug(_ deviceId: String) {
        removeWithoutNotifying(deviceId)
        for scope in Scope.allCases where system[scope]?.deviceId == deviceId {
            system[scope] = connected.lazy.compactMap { $0.channels[scope] }.first
        }
        notifyListChanged()
    }

    /// The device disappears and the HAL hasn't notified yet: the race between the list the
    /// client saw and its tap.
    func removeWithoutNotifying(_ deviceId: String) {
        for scope in Scope.allCases { saveDefault(scope) }
        connected.removeAll { $0.id == deviceId }
    }

    /// Like the HAL: a change in `kAudioHardwarePropertyDevices` arrives for both scopes.
    private func notifyListChanged() {
        for scope in Scope.allCases {
            onChange?(scope)
        }
    }

    /// Stores the active channel's state in its device, so that when it is selected again
    /// it keeps its volume and mute.
    private func saveDefault(_ scope: Scope) {
        guard let current = system[scope],
              let index = connected.firstIndex(where: { $0.id == current.deviceId }) else { return }
        connected[index].channels[scope] = current
    }
}

extension AudioChannel {
    static let speakers = AudioChannel(
        deviceId: "BuiltInSpeakerDevice", deviceName: "MacBook Pro Speakers",
        volume: 0.62, muted: false, volumeSettable: true, muteSettable: true
    )
    static let microphone = AudioChannel(
        deviceId: "BuiltInMicrophoneDevice", deviceName: "MacBook Pro Microphone",
        volume: 0.80, muted: false, volumeSettable: true, muteSettable: true
    )
    static let hdmi = AudioChannel(
        deviceId: "HDMIDisplay", deviceName: "LG UltraFine",
        volume: 0, muted: false, volumeSettable: false, muteSettable: false
    )
    static let usbInterface = AudioChannel(
        deviceId: "AppleUSBAudioEngine:Focusrite:Scarlett", deviceName: "Scarlett 2i2",
        volume: 0.5, muted: false, volumeSettable: true, muteSettable: false
    )
    /// Display with HDMI audio: mute, but no volume.
    static let displayMuteOnly = AudioChannel(
        deviceId: "DisplayPortAudio", deviceName: "Studio Display",
        volume: 1, muted: false, volumeSettable: false, muteSettable: true
    )
    static let headsetOutput = AudioChannel(
        deviceId: "BluetoothHeadset", deviceName: "AirPods Pro",
        volume: 0.4, muted: false, volumeSettable: true, muteSettable: true
    )
    static let headsetInput = AudioChannel(
        deviceId: "BluetoothHeadset", deviceName: "AirPods Pro",
        volume: 0.7, muted: false, volumeSettable: true, muteSettable: true
    )
    /// Virtual device (BlackHole-style): only what the HAL reports about its streams.
    static let virtualLoopback = AudioChannel(
        deviceId: "BlackHole2ch_UID", deviceName: "BlackHole 2ch",
        volume: 1, muted: false, volumeSettable: false, muteSettable: false
    )
}

extension MockAudioController.Device {
    static let headset = Self([.output: .headsetOutput, .input: .headsetInput])
    static let scarlett = Self([.input: .usbInterface])
    static let hdmi = Self([.output: .hdmi])
    static let display = Self([.output: .displayMuteOnly])
}
