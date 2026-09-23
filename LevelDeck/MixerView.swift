import LevelDeckKit
import SwiftUI

/// Mixer con dos faders verticales, Salida y Entrada, cada uno con mute (SPEC §6.1).
struct MixerView: View {
    let model: MixerModel

    var body: some View {
        VStack(spacing: 16) {
            StatusBanner(model: model)
            HStack(spacing: 24) {
                ChannelStrip(title: "Salida", scope: .output, model: model)
                ChannelStrip(title: "Entrada", scope: .input, model: model)
            }
            #if DEBUG
            RoundTripOverlay(meter: model.roundTrip)
            #endif
        }
        .padding()
        .navigationTitle(model.agentName)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct StatusBanner: View {
    let model: MixerModel

    var body: some View {
        switch model.status {
        case .connected:
            if let error = model.lastError {
                Label(error.message, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        case .idle, .connecting:
            Label("Conectando…", systemImage: "antenna.radiowaves.left.and.right")
                .font(.footnote)
        case let .waiting(reason):
            VStack(spacing: 4) {
                Label("Esperando la red local", systemImage: "wifi.exclamationmark")
                Text(reason).font(.caption)
                Text("Revisa Ajustes › Privacidad y seguridad › Red local.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .font(.footnote)
        case let .disconnected(reason):
            VStack(spacing: 6) {
                Label("Desconectado", systemImage: "bolt.horizontal.circle")
                if let reason {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                }
                Button("Reconectar") { model.connect() }
                    .buttonStyle(.borderedProminent)
            }
            .font(.footnote)
        }
    }
}

private struct ChannelStrip: View {
    let title: String
    let scope: Scope
    let model: MixerModel

    var body: some View {
        let channel = model.channel(scope)
        let canSetVolume = model.isConnected && (channel?.settable ?? false)
        let canSetMute = model.isConnected && (channel?.muteSettable ?? false)
        let volume = channel?.volume ?? 0

        VStack(spacing: 12) {
            Text(title).font(.headline)
            Text("\(Int((volume * 100).rounded())) %")
                .font(.title3.monospacedDigit())
                .foregroundStyle(channel?.muted == true ? .secondary : .primary)

            VerticalFader(
                value: volume,
                isEnabled: canSetVolume,
                isDimmed: channel?.muted ?? false,
                onBegan: { model.dragBegan(scope) },
                onChanged: { model.dragChanged(scope, to: $0) },
                onEnded: { model.dragEnded(scope, at: $0) }
            )
            .frame(width: 88)
            .frame(maxHeight: .infinity)
            .accessibilityLabel("Volumen de \(title.lowercased())")

            Button {
                model.toggleMute(scope)
            } label: {
                Image(systemName: muteSymbol(muted: channel?.muted ?? false))
                    .font(.title2)
                    .frame(width: 56, height: 36)
            }
            .buttonStyle(.bordered)
            .tint(channel?.muted == true ? .red : .accentColor)
            .disabled(!canSetMute)
            .accessibilityLabel(channel?.muted == true ? "Activar \(title.lowercased())" : "Silenciar \(title.lowercased())")

            Text(channel?.deviceName ?? "Sin dispositivo")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(height: 32, alignment: .top)

            if let channel, !channel.settable {
                Text("No permite cambiar el volumen")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func muteSymbol(muted: Bool) -> String {
        switch scope {
        case .output: muted ? "speaker.slash.fill" : "speaker.wave.2.fill"
        case .input: muted ? "mic.slash.fill" : "mic.fill"
        }
    }
}

#if DEBUG
/// Overlay de debug: RTT de `setVolume` → `state` para verificar la latencia (Fase 2).
private struct RoundTripOverlay: View {
    let meter: RoundTripMeter

    var body: some View {
        Text(summary)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("rtt")
    }

    private var summary: String {
        guard let last = meter.last, let average = meter.average, let maximum = meter.maximum else {
            return "RTT: mueve un fader para medir"
        }
        return "RTT \(format(last)) · prom \(format(average)) · máx \(format(maximum)) · n=\(meter.samples.count)"
    }

    private func format(_ duration: Duration) -> String {
        String(format: "%.0f ms", duration.milliseconds)
    }
}
#endif
