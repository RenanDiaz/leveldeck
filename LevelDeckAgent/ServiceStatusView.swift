import LevelDeckKit
import SwiftUI

/// Network service status in the menu: advertised name, port and connected clients.
/// The connection always uses TLS-PSK (SPEC §5.3).
struct ServiceStatusView: View {
    let server: LevelDeckServer

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: symbol)
                .font(.caption)
            if !server.clients.isEmpty {
                Text(server.clients.map(\.deviceName).joined(separator: ", "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            #if DEBUG
            if let issue {
                Text(verbatim: issue.detail)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }
            #endif
        }
    }

    private var title: String {
        switch server.status {
        case .stopped:
            String(localized: "Service stopped")
        case .starting:
            String(localized: "Starting service…")
        case let .ready(port):
            String(localized: "“\(server.advertisedName ?? "…")” · port \(Int(port)) · \(clientsText)")
        case .waiting:
            String(localized: "Waiting for the network…")
        case .failed:
            String(localized: "The network service couldn't start.")
        }
    }

    /// Technical detail of the network problem, if any.
    private var issue: NetworkIssue? {
        switch server.status {
        case let .waiting(issue), let .failed(issue): issue
        default: nil
        }
    }

    private var clientsText: String {
        let count = server.clients.count
        return count == 1 ? String(localized: "1 client") : String(localized: "\(count) clients")
    }

    private var symbol: String {
        switch server.status {
        case .ready: server.clients.isEmpty ? "antenna.radiowaves.left.and.right" : "iphone.radiowaves.left.and.right"
        case .starting, .waiting: "hourglass"
        case .stopped, .failed: "exclamationmark.triangle"
        }
    }
}
