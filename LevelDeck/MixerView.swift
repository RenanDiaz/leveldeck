import LevelDeckKit
import SwiftUI

/// Mixer with two vertical faders, Output and Input, each with mute (SPEC §6.1).
struct MixerView: View {
    let model: MixerModel

    var body: some View {
        VStack(spacing: 16) {
            StatusBanner(model: model)
            HStack(spacing: 24) {
                ChannelStrip(scope: .output, model: model)
                ChannelStrip(scope: .input, model: model)
            }
            #if DEBUG
            RoundTripOverlay(meter: model.roundTrip)
            #endif
        }
        .padding()
        .sensoryFeedback(.impact(weight: .light), trigger: model.hapticTick)
        .navigationTitle(model.agentName)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct StatusBanner: View {
    let model: MixerModel

    var body: some View {
        switch model.status {
        case .connected:
            if let error = model.notice {
                Label(error.localizedMessage, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        case .idle, .connecting:
            Label("Connecting…", systemImage: "antenna.radiowaves.left.and.right")
                .font(.footnote)
        case let .reconnecting(_, issue):
            // The faders stay disabled; the client retries on its own (SPEC §6.2).
            VStack(spacing: 4) {
                Label {
                    Text("Reconnecting…")
                } icon: {
                    ProgressView().controlSize(.small)
                }
                if let issue {
                    Text(issue.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    TechnicalDetail(issue: issue)
                }
            }
            .font(.footnote)
        case let .waiting(issue):
            VStack(spacing: 4) {
                Label("Waiting for the local network", systemImage: "wifi.exclamationmark")
                Text(issue.message)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                TechnicalDetail(issue: issue)
            }
            .font(.footnote)
        case let .disconnected(issue):
            VStack(spacing: 6) {
                Label("Disconnected", systemImage: "bolt.horizontal.circle")
                if let issue {
                    Text(issue.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    TechnicalDetail(issue: issue)
                }
                Button("Reconnect") { model.connect() }
                    .buttonStyle(.borderedProminent)
            }
            .font(.footnote)
        }
    }
}

private struct ChannelStrip: View {
    let scope: Scope
    let model: MixerModel
    @State private var isChoosingDevice = false

    var body: some View {
        let channel = model.channel(scope)
        let canSetVolume = model.isConnected && (channel?.volumeSettable ?? false)
        let canSetMute = model.isConnected && (channel?.muteSettable ?? false)
        let volume = channel?.volume ?? 0
        let muted = channel?.muted ?? false

        VStack(spacing: 12) {
            Text(title).font(.headline)
            Text(Double(volume), format: .percent.precision(.fractionLength(0)))
                .font(.title3.monospacedDigit())
                .foregroundStyle(muted ? .secondary : .primary)

            VerticalFader(
                value: volume,
                isEnabled: canSetVolume,
                isDimmed: muted,
                onBegan: { model.dragBegan(scope) },
                onChanged: { model.dragChanged(scope, to: $0) },
                onEnded: { model.dragEnded(scope, at: $0) }
            )
            .frame(width: 88)
            .frame(maxHeight: .infinity)
            .accessibilityLabel(volumeLabel)

            Button {
                model.toggleMute(scope)
            } label: {
                Image(systemName: muteSymbol(muted: muted))
                    .font(.title2)
                    .frame(width: 56, height: 36)
            }
            .buttonStyle(.bordered)
            .tint(muted ? .red : .accentColor)
            .disabled(!canSetMute)
            .accessibilityLabel(muteLabel(muted: muted))

            Button {
                isChoosingDevice = true
            } label: {
                HStack(spacing: 2) {
                    Text(channel?.deviceName ?? String(localized: "No device"))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                    Image(systemName: "chevron.up.chevron.down")
                        .imageScale(.small)
                }
                .font(.caption)
                .frame(height: 32, alignment: .top)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .disabled(!model.isConnected || model.devices(scope).isEmpty)
            .accessibilityLabel(chooseDeviceLabel)
            .accessibilityValue(channel?.deviceName ?? String(localized: "No device"))

            if let channel, let note = settabilityNote(channel) {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .sheet(isPresented: $isChoosingDevice) {
            DevicePickerView(scope: scope, model: model)
        }
    }

    /// Each control is disabled separately; the text says which one can't be changed.
    private func settabilityNote(_ channel: ChannelState) -> String? {
        switch (channel.volumeSettable, channel.muteSettable) {
        case (true, true): nil
        case (false, true): String(localized: "This device doesn't allow changing the volume")
        case (true, false): String(localized: "This device doesn't allow muting")
        case (false, false): String(localized: "This device doesn't allow changing the volume or muting")
        }
    }

    private var chooseDeviceLabel: String {
        switch scope {
        case .output: String(localized: "Choose output device")
        case .input: String(localized: "Choose input device")
        }
    }

    private var title: String {
        switch scope {
        case .output: String(localized: "Output")
        case .input: String(localized: "Input")
        }
    }

    private var volumeLabel: String {
        switch scope {
        case .output: String(localized: "Output volume")
        case .input: String(localized: "Input volume")
        }
    }

    private func muteLabel(muted: Bool) -> String {
        switch (scope, muted) {
        case (.output, false): String(localized: "Mute output")
        case (.output, true): String(localized: "Unmute output")
        case (.input, false): String(localized: "Mute input")
        case (.input, true): String(localized: "Unmute input")
        }
    }

    private func muteSymbol(muted: Bool) -> String {
        switch scope {
        case .output: muted ? "speaker.slash.fill" : "speaker.wave.2.fill"
        case .input: muted ? "mic.slash.fill" : "mic.fill"
        }
    }
}

#if DEBUG
/// Debug overlay: `setVolume` → `state` RTT to check latency (Phase 2).
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
            return String(localized: "RTT: move a fader to measure")
        }
        let count = meter.samples.count
        return String(localized: "RTT \(format(last)) · avg \(format(average)) · max \(format(maximum)) · n=\(count)")
    }

    private func format(_ duration: Duration) -> String {
        String(format: "%.0f ms", duration.milliseconds)
    }
}
#endif
