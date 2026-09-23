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
        public var id: String { name }
    }

    public enum Status: Equatable, Sendable {
        case idle
        case browsing
        /// En iOS, típicamente el permiso de red local denegado.
        case waiting(String)
        case failed(String)
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
            status = .waiting(error.localizedDescription)
        case let .failed(error):
            browser?.cancel()
            browser = nil
            status = .failed(error.localizedDescription)
        default:
            break
        }
    }

    private func update(_ results: Set<NWBrowser.Result>) {
        // La misma Mac puede aparecer por varias interfaces; se queda una entrada por nombre.
        var byName: [String: Agent] = [:]
        for result in results {
            guard case let .service(name, _, _, _) = result.endpoint, byName[name] == nil else { continue }
            byName[name] = Agent(name: name, endpoint: result.endpoint)
        }
        agents = byName.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}
