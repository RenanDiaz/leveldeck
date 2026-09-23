import CoreImage.CIFilterBuiltins
import LevelDeckKit
import SwiftUI

/// Ventana con el QR de emparejamiento (SPEC §7): expira a los 2 minutos, confirma cuando el
/// iPhone se registra y, al cerrarse, descarta la clave pendiente.
struct PairingWindowView: View {
    static let windowID = "pairing"

    let remote: RemoteService

    @Environment(\.dismiss) private var dismiss

    private var pairing: PairingManager { remote.pairing }

    var body: some View {
        VStack(spacing: 16) {
            if let device = pairing.lastPaired, pairing.pending == nil {
                paired(device)
            } else if let pending = pairing.pending {
                code(pending)
            } else if let error = pairing.storeError {
                failed(error)
            } else {
                expired
            }
        }
        .padding(24)
        .frame(width: 360)
        .onDisappear {
            // Cerrar la ventana sin emparejar descarta la clave pendiente.
            pairing.cancelPairing()
        }
    }

    private func code(_ pending: PairingManager.Pending) -> some View {
        VStack(spacing: 12) {
            Text("Scan this code with LevelDeck on your iPhone.")
                .font(.headline)
                .multilineTextAlignment(.center)
            QRCodeView(text: pending.code.encoded())
                .frame(width: 240, height: 240)
                .accessibilityLabel("Pairing QR code")
            Text("Expires in \(Text(timerInterval: min(Date.now, pending.expiresAt)...pending.expiresAt, countsDown: true))")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            Text("Open LevelDeck on the iPhone, tap Pair and point the camera at this code. The key never leaves this screen.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            #if DEBUG
            // Sin cámara (simulador): el código se puede copiar y pegar en el iPhone.
            Text(verbatim: pending.code.encoded())
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
                .lineLimit(3)
                .truncationMode(.middle)
            #endif
            Button("Cancel") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
        }
    }

    private func paired(_ device: PairedDevice) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            Text("“\(device.name)” is now paired.")
                .font(.headline)
                .multilineTextAlignment(.center)
            Text("It will connect automatically from now on. You can revoke it from the menu.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Done") {
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    /// El iPhone pasó el handshake pero la Mac no pudo guardar la clave: no se empareja.
    private func failed(_ error: PairingStoreError) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "key.slash")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text("Couldn't save the pairing in the Keychain.")
                .font(.headline)
                .multilineTextAlignment(.center)
            Text("The iPhone was refused so it doesn't keep a key the Mac won't remember. Fix Keychain access and show a new code.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            #if DEBUG
            Text(verbatim: error.detail)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            #endif
            HStack {
                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Show a New Code") {
                    pairing.beginPairing(agentName: remote.displayName)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var expired: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.badge.xmark")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("The code expired.")
                .font(.headline)
            Text("A code is valid for 2 minutes. Show a new one and scan it with the iPhone.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack {
                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Show a New Code") {
                    pairing.beginPairing(agentName: remote.displayName)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}

/// QR generado con CoreImage, sin interpolar para que los módulos queden nítidos.
private struct QRCodeView: View {
    let text: String

    var body: some View {
        if let image = Self.image(for: text) {
            Image(nsImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .padding(8)
                .background(.white, in: RoundedRectangle(cornerRadius: 8))
        } else {
            ContentUnavailableView("Couldn't generate the QR code.", systemImage: "qrcode")
        }
    }

    private static func image(for text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let representation = NSCIImageRep(ciImage: output)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }
}
