import Foundation

/// iPhone emparejado, visto desde la Mac (SPEC §7). La clave se guarda aparte, en el Keychain.
public struct PairedDevice: Identifiable, Equatable, Sendable, Codable {
    /// Identidad PSK que la Mac le asignó al emparejar.
    public let id: String
    /// Nombre que el iPhone declaró en su último `hello`.
    public var name: String
    public let pairedAt: Date

    public init(id: String, name: String, pairedAt: Date) {
        self.id = id
        self.name = name
        self.pairedAt = pairedAt
    }
}

/// Lo que la Mac persiste por dispositivo: el dispositivo y su clave.
public struct PairedDeviceRecord: Equatable, Sendable, Codable {
    public var device: PairedDevice
    public var key: PresharedKey

    public init(device: PairedDevice, key: PresharedKey) {
        self.device = device
        self.key = key
    }
}

/// Mac emparejada, vista desde el iPhone (SPEC §7).
public struct PairedAgent: Identifiable, Equatable, Sendable, Codable {
    /// `agentId` de la Mac; coincide con el TXT `id` que anuncia por Bonjour.
    public let id: String
    public var name: String
    /// Identidad PSK que esta Mac le dio a este iPhone.
    public let deviceID: String
    public let key: PresharedKey
    public let pairedAt: Date

    public init(id: String, name: String, deviceID: String, key: PresharedKey, pairedAt: Date) {
        self.id = id
        self.name = name
        self.deviceID = deviceID
        self.key = key
        self.pairedAt = pairedAt
    }

    public init(code: PairingCode, pairedAt: Date = .now) {
        self.init(id: code.agentID, name: code.agentName, deviceID: code.deviceID, key: code.key, pairedAt: pairedAt)
    }

    /// Transporte para conectar con esta Mac: TLS-PSK con la clave propia.
    public var security: TransportSecurity {
        .tlsPSK(.single(identity: deviceID, key: key))
    }
}

/// Fallo del almacenamiento (Keychain). La app arma el texto localizado; `detail` es diagnóstico.
public struct PairingStoreError: Error, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// `SecItem*` devolvió un error; `status` es el `OSStatus`.
        case keychain(status: Int32)
        /// Un registro guardado no se pudo decodificar.
        case corrupted
    }

    public let kind: Kind
    public let detail: String

    public init(_ kind: Kind, detail: String) {
        self.kind = kind
        self.detail = detail
    }
}
