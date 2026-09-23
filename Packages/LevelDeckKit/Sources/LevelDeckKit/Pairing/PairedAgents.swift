import Foundation
import Observation

/// Macs emparejadas, del lado del iPhone (SPEC §7): guarda la clave del QR y la olvida.
@MainActor
@Observable
public final class PairedAgents {
    public private(set) var agents: [PairedAgent] = []
    /// Último fallo del Keychain. La app lo muestra localizado.
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

    /// Guarda la clave del QR. Volver a escanear un QR de la misma Mac reemplaza la entrada:
    /// la Mac tendrá una identidad vieja huérfana hasta que se revoque desde su menú.
    @discardableResult
    public func pair(with code: PairingCode) throws -> PairedAgent {
        let agent = PairedAgent(code: code)
        try store.save(agent)
        agents.removeAll { $0.id == agent.id }
        agents.append(agent)
        storeError = nil
        return agent
    }

    /// Olvida la Mac. La Mac sigue teniendo la identidad hasta que se revoque desde su menú.
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
