import AgentAudio
import LevelDeckKit

/// Simula el sistema de audio: guarda el estado por scope y, como la HAL real, avisa
/// del cambio después de cada escritura exitosa.
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

    /// Estado del "sistema". Sin clave = no hay dispositivo por defecto.
    var system: [Scope: AudioChannel]
    var readError: AudioControlError?
    var writeError: AudioControlError?

    private(set) var volumeCalls: [VolumeCall] = []
    private(set) var muteCalls: [MuteCall] = []
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var onChange: (@MainActor (Scope) -> Void)?

    var isObserving: Bool { onChange != nil }

    init(system: [Scope: AudioChannel] = [.output: .speakers, .input: .microphone]) {
        self.system = system
    }

    func channel(_ scope: Scope) throws(AudioControlError) -> AudioChannel? {
        if let readError { throw readError }
        return system[scope]
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

    func startObserving(_ onChange: @escaping @MainActor (Scope) -> Void) {
        startCount += 1
        self.onChange = onChange
    }

    func stopObserving() {
        stopCount += 1
        onChange = nil
    }

    /// Cambio hecho fuera del agente (teclado, Ajustes del Sistema, otro dispositivo).
    func simulateExternalChange(_ scope: Scope, _ change: (inout [Scope: AudioChannel]) -> Void) {
        change(&system)
        onChange?(scope)
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
}
