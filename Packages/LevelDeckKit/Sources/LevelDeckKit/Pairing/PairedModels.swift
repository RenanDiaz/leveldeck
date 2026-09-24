import Foundation

/// Paired iPhone, as seen from the Mac (SPEC §7). The key is stored separately, in the Keychain.
public struct PairedDevice: Identifiable, Equatable, Sendable, Codable {
    /// PSK identity the Mac assigned to it when pairing.
    public let id: String
    /// Name the iPhone declared in its last `hello`.
    public var name: String
    public let pairedAt: Date

    public init(id: String, name: String, pairedAt: Date) {
        self.id = id
        self.name = name
        self.pairedAt = pairedAt
    }
}

/// What the Mac persists per device: the device and its key.
public struct PairedDeviceRecord: Equatable, Sendable, Codable {
    public var device: PairedDevice
    public var key: PresharedKey

    public init(device: PairedDevice, key: PresharedKey) {
        self.device = device
        self.key = key
    }
}

/// Paired Mac, as seen from the iPhone (SPEC §7).
public struct PairedAgent: Identifiable, Equatable, Sendable, Codable {
    /// The Mac's `agentId`; matches the TXT `id` it advertises over Bonjour.
    public let id: String
    public var name: String
    /// PSK identity this Mac gave to this iPhone.
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

    /// Transport for connecting to this Mac: TLS-PSK with its own key.
    public var security: TransportSecurity {
        .tlsPSK(.single(identity: deviceID, key: key))
    }
}

/// Storage (Keychain) failure. The app builds the localized text; `detail` is diagnostic.
public struct PairingStoreError: Error, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// `SecItem*` returned an error; `status` is the `OSStatus`.
        case keychain(status: Int32)
        /// A stored record could not be decoded.
        case corrupted
    }

    public let kind: Kind
    public let detail: String

    public init(_ kind: Kind, detail: String) {
        self.kind = kind
        self.detail = detail
    }
}
