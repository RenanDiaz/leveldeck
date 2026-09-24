import Foundation

/// Single JSON coding for the protocol, so both sides use the same configuration.
public enum ProtocolCoder {
    public static func encode(_ message: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(message)
    }

    public static func decode<Message: Decodable>(_ type: Message.Type, from data: Data) throws -> Message {
        try JSONDecoder().decode(type, from: data)
    }
}
