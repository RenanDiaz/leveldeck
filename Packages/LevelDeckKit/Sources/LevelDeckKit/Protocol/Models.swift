/// Audio side a message applies to.
public enum Scope: String, Codable, Sendable, CaseIterable {
    case output
    case input
}

/// State of the default device for a `Scope`.
public struct ChannelState: Codable, Sendable, Equatable {
    /// Device UID (`kAudioDevicePropertyDeviceUID`), stable across restarts.
    public var deviceId: String
    public var deviceName: String
    /// Normalized to 0.0–1.0.
    public var volume: Float
    public var muted: Bool
    /// `false` if the device does not allow changing the volume (e.g. HDMI).
    public var volumeSettable: Bool
    /// `false` if the device does not allow changing mute. Evaluated separately from volume:
    /// some devices have one without the other.
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

public struct DeviceInfo: Codable, Sendable, Equatable {
    /// Device UID.
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct DeviceList: Codable, Sendable, Equatable {
    public var output: [DeviceInfo]
    public var input: [DeviceInfo]

    public init(output: [DeviceInfo], input: [DeviceInfo]) {
        self.output = output
        self.input = input
    }

    public subscript(_ scope: Scope) -> [DeviceInfo] {
        get {
            switch scope {
            case .output: output
            case .input: input
            }
        }
        set {
            switch scope {
            case .output: output = newValue
            case .input: input = newValue
            }
        }
    }
}

/// Full snapshot the agent sends in every `state` message.
public struct StateSnapshot: Codable, Sendable, Equatable {
    /// `nil` if there is no default output device. On the wire it travels as `null`.
    public var output: ChannelState?
    /// `nil` if there is no default input device (e.g. a Mac mini without a microphone).
    public var input: ChannelState?
    public var devices: DeviceList

    public init(output: ChannelState?, input: ChannelState?, devices: DeviceList) {
        self.output = output
        self.input = input
        self.devices = devices
    }

    public subscript(_ scope: Scope) -> ChannelState? {
        get {
            switch scope {
            case .output: output
            case .input: input
            }
        }
        set {
            switch scope {
            case .output: output = newValue
            case .input: input = newValue
            }
        }
    }
}

public enum ErrorCode: String, Codable, Sendable, CaseIterable {
    case unsupportedVersion
    case notSettable
    case deviceNotFound
    case invalidValue
    /// The device is not paired (or was revoked): the agent closes the session (SPEC §7).
    case notPaired
}
