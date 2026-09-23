import LevelDeckKit
import SwiftUI

/// Dispositivos emparejados en el menú (SPEC §5.1, §7): nombre, si está conectado y revocar.
struct PairedDevicesView: View {
    let pairing: PairingManager

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Paired devices")
                .font(.caption)
                .foregroundStyle(.secondary)
            if pairing.devices.isEmpty {
                Text("No paired devices yet.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            ForEach(pairing.devices) { device in
                HStack(spacing: 6) {
                    Circle()
                        .fill(pairing.isConnected(device.id) ? Color.green : Color.secondary.opacity(0.4))
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                    Text(device.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(pairing.isConnected(device.id) ? String(localized: "Connected") : String(localized: "Not connected"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Button(role: .destructive) {
                        pairing.revoke(device.id)
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Revoke")
                    .accessibilityLabel("Revoke “\(device.name)”")
                }
            }
            if let error = pairing.storeError {
                KeychainErrorView(error: error)
            }
        }
    }
}

/// Fallo del Keychain, localizado; el detalle técnico solo en Debug (SPEC §3).
struct KeychainErrorView: View {
    let error: PairingStoreError

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label("Couldn't access the Keychain. Pairing won't be saved.", systemImage: "exclamationmark.triangle")
                .font(.caption2)
                .foregroundStyle(.orange)
            #if DEBUG
            Text(verbatim: error.detail)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
            #endif
        }
    }
}
