/// Lado del audio al que aplica un mensaje.
public enum Scope: String, Codable, Sendable, CaseIterable {
    case output
    case input
}

/// Estado del dispositivo por defecto de un `Scope`.
public struct ChannelState: Codable, Sendable, Equatable {
    /// UID del dispositivo (`kAudioDevicePropertyDeviceUID`), estable entre reinicios.
    public var deviceId: String
    public var deviceName: String
    /// Normalizado en 0.0–1.0.
    public var volume: Float
    public var muted: Bool
    /// `false` si el dispositivo no permite cambiar el volumen (p. ej. HDMI).
    public var settable: Bool

    public init(deviceId: String, deviceName: String, volume: Float, muted: Bool, settable: Bool) {
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.volume = volume
        self.muted = muted
        self.settable = settable
    }
}

public struct DeviceInfo: Codable, Sendable, Equatable {
    /// UID del dispositivo.
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
}

/// Snapshot completo que el agente envía en cada mensaje `state`.
public struct StateSnapshot: Codable, Sendable, Equatable {
    public var output: ChannelState
    public var input: ChannelState
    public var devices: DeviceList

    public init(output: ChannelState, input: ChannelState, devices: DeviceList) {
        self.output = output
        self.input = input
        self.devices = devices
    }
}

public enum ErrorCode: String, Codable, Sendable, CaseIterable {
    case unsupportedVersion
    case notSettable
    case deviceNotFound
    case invalidValue
}
