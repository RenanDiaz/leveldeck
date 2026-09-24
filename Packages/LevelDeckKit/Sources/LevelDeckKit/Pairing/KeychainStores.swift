import Foundation
import Security

/// `kSecClassGenericPassword` items for one service, one per account, with the value as JSON.
///
/// - iOS: data protection Keychain, with `ThisDeviceOnly` (the identity is per device
///   and does not migrate with a backup).
/// - macOS: classic login keychain. The data protection one requires the
///   `keychain-access-groups` entitlement with a provisioning profile, which a Personal Team
///   does not grant (`SecItemUpdate` fails with `errSecMissingEntitlement`). The login keychain
///   only prompts if the agent's signing identity changes; with the same team it stays quiet.
#if os(macOS)
private let usesDataProtectionKeychain = false
#else
private let usesDataProtectionKeychain = true
#endif

@MainActor
final class KeychainRecords<Record: Codable> {
    private let service: String

    init(service: String) {
        self.service = service
    }

    /// In two steps: the macOS login keychain does not support `kSecReturnData` with
    /// `kSecMatchLimitAll` (it returns `errSecParam`), so the accounts are listed first
    /// and then each one is read.
    func loadAll() throws -> [Record] {
        try accounts().compactMap { account -> Record? in
            guard let data = try readData(account: account) else { return nil }
            do {
                return try JSONDecoder().decode(Record.self, from: data)
            } catch {
                throw PairingStoreError(.corrupted, detail: "\(service): \(error)")
            }
        }
    }

    private func accounts() throws -> [String] {
        var query = baseQuery()
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        try check(status, "SecItemCopyMatching")
        let items = (result as? [[String: Any]]) ?? (result as? [String: Any]).map { [$0] } ?? []
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    /// `nil` if the item disappeared between listing and reading.
    private func readData(account: String) throws -> Data? {
        var query = baseQuery()
        query[kSecAttrAccount as String] = account
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status, "SecItemCopyMatching")
        return result as? Data
    }

    func save(_ record: Record, account: String) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(record)
        } catch {
            throw PairingStoreError(.corrupted, detail: "\(service): \(error)")
        }
        var query = baseQuery()
        query[kSecAttrAccount as String] = account
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query
            attributes[kSecValueData as String] = data
            if usesDataProtectionKeychain {
                attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            }
            try check(SecItemAdd(attributes as CFDictionary, nil), "SecItemAdd")
            return
        }
        try check(status, "SecItemUpdate")
    }

    func remove(account: String) throws {
        var query = baseQuery()
        query[kSecAttrAccount as String] = account
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecItemNotFound { return }
        try check(status, "SecItemDelete")
    }

    private func baseQuery() -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        if usesDataProtectionKeychain {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }

    private func check(_ status: OSStatus, _ operation: String) throws {
        guard status == errSecSuccess else {
            let message = SecCopyErrorMessageString(status, nil).map { $0 as String } ?? ""
            throw PairingStoreError(.keychain(status: status), detail: "\(operation) (\(service)): \(status) \(message)")
        }
    }
}

/// Mac Keychain (SPEC §7): one item per paired iPhone and another with the `agentId`.
@MainActor
public final class KeychainPairedDeviceStore: PairedDeviceStore {
    private let devices: KeychainRecords<PairedDeviceRecord>
    private let identity: KeychainRecords<String>
    static let identityAccount = "agentId"

    /// - Parameter service: prefix for the Keychain services; defaults to the agent's bundle ID.
    public init(service: String = "com.renandiaz.LevelDeckAgent") {
        devices = KeychainRecords(service: service + ".pairedDevices")
        identity = KeychainRecords(service: service + ".identity")
    }

    public func loadDevices() throws -> [PairedDeviceRecord] {
        try devices.loadAll().sorted { $0.device.pairedAt < $1.device.pairedAt }
    }

    public func save(_ record: PairedDeviceRecord) throws {
        try devices.save(record, account: record.device.id)
    }

    public func removeDevice(id: String) throws {
        try devices.remove(account: id)
    }

    public func loadAgentID() throws -> String? {
        try identity.loadAll().first
    }

    public func saveAgentID(_ id: String) throws {
        try identity.save(id, account: Self.identityAccount)
    }
}

/// iPhone Keychain (SPEC §7): one item per paired Mac.
@MainActor
public final class KeychainPairedAgentStore: PairedAgentStore {
    private let agents: KeychainRecords<PairedAgent>

    public init(service: String = "com.renandiaz.LevelDeck") {
        agents = KeychainRecords(service: service + ".pairedAgents")
    }

    public func loadAgents() throws -> [PairedAgent] {
        try agents.loadAll().sorted { $0.pairedAt < $1.pairedAt }
    }

    public func save(_ agent: PairedAgent) throws {
        try agents.save(agent, account: agent.id)
    }

    public func removeAgent(id: String) throws {
        try agents.remove(account: id)
    }
}
