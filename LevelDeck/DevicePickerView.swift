import LevelDeckKit
import SwiftUI

/// Selector del dispositivo por defecto de un scope (SPEC §6.1). La lista viene del último
/// `state`, así que cambia en vivo al conectar o desconectar algo en la Mac.
struct DevicePickerView: View {
    let scope: Scope
    let model: MixerModel

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let devices = model.devices(scope)
        let activeID = model.channel(scope)?.deviceId

        NavigationStack {
            List {
                ForEach(devices, id: \.id) { device in
                    Button {
                        model.selectDevice(device.id, scope: scope)
                        dismiss()
                    } label: {
                        HStack {
                            Text(device.name)
                                .foregroundStyle(.primary)
                            Spacer()
                            if device.id == activeID {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                    .accessibilityAddTraits(device.id == activeID ? .isSelected : [])
                }
            }
            .overlay {
                if devices.isEmpty {
                    ContentUnavailableView(
                        "No devices",
                        systemImage: scope == .output ? "speaker.slash" : "mic.slash",
                        description: Text("Connect a device to the Mac to choose it here.")
                    )
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onChange(of: model.isConnected) {
            // Sin conexión la lista ya no es confiable y elegir no haría nada.
            if !model.isConnected {
                dismiss()
            }
        }
    }

    private var title: String {
        switch scope {
        case .output: String(localized: "Output device")
        case .input: String(localized: "Input device")
        }
    }
}
