import Foundation
import Observation

/// Paired Macs, on the iPhone side (SPEC §7): stores the key from the QR and forgets it.
@MainActor
@Observable
public final class PairedAgents {
    public private(set) var agents: [PairedAgent] = []
    /// Last Keychain failure. The app shows it localized.
    public private(set) var storeError: PairingStoreError?

    private let store: any PairedAgentStore

    public init(store: any PairedAgentStore) {
        self.store = store
        do {
            agents = try store.loadAgents()
        } catch {
            record(error)
        }
    }

    public func agent(id: String) -> PairedAgent? {
        agents.first { $0.id == id }
    }

    /// Stores the key from the QR. Scanning a QR from the same Mac again replaces the entry:
    /// the Mac will keep an orphaned old identity until it is revoked from its menu.
    @discardableResult
    public func pair(with code: PairingCode) throws -> PairedAgent {
        let agent = PairedAgent(code: code)
        try store.save(agent)
        agents.removeAll { $0.id == agent.id }
        agents.append(agent)
        storeError = nil
        return agent
    }

    /// Forgets the Mac. The Mac keeps the identity until it is revoked from its menu.
    public func forget(id: String) {
        do {
            try store.removeAgent(id: id)
        } catch {
            record(error)
            return
        }
        agents.removeAll { $0.id == id }
    }

    private func record(_ error: any Error) {
        storeError = error as? PairingStoreError
            ?? PairingStoreError(.corrupted, detail: String(describing: error))
    }
}
