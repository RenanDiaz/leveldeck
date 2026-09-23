import Foundation

// Almacenamiento de las claves de emparejamiento (SPEC §7). Protocolos para poder usar
// memoria en los tests y el Keychain en las apps.

/// Lado de la Mac: dispositivos emparejados con su clave, y el `agentId` propio.
@MainActor
public protocol PairedDeviceStore: AnyObject {
    func loadDevices() throws -> [PairedDeviceRecord]
    /// Inserta o reemplaza por `record.device.id`.
    func save(_ record: PairedDeviceRecord) throws
    func removeDevice(id: String) throws
    func loadAgentID() throws -> String?
    func saveAgentID(_ id: String) throws
}

/// Lado del iPhone: Macs emparejadas con la clave propia para cada una.
@MainActor
public protocol PairedAgentStore: AnyObject {
    func loadAgents() throws -> [PairedAgent]
    /// Inserta o reemplaza por `agent.id`.
    func save(_ agent: PairedAgent) throws
    func removeAgent(id: String) throws
}

// MARK: - Memoria (tests y previews)

@MainActor
public final class InMemoryPairedDeviceStore: PairedDeviceStore {
    public private(set) var records: [String: PairedDeviceRecord] = [:]
    public private(set) var agentID: String?
    /// Si se fija, toda operación falla con este error (para probar el manejo de fallos).
    public var failure: PairingStoreError?

    public init() {}

    public func loadDevices() throws -> [PairedDeviceRecord] {
        try check()
        return records.values.sorted { $0.device.pairedAt < $1.device.pairedAt }
    }

    public func save(_ record: PairedDeviceRecord) throws {
        try check()
        records[record.device.id] = record
    }

    public func removeDevice(id: String) throws {
        try check()
        records[id] = nil
    }

    public func loadAgentID() throws -> String? {
        try check()
        return agentID
    }

    public func saveAgentID(_ id: String) throws {
        try check()
        agentID = id
    }

    private func check() throws {
        if let failure { throw failure }
    }
}

@MainActor
public final class InMemoryPairedAgentStore: PairedAgentStore {
    public private(set) var agents: [String: PairedAgent] = [:]
    public var failure: PairingStoreError?

    public init() {}

    public func loadAgents() throws -> [PairedAgent] {
        if let failure { throw failure }
        return agents.values.sorted { $0.pairedAt < $1.pairedAt }
    }

    public func save(_ agent: PairedAgent) throws {
        if let failure { throw failure }
        agents[agent.id] = agent
    }

    public func removeAgent(id: String) throws {
        if let failure { throw failure }
        agents[id] = nil
    }
}
