import Foundation

/// Contenido del QR que muestra la Mac (SPEC §7): `leveldeck-pair:` + base64url de un JSON
/// `{ v, agentId, agentName, deviceId, key }`.
///
/// - `agentId` identifica a la Mac de forma estable (también viaja en el TXT de Bonjour).
/// - `deviceId` es la identidad que la Mac asignó a este iPhone: es la identidad PSK del
///   handshake y va en el `hello`.
/// - `key` es la PSK. Es el único secreto y solo existe en el QR y en los dos Keychains.
public struct PairingCode: Equatable, Sendable {
    public static let version = 1
    public static let prefix = "leveldeck-pair:"

    public var agentID: String
    public var agentName: String
    public var deviceID: String
    public var key: PresharedKey

    public init(agentID: String, agentName: String, deviceID: String, key: PresharedKey) {
        self.agentID = agentID
        self.agentName = agentName
        self.deviceID = deviceID
        self.key = key
    }

    /// Texto para el QR.
    public func encoded() -> String {
        let payload = Payload(v: Self.version, agentId: agentID, agentName: agentName, deviceId: deviceID, key: key)
        // Un `Payload` siempre se puede codificar: no hay valores inválidos.
        let data = (try? ProtocolCoder.encode(payload)) ?? Data()
        return Self.prefix + data.base64URLEncodedString()
    }

    /// Decodifica lo que escaneó la cámara.
    public init(decoding text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(Self.prefix) else { throw PairingCodeError.notAPairingCode }
        let body = String(trimmed.dropFirst(Self.prefix.count))
        guard let data = Data(base64URLEncoded: body),
              let payload = try? ProtocolCoder.decode(Payload.self, from: data) else {
            throw PairingCodeError.malformed
        }
        guard payload.v == Self.version else { throw PairingCodeError.unsupportedVersion(payload.v) }
        guard !payload.agentId.isEmpty, !payload.deviceId.isEmpty else { throw PairingCodeError.malformed }
        self.init(agentID: payload.agentId, agentName: payload.agentName, deviceID: payload.deviceId, key: payload.key)
    }

    private struct Payload: Codable {
        var v: Int
        var agentId: String
        var agentName: String
        var deviceId: String
        var key: PresharedKey
    }
}

public enum PairingCodeError: Error, Equatable, Sendable {
    /// El QR no es de LevelDeck.
    case notAPairingCode
    /// Tiene el prefijo pero el contenido no se entiende.
    case malformed
    /// Lo generó una versión del agente que este cliente no entiende.
    case unsupportedVersion(Int)
}
