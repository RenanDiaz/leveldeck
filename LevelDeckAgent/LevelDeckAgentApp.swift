import AgentAudio
import AgentCoreAudio
import LevelDeckKit
import SwiftUI

@main
struct LevelDeckAgentApp: App {
    @State private var audio: AudioModel

    init() {
        let audio = AudioModel(controller: CoreAudioController())
        audio.start()
        _audio = State(initialValue: audio)
    }

    var body: some Scene {
        MenuBarExtra("LevelDeck", systemImage: "slider.vertical.3") {
            MenuContent(audio: audio)
        }
        // El estilo menú no admite sliders (SPEC §5.1).
        .menuBarExtraStyle(.window)
    }
}

private struct MenuContent: View {
    let audio: AudioModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ChannelControl(title: "Salida", scope: .output, audio: audio)
            ChannelControl(title: "Entrada", scope: .input, audio: audio)
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
