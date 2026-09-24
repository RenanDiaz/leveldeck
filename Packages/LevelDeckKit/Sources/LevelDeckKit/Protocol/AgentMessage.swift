import Foundation

/// Agent → Client messages (SPEC §8).
public enum AgentMessage: Sendable, Equatable {
    /// First message of every session: the client answers with a `hello` whose `proof` signs
    /// this `nonce` (SPEC §8). The client consumes it and does not publish it.
    case challenge(nonce: Data)
    case state(StateSnapshot, version: Int = ProtocolVersion.current)
    case error(code: ErrorCode, message: String)
}

extension AgentMessage: Codable {
    private enum MessageType: String, Codable {
        case challenge, state, error
    }

    private enum CodingKeys: String, CodingKey {
        case type, v, output, input, devices, code, message, nonce
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(MessageType.self, forKey: .type) {
        case .challenge:
            let text = try container.decode(String.self, forKey: .nonce)
            guard let nonce = Data(base64URLEncoded: text), nonce.count == HelloProof.nonceByteCount else {
                throw DecodingError.dataCorruptedError(
                    forKey: .nonce, in: container,
                    debugDescription: "El nonce debe ser base64url de \(HelloProof.nonceByteCount) bytes."
                )
            }
            self = .challenge(nonce: nonce)
        case .state:
            // `null` = no device; a missing key is still a decoding error.
            let snapshot = StateSnapshot(
                output: try container.decode(ChannelState?.self, forKey: .output),
                input: try container.decode(ChannelState?.self, forKey: .input),
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
        case let .challenge(nonce):
            try container.encode(MessageType.challenge, forKey: .type)
            try container.encode(nonce.base64URLEncodedString(), forKey: .nonce)
        case let .state(snapshot, version):
            // Flat payload: the snapshot fields sit at the same level as `type`.
            try container.encode(MessageType.state, forKey: .type)
            try container.encode(version, forKey: .v)
            try encodeChannel(snapshot.output, forKey: .output, in: &container)
            try encodeChannel(snapshot.input, forKey: .input, in: &container)
            try container.encode(snapshot.devices, forKey: .devices)
        case let .error(code, message):
            try container.encode(MessageType.error, forKey: .type)
            try container.encode(code, forKey: .code)
            try container.encode(message, forKey: .message)
        }
    }

    /// Missing channel = key present with `null`, never omitted (SPEC §8).
    private func encodeChannel(
        _ channel: ChannelState?, forKey key: CodingKeys,
        in container: inout KeyedEncodingContainer<CodingKeys>
    ) throws {
        if let channel {
            try container.encode(channel, forKey: key)
        } else {
            try container.encodeNil(forKey: key)
        }
    }
}
