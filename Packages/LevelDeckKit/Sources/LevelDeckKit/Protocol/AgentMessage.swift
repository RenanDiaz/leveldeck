/// Mensajes Agente → Cliente (SPEC §8).
public enum AgentMessage: Sendable, Equatable {
    case state(StateSnapshot, version: Int = ProtocolVersion.current)
    case error(code: ErrorCode, message: String)
}

extension AgentMessage: Codable {
    private enum MessageType: String, Codable {
        case state, error
    }

    private enum CodingKeys: String, CodingKey {
        case type, v, output, input, devices, code, message
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(MessageType.self, forKey: .type) {
        case .state:
            let snapshot = StateSnapshot(
                output: try container.decode(ChannelState.self, forKey: .output),
                input: try container.decode(ChannelState.self, forKey: .input),
                devices: try container.decode(DeviceList.self, forKey: .devices)
            )
            self = .state(snapshot, version: try container.decode(Int.self, forKey: .v))
        case .error:
            self = .error(
                code: try container.decode(ErrorCode.self, forKey: .code),
                message: try container.decode(String.self, forKey: .message)
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .state(snapshot, version):
            // Payload plano: los campos del snapshot van al mismo nivel que `type`.
            try container.encode(MessageType.state, forKey: .type)
            try container.encode(version, forKey: .v)
            try container.encode(snapshot.output, forKey: .output)
            try container.encode(snapshot.input, forKey: .input)
            try container.encode(snapshot.devices, forKey: .devices)
        case let .error(code, message):
            try container.encode(MessageType.error, forKey: .type)
            try container.encode(code, forKey: .code)
            try container.encode(message, forKey: .message)
        }
    }
}
