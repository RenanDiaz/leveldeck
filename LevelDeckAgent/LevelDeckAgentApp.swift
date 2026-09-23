import AgentAudio
import AgentCoreAudio
import LevelDeckKit
import SwiftUI

@main
struct LevelDeckAgentApp: App {
    @State private var audio: AudioModel
    @State private var remote: RemoteService?

    init() {
        let audio = AudioModel(controller: CoreAudioController())
        audio.start()
        _audio = State(initialValue: audio)

        let remote = AgentTransport.security.map { RemoteService(audio: audio, security: $0) }
        remote?.start()
        _remote = State(initialValue: remote)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(audio: audio, server: remote?.server)
        } label: {
            // Template image: macOS lo tiñe según el modo claro/oscuro de la barra.
            Image("MenuBarIcon")
                .accessibilityLabel("LevelDeck")
        }
        // El estilo menú no admite sliders (SPEC §5.1).
        .menuBarExtraStyle(.window)
    }
}

private struct MenuContent: View {
    let audio: AudioModel
    let server: LevelDeckServer?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ChannelControl(title: "Salida", scope: .output, audio: audio)
            ChannelControl(title: "Entrada", scope: .input, audio: audio)
            Divider()
            if let server {
                ServiceStatusView(server: server)
            } else {
                Label("Red: requiere TLS-PSK (Fase 3)", systemImage: "lock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Text("Protocolo v\(ProtocolVersion.current)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Salir") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q")
            }
        }
        .padding()
        .frame(width: 300)
    }
}
