import LevelDeckKit
import SwiftUI
import UIKit

/// Lista de Macs encontradas por Bonjour. Al tocar una se conecta; la última usada se
/// reconecta sola al aparecer (SPEC §6.1, sin emparejamiento hasta la Fase 3).
struct DiscoveryView: View {
    let security: TransportSecurity

    @State private var browser = ServiceBrowser()
    @State private var mixer: MixerModel?
    @State private var didAutoConnect = false
    @AppStorage("lastAgentName") private var lastAgentName = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(browser.agents) { agent in
                        Button {
                            open(agent)
                        } label: {
                            Label(agent.name, systemImage: "desktopcomputer")
                        }
                    }
                } header: {
                    Text("Macs en la red")
                } footer: {
                    if let statusText {
                        Text(statusText)
                    }
                }
            }
            .overlay {
                if browser.agents.isEmpty {
                    ContentUnavailableView(
                        "Buscando Macs…",
                        systemImage: "wifi",
                        description: Text("Abre LevelDeck Agent en tu Mac, en la misma red Wi-Fi.")
                    )
                }
            }
            .navigationTitle("LevelDeck")
            .navigationDestination(isPresented: isShowingMixer) {
                if let mixer {
                    MixerView(model: mixer)
                }
            }
        }
        .onAppear { browser.start() }
        .onChange(of: browser.agents) { autoConnectIfPossible() }
    }

    private var statusText: String? {
        switch browser.status {
        case .idle, .browsing:
            nil
        case let .waiting(reason):
            "Sin acceso a la red local (\(reason)). Revisa Ajustes › Privacidad y seguridad › Red local."
        case let .failed(reason):
            "La búsqueda falló: \(reason)"
        }
    }

    private var isShowingMixer: Binding<Bool> {
        Binding {
            mixer != nil
        } set: { isShowing in
            guard !isShowing else { return }
            mixer?.disconnect()
            mixer = nil
        }
    }

    private func open(_ agent: ServiceBrowser.Agent) {
        let client = LevelDeckClient(
            endpoint: agent.endpoint, security: security, deviceName: UIDevice.current.name
        )
        let model = MixerModel(agentName: agent.name, client: client)
        model.connect()
        mixer = model
        lastAgentName = agent.name
    }

    private func autoConnectIfPossible() {
        guard !didAutoConnect, mixer == nil, !lastAgentName.isEmpty,
              let agent = browser.agents.first(where: { $0.name == lastAgentName }) else { return }
        didAutoConnect = true
        open(agent)
    }
}
