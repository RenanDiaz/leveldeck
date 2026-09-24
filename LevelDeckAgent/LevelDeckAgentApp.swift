import AgentAudio
import AgentCoreAudio
import LevelDeckKit
import SwiftUI

@main
struct LevelDeckAgentApp: App {
    @State private var audio: AudioModel
    @State private var remote: RemoteService
    @State private var loginItem: LoginItem
    /// Se guarda para que viva lo que vive la app.
    private let systemEvents: SystemEvents

    init() {
        let audio = AudioModel(controller: CoreAudioController())
        audio.start()
        _audio = State(initialValue: audio)

        let remote = RemoteService(audio: audio, store: KeychainPairedDeviceStore())
        remote.start()
        _remote = State(initialValue: remote)

        // Al despertar o cambiar de red: volver a anunciarse y, al despertar, re-suscribir
        // los listeners de CoreAudio (SPEC §5.2, §5.3).
        systemEvents = SystemEvents(
            onWake: {
                remote.server.restartListener()
                audio.restart()
            },
            onNetworkChange: {
                remote.server.restartListener()
            }
        )
        systemEvents.start()

        let loginItem = LoginItem()
        loginItem.registerOnFirstLaunch()
        _loginItem = State(initialValue: loginItem)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(audio: audio, remote: remote, loginItem: loginItem)
        } label: {
            // Template image: macOS lo tiñe según el modo claro/oscuro de la barra.
            Image("MenuBarIcon")
                .accessibilityLabel("LevelDeck")
        }
        // El estilo menú no admite sliders (SPEC §5.1).
        .menuBarExtraStyle(.window)

        Window("Pair a New Device", id: PairingWindowView.windowID) {
            PairingWindowView(remote: remote)
        }
        .windowResizability(.contentSize)
    }
}

private struct MenuContent: View {
    let audio: AudioModel
    let remote: RemoteService
    let loginItem: LoginItem

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ChannelControl(scope: .output, audio: audio)
            ChannelControl(scope: .input, audio: audio)
            Divider()
            ServiceStatusView(server: remote.server)
            Divider()
            PairedDevicesView(pairing: remote.pairing)
            Button("Pair New Device…") {
                remote.pairing.beginPairing(agentName: remote.displayName)
                openWindow(id: PairingWindowView.windowID)
                NSApplication.shared.activate()
            }
            Divider()
            LoginItemView(loginItem: loginItem)
            Divider()
            HStack {
                Text("Protocol v\(ProtocolVersion.current)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q")
            }
        }
        .padding()
        .frame(width: 300)
    }
}
