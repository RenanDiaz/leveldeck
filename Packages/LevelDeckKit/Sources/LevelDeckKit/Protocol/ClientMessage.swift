/// Mensajes Cliente → Agente (SPEC §8).
public enum ClientMessage: Sendable, Equatable {
    case hello(deviceName: String, version: Int = ProtocolVersion.current)
    case setVolume(scope: Scope, value: Float)
    case setMute(scope: Scope, muted: Bool)
    case setDefaultDevice(scope: Scope, deviceId: String)
}

extension ClientMessage: Codable {
    private enum MessageType: String, Codable {
        case hello, setVolume, setMute, setDefaultDevice
    }

    private enum CodingKeys: String, CodingKey {
        case type, v, deviceName, scope, value, muted, deviceId
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(MessageType.self, forKey: .type) {
        case .hello:
            self = .hello(
                deviceName: try container.decode(String.self, forKey: .deviceName),
                version: try container.decode(Int.self, forKey: .v)
            )
        case .setVolume:
            let value = try container.decode(Float.self, forKey: .value)
            guard Volume.isValid(value) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .value, in: container,
                    debugDescription: "El volumen debe estar en 0.0–1.0; se recibió \(value)."
                )
            }
            self = .setVolume(scope: try container.decode(Scope.self, forKey: .scope), value: value)
        case .setMute:
            self = .setMute(
                scope: try container.decode(Scope.self, forKey: .scope),
                muted: try container.decode(Bool.self, forKey: .muted)
            )
        case .setDefaultDevice:
            self = .setDefaultDevice(
                scope: try container.decode(Scope.self, forKey: .scope),
                deviceId: try container.decode(String.self, forKey: .deviceId)
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .hello(deviceName, version):
            try container.encode(MessageType.hello, forKey: .type)
            try container.encode(version, forKey: .v)
            try container.encode(deviceName, forKey: .deviceName)
        case let .setVolume(scope, value):
            guard Volume.isValid(value) else {
                throw EncodingError.invalidValue(
                    value,
                    .init(codingPath: container.codingPath + [CodingKeys.value],
                          debugDescription: "El volumen debe estar en 0.0–1.0.")
                )
            }
            try container.encode(MessageType.setVolume, forKey: .type)
            try container.encode(scope, forKey: .scope)
            try container.encode(value, forKey: .value)
        case let .setMute(scope, muted):
            try container.encode(MessageType.setMute, forKey: .type)
            try container.encode(scope, forKey: .scope)
            try container.encode(muted, forKey: .muted)
        case let .setDefaultDevice(scope, deviceId):
            try container.encode(MessageType.setDefaultDevice, forKey: .type)
            try container.encode(scope, forKey: .scope)
            try container.encode(deviceId, forKey: .deviceId)
        }
    }
}

public enum Volume {
    /// 0.0–1.0 inclusive. `NaN` no pasa.
    public static func isValid(_ value: Float) -> Bool {
        (0...1).contains(value)
    }
}
