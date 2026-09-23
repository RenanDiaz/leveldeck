import Foundation

/// Codificación JSON única para el protocolo, para que ambos lados usen la misma configuración.
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
