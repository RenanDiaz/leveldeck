import SwiftUI

/// Opción del menú para abrir el agente al iniciar sesión (SPEC §5.1).
struct LoginItemView: View {
    let loginItem: LoginItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Open at Login", isOn: Binding(
                get: { loginItem.status != .disabled },
                set: { loginItem.setEnabled($0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .font(.caption)

            if loginItem.status == .requiresApproval {
                Text("macOS needs your approval to open LevelDeck Agent at login.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Login Items Settings…") {
                    loginItem.openSystemSettings()
                }
                .font(.caption2)
            }

            if loginItem.failure != nil {
                Label("Couldn't change the login item.", systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                #if DEBUG
                Text(verbatim: loginItem.failure ?? "")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                #endif
            }
        }
        .onAppear { loginItem.refresh() }
    }
}
