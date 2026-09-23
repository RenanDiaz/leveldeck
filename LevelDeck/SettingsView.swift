import LevelDeckKit
import SwiftUI

/// Ajustes (SPEC §6.1): Macs emparejadas con opción de olvidar, y versión.
struct SettingsView: View {
    let pairedAgents: PairedAgents

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if pairedAgents.agents.isEmpty {
                        Text("No paired Macs yet.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(pairedAgents.agents) { agent in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(agent.name)
                            Text("Paired \(agent.pairedAt, format: .dateTime.day().month().year())")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .swipeActions {
                            Button("Forget", role: .destructive) {
                                pairedAgents.forget(id: agent.id)
                            }
                        }
                    }
                } header: {
                    Text("Paired Macs")
                } footer: {
                    Text("Forgetting a Mac removes its key from this iPhone. The Mac still lists this iPhone until you revoke it from its menu.")
                }
                if let error = pairedAgents.storeError {
                    Section {
                        KeychainErrorLabel(error: error)
                    }
                }
                Section {
                    LabeledContent("Version", value: Self.version)
                    LabeledContent("Protocol", value: "v\(ProtocolVersion.current)")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build))"
    }
}
