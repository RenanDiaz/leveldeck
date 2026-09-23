import LevelDeckKit
import SwiftUI

struct ContentView: View {
    let pairedAgents: PairedAgents

    var body: some View {
        DiscoveryView(pairedAgents: pairedAgents)
    }
}

#Preview {
    ContentView(pairedAgents: PairedAgents(store: InMemoryPairedAgentStore()))
}
