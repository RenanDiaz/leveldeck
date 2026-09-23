import LevelDeckKit
import SwiftUI

struct ContentView: View {
    var body: some View {
        if let security = AppTransport.security {
            DiscoveryView(security: security)
        } else {
            ContentUnavailableView(
                "Connection unavailable",
                systemImage: "lock",
                description: Text("This build doesn't include secure transport yet (phase 3). Protocol v\(ProtocolVersion.current).")
            )
        }
    }
}

#Preview {
    ContentView()
}
