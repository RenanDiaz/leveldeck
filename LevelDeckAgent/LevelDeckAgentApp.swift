import AgentAudio
import AgentCoreAudio
import LevelDeckKit
import SwiftUI

@main
struct LevelDeckAgentApp: App {
    @State private var audio: AudioModel
    @State private var remote: RemoteService
    @State private var loginItem: LoginItem
    /// Kept so it lives as long as the app does.
    private let systemEvents: SystemEvents

    init() {
        let audio = AudioModel(controller: CoreAudioController())
        audio.start()
        _audio = State(initialValue: audio)

        let remote = RemoteService(audio: audio, store: KeychainPairedDeviceStore())
        remote.start()
        _remote = State(initialValue: remote)

        // On wake or network change: re-advertise and, on wake, resubscribe
        // the CoreAudio listeners (SPEC §5.2, §5.3).
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
            // Template image: macOS tints it to match the menu bar's light/dark mode.
            Image("MenuBarIcon")
                .accessibilityLabel("LevelDeck")
        }
        // The menu style doesn't support sliders (SPEC §5.1).
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
