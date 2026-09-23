import LevelDeckKit
import SwiftUI

struct ContentView: View {
    var body: some View {
        if let security = AppTransport.security {
            DiscoveryView(security: security)
        } else {
            ContentUnavailableView(
                "Conexión no disponible",
                systemImage: "lock",
                description: Text("Este build no incluye transporte seguro todavía (Fase 3). Protocolo v\(ProtocolVersion.current).")
            )
        }
    }
}

#Preview {
    ContentView()
}
