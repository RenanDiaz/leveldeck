import AgentAudio
import LevelDeckKit
import SwiftUI

/// Slider de volumen con botón de mute para un `Scope`.
/// Se deshabilita cada control por separado si el dispositivo no lo permite.
struct ChannelControl: View {
    let scope: Scope
    let audio: AudioModel

    private var channel: AudioChannel? { audio.channel(scope) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                Spacer()
                Text(channel?.deviceName ?? String(localized: "No device"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack {
                Button {
                    audio.setMute(!(channel?.muted ?? false), scope: scope)
                } label: {
                    Image(systemName: muteSymbol)
                        .frame(width: 20)
                }
                .buttonStyle(.borderless)
                .disabled(!audio.canSetMute(scope))
                .help(channel?.muted == true ? String(localized: "Unmute") : String(localized: "Mute"))

                Slider(
                    value: Binding(
                        get: { channel?.volume ?? 0 },
                        set: { audio.setVolume($0, scope: scope) }
                    ),
                    in: 0...1
                )
                .disabled(!audio.canSetVolume(scope))
            }
            if let channel, let note = settabilityNote(channel) {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func settabilityNote(_ channel: AudioChannel) -> String? {
        switch (channel.volumeSettable, channel.muteSettable) {
        case (true, true): nil
        case (false, true): String(localized: "This device doesn't allow changing the volume.")
        case (true, false): String(localized: "This device doesn't allow muting.")
        case (false, false): String(localized: "This device doesn't allow changing the volume or muting.")
        }
    }

    private var title: String {
        switch scope {
        case .output: String(localized: "Output")
        case .input: String(localized: "Input")
        }
    }

    private var muteSymbol: String {
        let muted = channel?.muted ?? false
        switch scope {
        case .output: return muted ? "speaker.slash.fill" : "speaker.wave.2.fill"
        case .input: return muted ? "mic.slash.fill" : "mic.fill"
        }
    }
}
