import Foundation
@preconcurrency import Network
import Observation

/// Descubre agentes en la red local por Bonjour (`_leveldeck._tcp`), sin configurar IP.
@MainActor
@Observable
public final class ServiceBrowser {
    public struct Agent: Identifiable, Hashable {
        public let name: String
        public let endpoint: NWEndpoint
        /// `agentId` del registro TXT (SPEC §7). `nil` si el agente no lo anuncia.
        public let agentID: String?
        public var id: String { name }
    }

    public enum Status: Equatable, Sendable {
        case idle
        case browsing
        /// En iOS, típicamente el permiso de red local denegado.
        case waiting(NetworkIssue)
        case failed(NetworkIssue)
    }

    public private(set) var agents: [Agent] = []
    public private(set) var status: Status = .idle

    @ObservationIgnored private var browser: NWBrowser?

    public init() {}

    public func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(
            for: .bonjour(type: LevelDeckService.bonjourType, domain: nil),
            using: NWParameters()
        )
        browser.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.stateChanged(state) }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated { self?.update(results) }
        }
        self.browser = browser
        status = .browsing
        browser.start(queue: .main)
    }

    public func stop() {
        browser?.cancel()
        browser = nil
        agents = []
        status = .idle
    }

    private func stateChanged(_ state: NWBrowser.State) {
        switch state {
        case .ready:
            status = .browsing
        case let .waiting(error):
            status = .waiting(NetworkIssue(error))
        case let .failed(error):
            browser?.cancel()
            browser = nil
            status = .failed(NetworkIssue(error))
        default:
            break
        }
    }

    private func update(_ results: Set<NWBrowser.Result>) {
        // La misma Mac puede aparecer por varias interfaces; se queda una entrada por nombre.
        var byName: [String: Agent] = [:]
        for result in results {
            guard case let .service(name, _, _, _) = result.endpoint, byName[name] == nil else { continue }
            var agentID: String?
            if case let .bonjour(txt) = result.metadata {
                agentID = txt.dictionary[LevelDeckService.txtAgentIDKey]
            }
            byName[name] = Agent(name: name, endpoint: result.endpoint, agentID: agentID)
        }
        agents = byName.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}
