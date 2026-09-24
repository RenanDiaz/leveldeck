import AVFoundation
import LevelDeckKit
import SwiftUI
import UIKit

/// Emparejar una Mac (SPEC §7): escanear el QR, guardar la clave y hacer la primera conexión,
/// que es la que registra este iPhone en la Mac.
struct PairingView: View {
    let pairedAgents: PairedAgents
    let browser: ServiceBrowser
    let onPaired: (PairedAgent) -> Void

    @State private var flow = PairingFlow()
    @State private var camera = CameraAccess.unknown
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                switch flow.phase {
                case .scanning:
                    scanner
                case let .connecting(name):
                    ProgressView()
                        .controlSize(.large)
                    Text("Connecting to “\(name)”…")
                        .font(.headline)
                    Text("The Mac registers this iPhone on the first connection.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                case let .paired(agent):
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(.green)
                        .accessibilityHidden(true)
                    Text("Paired with “\(agent.name)”.")
                        .font(.headline)
                case let .failed(failure):
                    Image(systemName: "xmark.octagon")
                        .font(.system(size: 56))
                        .foregroundStyle(.red)
                        .accessibilityHidden(true)
                    Text(failure.message)
                        .multilineTextAlignment(.center)
                    if case let .rejected(issue?) = failure {
                        TechnicalDetail(issue: issue)
                    }
                    Button("Try Again") {
                        flow.reset()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Pair a Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        flow.cancel()
                        dismiss()
                    }
                }
            }
        }
        .interactiveDismissDisabled(flow.isBusy)
        .task { camera = await CameraAccess.request() }
        .onChange(of: flow.phase) {
            if case let .paired(agent) = flow.phase {
                onPaired(agent)
            }
        }
    }

    @ViewBuilder
    private var scanner: some View {
        switch camera {
        case .unknown:
            ProgressView()
        case .authorized:
            QRScannerView { text in
                flow.handle(scanned: text, pairedAgents: pairedAgents, browser: browser)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .frame(maxHeight: 360)
            .accessibilityLabel("Camera viewfinder")
        case .denied:
            ContentUnavailableView {
                Label("Camera access is off", systemImage: "camera.fill")
            } description: {
                Text("Allow LevelDeck to use the camera in Settings to scan the pairing code.")
            } actions: {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
            }
        case .unavailable:
            ContentUnavailableView(
                "No camera available",
                systemImage: "camera.badge.ellipsis",
                description: Text("This device can't scan the pairing code.")
            )
        }
        Text("On the Mac, choose “Pair New Device…” in the LevelDeck menu and point the camera at the code.")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        #if DEBUG
        // Sin cámara (simulador): pegar el código que la ventana del agente muestra en Debug.
        Button("Paste Code") {
            if let text = UIPasteboard.general.string {
                flow.handle(scanned: text, pairedAgents: pairedAgents, browser: browser)
            }
        }
        #endif
    }
}

/// Detalle técnico sin localizar (código de error del sistema). Solo en builds Debug.
struct TechnicalDetail: View {
    let issue: NetworkIssue

    var body: some View {
        #if DEBUG
        Text(verbatim: issue.detail)
            .font(.caption2.monospaced())
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
        #else
        EmptyView()
        #endif
    }
}

enum CameraAccess {
    case unknown, authorized, denied, unavailable

    static func request() async -> CameraAccess {
        guard AVCaptureDevice.default(for: .video) != nil else { return .unavailable }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return .authorized
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video) ? .authorized : .denied
        case .denied, .restricted:
            return .denied
        @unknown default:
            return .denied
        }
    }
}

/// Estado del emparejamiento: del QR a la primera conexión.
@MainActor
@Observable
final class PairingFlow {
    enum Failure: Equatable {
        case notAPairingCode
        case unsupportedVersion
        case macNotFound(String)
        case notPaired(String)
        case rejected(NetworkIssue?)
        case store
    }

    enum Phase: Equatable {
        case scanning
        case connecting(String)
        case paired(PairedAgent)
        case failed(Failure)
    }

    private(set) var phase: Phase = .scanning
    @ObservationIgnored private var client: LevelDeckClient?
    @ObservationIgnored private var task: Task<Void, Never>?

    var isBusy: Bool {
        if case .connecting = phase { true } else { false }
    }

    func handle(scanned text: String, pairedAgents: PairedAgents, browser: ServiceBrowser) {
        guard phase == .scanning else { return }
        let code: PairingCode
        do {
            code = try PairingCode(decoding: text)
        } catch PairingCodeError.unsupportedVersion(_) {
            phase = .failed(.unsupportedVersion)
            return
        } catch {
            phase = .failed(.notAPairingCode)
            return
        }
        let agent: PairedAgent
        do {
            agent = try pairedAgents.pair(with: code)
        } catch {
            phase = .failed(.store)
            return
        }
        phase = .connecting(agent.name)
        task = Task { [weak self] in
            await self?.connect(agent, pairedAgents: pairedAgents, browser: browser)
        }
    }

    func reset() {
        cancel()
        phase = .scanning
    }

    func cancel() {
        task?.cancel()
        task = nil
        client?.disconnect()
        client = nil
    }

    /// Espera a que la Mac aparezca por Bonjour, conecta y espera el primer `state`.
    private func connect(_ agent: PairedAgent, pairedAgents: PairedAgents, browser: ServiceBrowser) async {
        let deadline = ContinuousClock.now + .seconds(15)
        while browser.agents.first(where: { $0.agentID == agent.id }) == nil {
            guard ContinuousClock.now < deadline, !Task.isCancelled else {
                if !Task.isCancelled {
                    pairedAgents.forget(id: agent.id)
                    phase = .failed(.macNotFound(agent.name))
                }
                return
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        guard let found = browser.agents.first(where: { $0.agentID == agent.id }) else { return }
        let client = LevelDeckClient(
            endpoint: found.endpoint, security: AppTransport.security(for: agent),
            deviceName: UIDevice.current.name, deviceID: agent.deviceID
        )
        self.client = client
        client.connect()
        while !Task.isCancelled {
            switch client.status {
            case .connected:
                client.disconnect()
                self.client = nil
                phase = .paired(agent)
                return
            case let .disconnected(issue):
                self.client = nil
                pairedAgents.forget(id: agent.id)
                if client.lastError?.code == .notPaired {
                    phase = .failed(.notPaired(agent.name))
                } else {
                    phase = .failed(.rejected(issue))
                }
                return
            case .idle, .connecting, .waiting, .reconnecting:
                if ContinuousClock.now >= deadline {
                    client.disconnect()
                    self.client = nil
                    pairedAgents.forget(id: agent.id)
                    phase = .failed(.rejected(nil))
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
}

extension PairingFlow.Failure {
    var message: String {
        switch self {
        case .notAPairingCode:
            String(localized: "That code isn't a LevelDeck pairing code.")
        case .unsupportedVersion:
            String(localized: "The code comes from a newer LevelDeck Agent. Update this app.")
        case let .macNotFound(name):
            String(localized: "Couldn't find “\(name)” on the network. Make sure both devices are on the same Wi-Fi and try again.")
        case let .notPaired(name):
            String(localized: "“\(name)” didn't accept the pairing. The code may have expired: show a new one on the Mac.")
        case let .rejected(issue):
            issue?.message ?? String(localized: "Couldn't connect to the Mac to finish pairing. Show a new code and try again.")
        case .store:
            String(localized: "Couldn't save the key in the Keychain.")
        }
    }
}
