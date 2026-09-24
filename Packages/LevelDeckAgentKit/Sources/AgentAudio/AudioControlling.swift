import LevelDeckKit

/// State of a `Scope`'s default device, as the agent sees it.
///
/// Richer than the protocol's `ChannelState`: it distinguishes whether the volume can be changed
/// and whether mute can be changed, because some devices have one without the other.
public struct AudioChannel: Sendable, Equatable {
    /// Device UID (`kAudioDevicePropertyDeviceUID`), stable across reboots.
    public var deviceId: String
    public var deviceName: String
    /// Normalized to 0.0–1.0.
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
    /// There is no default device for the scope.
    case noDevice(Scope)
    /// The requested device doesn't exist, is hidden or has no streams in that scope
    /// (e.g. it was disconnected between the client seeing the list and selecting it).
    case deviceNotFound(Scope)
    /// The device doesn't allow changing that control.
    case notSettable(Scope)
    /// Volume outside 0.0–1.0 or `NaN`. It is not clamped.
    case invalidValue
    /// CoreAudio returned an `OSStatus` other than `noErr`.
    case coreAudio(status: Int32)
}

/// Access to system audio, parameterized by `Scope` (SPEC §5.2).
///
/// Everything runs on the main actor: HAL calls are fast, and this way listeners
/// deliver changes directly on the UI thread.
@MainActor
public protocol AudioControlling: AnyObject {
    /// Current state of the default device, or `nil` if there is none.
    func channel(_ scope: Scope) throws(AudioControlError) -> AudioChannel?
    func setVolume(_ value: Float, scope: Scope) throws(AudioControlError)
    func setMute(_ muted: Bool, scope: Scope) throws(AudioControlError)
    /// Devices that can be selected in the scope: those with streams in it that are not
    /// hidden (`kAudioDevicePropertyIsHidden`). Virtual ones (BlackHole, Zoom, Teams) count.
    /// Sorted by name.
    func devices(_ scope: Scope) throws(AudioControlError) -> [DeviceInfo]
    /// Makes the device with that UID the scope's default device.
    /// Throws `.deviceNotFound` if it isn't in `devices(scope)`.
    func setDefaultDevice(_ deviceId: String, scope: Scope) throws(AudioControlError)
    /// Starts observing changes to volume, mute, default device and device
    /// list. `onChange` receives the affected scope (a list change arrives for
    /// both); the receiver rereads that scope's channel and list.
    func startObserving(_ onChange: @escaping @MainActor (Scope) -> Void)
    func stopObserving()
}
