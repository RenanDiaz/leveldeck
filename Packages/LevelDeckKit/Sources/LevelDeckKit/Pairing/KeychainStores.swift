import Foundation
import Security

/// Ítems `kSecClassGenericPassword` de un servicio, uno por cuenta, con el valor en JSON.
///
/// Usa el Keychain de protección de datos (`kSecUseDataProtectionKeychain`) en ambas
/// plataformas: en macOS evita los diálogos del llavero de login al re-firmar el binario en
/// cada build, a cambio de exigir que la app esté firmada con un equipo de desarrollo. Los
/// ítems no migran a otro dispositivo (`ThisDeviceOnly`): la identidad es por dispositivo.
@MainActor
final class KeychainRecords<Record: Codable> {
    private let service: String

    init(service: String) {
        self.service = service
    }

    func loadAll() throws -> [Record] {
        var query = baseQuery()
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        try check(status, "SecItemCopyMatching")
        let items = (result as? [Data]) ?? (result as? Data).map { [$0] } ?? []
        return try items.map { data in
            do {
                return try JSONDecoder().decode(Record.self, from: data)
            } catch {
                throw PairingStoreError(.corrupted, detail: "\(service): \(error)")
            }
        }
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
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
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
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    private func check(_ status: OSStatus, _ operation: String) throws {
        guard status == errSecSuccess else {
            let message = SecCopyErrorMessageString(status, nil).map { $0 as String } ?? ""
            throw PairingStoreError(.keychain(status: status), detail: "\(operation) (\(service)): \(status) \(message)")
        }
    }
}

/// Keychain de la Mac (SPEC §7): un ítem por iPhone emparejado y otro con el `agentId`.
@MainActor
public final class KeychainPairedDeviceStore: PairedDeviceStore {
    private let devices: KeychainRecords<PairedDeviceRecord>
    private let identity: KeychainRecords<String>
    private static let identityAccount = "agentId"

    /// - Parameter service: prefijo de los servicios del Keychain; por defecto el bundle ID del agente.
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

/// Keychain del iPhone (SPEC §7): un ítem por Mac emparejada.
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
