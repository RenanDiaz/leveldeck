import LevelDeckKit
import SwiftUI
import UIKit

/// Lista de Macs encontradas por Bonjour (SPEC §6.1). Las emparejadas se conectan solas; las
/// demás ofrecen "Emparejar" y abren la cámara.
struct DiscoveryView: View {
    let pairedAgents: PairedAgents

    @State private var browser = ServiceBrowser()
    @State private var mixer: MixerModel?
    @State private var didAutoConnect = false
    @State private var isPairing = false
    @State private var isShowingSettings = false
    @State private var unpairedAgentName: String?
    @AppStorage("lastAgentID") private var lastAgentID = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(browser.agents) { agent in
                        row(for: agent)
                    }
                } header: {
                    Text("Macs on the network")
                } footer: {
                    if let statusText {
                        Text(statusText)
                    }
                }
                if let error = pairedAgents.storeError {
                    Section {
                        KeychainErrorLabel(error: error)
                    }
                }
            }
            .overlay {
                if browser.agents.isEmpty {
                    ContentUnavailableView(
                        "Looking for Macs…",
                        systemImage: "wifi",
                        description: Text("Open LevelDeck Agent on your Mac, on the same Wi-Fi network.")
                    )
                }
            }
            .navigationTitle("LevelDeck")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isShowingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        isPairing = true
                    } label: {
                        Image(systemName: "qrcode.viewfinder")
                    }
                    .accessibilityLabel("Pair a Mac")
                }
            }
            .navigationDestination(isPresented: isShowingMixer) {
                if let mixer {
                    MixerView(model: mixer)
                }
            }
        }
        .sheet(isPresented: $isPairing) {
            PairingView(pairedAgents: pairedAgents, browser: browser) { agent in
                isPairing = false
                connect(to: agent)
            }
        }
        .sheet(isPresented: $isShowingSettings) {
            SettingsView(pairedAgents: pairedAgents)
        }
        .alert(
            "This iPhone is no longer paired",
            isPresented: Binding(get: { unpairedAgentName != nil }, set: { if !$0 { unpairedAgentName = nil } }),
            presenting: unpairedAgentName
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { name in
            Text("“\(name)” revoked this iPhone. To control it again, pair it from the Mac's menu.")
        }
        .onAppear { browser.start() }
        .onChange(of: browser.agents) { autoConnectIfPossible() }
    }

    @ViewBuilder
    private func row(for agent: ServiceBrowser.Agent) -> some View {
        if let paired = pairedAgent(for: agent) {
            Button {
                open(agent, as: paired)
            } label: {
                HStack {
                    Label(agent.name, systemImage: "desktopcomputer")
                    Spacer()
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                        .accessibilityLabel("Paired")
                }
            }
        } else {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Label(agent.name, systemImage: "desktopcomputer")
                    #if DEBUG
                    Text(verbatim: agent.agentID.map { "id \($0)" } ?? "sin TXT id")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                    #endif
                }
                Spacer()
                Button("Pair") {
                    isPairing = true
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
    }

    private var statusText: String? {
        switch browser.status {
        case .idle, .browsing:
            nil
        case let .waiting(issue), let .failed(issue):
            issue.message
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

    private func pairedAgent(for agent: ServiceBrowser.Agent) -> PairedAgent? {
        agent.agentID.flatMap { pairedAgents.agent(id: $0) }
    }

    /// Conecta con una Mac recién emparejada, si ya está en la lista; si no, se conectará
    /// sola cuando aparezca.
    private func connect(to paired: PairedAgent) {
        lastAgentID = paired.id
        didAutoConnect = false
        if let agent = browser.agents.first(where: { $0.agentID == paired.id }) {
            open(agent, as: paired)
        }
    }

    private func open(_ agent: ServiceBrowser.Agent, as paired: PairedAgent) {
        mixer?.disconnect()
        let client = LevelDeckClient(
            endpoint: agent.endpoint, security: AppTransport.security(for: paired),
            deviceName: UIDevice.current.name, deviceID: paired.deviceID
        )
        let model = MixerModel(agentName: agent.name, client: client)
        model.onUnpaired = {
            // La Mac revocó este iPhone: su clave ya no sirve.
            pairedAgents.forget(id: paired.id)
            mixer?.disconnect()
            mixer = nil
            unpairedAgentName = agent.name
        }
        model.connect()
        mixer = model
        lastAgentID = paired.id
    }

    private func autoConnectIfPossible() {
        guard !didAutoConnect, mixer == nil else { return }
        let candidates = browser.agents.compactMap { agent in
            pairedAgent(for: agent).map { (agent, $0) }
        }
        guard let candidate = candidates.first(where: { $0.1.id == lastAgentID }) ?? candidates.first else {
            return
        }
        didAutoConnect = true
        open(candidate.0, as: candidate.1)
    }
}

/// Fallo del Keychain, localizado; el detalle técnico solo en Debug (SPEC §3).
struct KeychainErrorLabel: View {
    let error: PairingStoreError

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Couldn't access the Keychain. Pairings may not be saved.", systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.orange)
            #if DEBUG
            Text(verbatim: error.detail)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
            #endif
        }
    }
}
