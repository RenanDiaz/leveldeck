import LevelDeckKit

/// Estado del dispositivo por defecto de un `Scope`, tal como lo ve el agente.
///
/// Es más rico que `ChannelState` del protocolo: distingue si se puede cambiar el volumen
/// y si se puede cambiar el mute, porque hay dispositivos con uno y sin el otro.
public struct AudioChannel: Sendable, Equatable {
    /// UID del dispositivo (`kAudioDevicePropertyDeviceUID`), estable entre reinicios.
    public var deviceId: String
    public var deviceName: String
    /// Normalizado en 0.0–1.0.
    public var volume: Float
    public var muted: Bool
    public var volumeSettable: Bool
    public var muteSettable: Bool

    public init(
        deviceId: String, deviceName: String, volume: Float, muted: Bool,
        volumeSettable: Bool, muteSettable: Bool
    ) {
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.volume = volume
        self.muted = muted
        self.volumeSettable = volumeSettable
        self.muteSettable = muteSettable
    }
}

public enum AudioControlError: Error, Sendable, Equatable {
    /// No hay dispositivo por defecto para el scope.
    case noDevice(Scope)
    /// El dispositivo no permite cambiar ese control.
    case notSettable(Scope)
    /// Volumen fuera de 0.0–1.0 o `NaN`. No se recorta.
    case invalidValue
    /// CoreAudio devolvió un `OSStatus` distinto de `noErr`.
    case coreAudio(status: Int32)
}

/// Acceso al audio del sistema, parametrizado por `Scope` (SPEC §5.2).
///
/// Todo corre en el main actor: las llamadas a la HAL son rápidas y así los listeners
/// entregan los cambios directamente en el hilo de la UI.
@MainActor
public protocol AudioControlling: AnyObject {
    /// Estado actual del dispositivo por defecto, o `nil` si no hay ninguno.
    func channel(_ scope: Scope) throws(AudioControlError) -> AudioChannel?
    func setVolume(_ value: Float, scope: Scope) throws(AudioControlError)
    func setMute(_ muted: Bool, scope: Scope) throws(AudioControlError)
    /// Empieza a observar cambios de volumen, mute y dispositivo por defecto.
    /// `onChange` recibe el scope afectado; el receptor relee el canal completo.
    func startObserving(_ onChange: @escaping @MainActor (Scope) -> Void)
    func stopObserving()
}
