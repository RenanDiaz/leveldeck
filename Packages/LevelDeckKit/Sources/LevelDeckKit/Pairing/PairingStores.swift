import Foundation

// Storage for the pairing keys (SPEC §7). Protocols so tests can use memory and the
// apps can use the Keychain.

/// Mac side: paired devices with their key, and its own `agentId`.
@MainActor
public protocol PairedDeviceStore: AnyObject {
    func loadDevices() throws -> [PairedDeviceRecord]
    /// Inserts or replaces by `record.device.id`.
    func save(_ record: PairedDeviceRecord) throws
    func removeDevice(id: String) throws
    func loadAgentID() throws -> String?
    func saveAgentID(_ id: String) throws
}

/// iPhone side: paired Macs with its own key for each one.
@MainActor
public protocol PairedAgentStore: AnyObject {
    func loadAgents() throws -> [PairedAgent]
    /// Inserts or replaces by `agent.id`.
    func save(_ agent: PairedAgent) throws
    func removeAgent(id: String) throws
}

// MARK: - Memory (tests and previews)

@MainActor
public final class InMemoryPairedDeviceStore: PairedDeviceStore {
    public private(set) var records: [String: PairedDeviceRecord] = [:]
    public private(set) var agentID: String?
    /// If set, every operation fails with this error (to test failure handling).
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
