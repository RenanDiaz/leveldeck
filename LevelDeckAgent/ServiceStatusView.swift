import LevelDeckKit
import SwiftUI

/// Estado del servicio de red en el menú: nombre anunciado, puerto y clientes conectados.
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
            Text("Transporte sin cifrar (solo Debug)")
                .font(.caption2)
                .foregroundStyle(.orange)
            #endif
        }
    }

    private var title: String {
        switch server.status {
        case .stopped:
            "Servicio detenido"
        case .starting:
            "Iniciando servicio…"
        case let .ready(port):
            "“\(server.advertisedName ?? "…")” · puerto \(port) · \(clientsText)"
        case let .waiting(reason):
            "Esperando red: \(reason)"
        case let .failed(reason):
            "Error del servicio: \(reason)"
        }
    }

    private var clientsText: String {
        server.clients.count == 1 ? "1 cliente" : "\(server.clients.count) clientes"
    }

    private var symbol: String {
        switch server.status {
        case .ready: server.clients.isEmpty ? "antenna.radiowaves.left.and.right" : "iphone.radiowaves.left.and.right"
        case .starting, .waiting: "hourglass"
        case .stopped, .failed: "exclamationmark.triangle"
        }
    }
}
