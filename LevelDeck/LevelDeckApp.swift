import LevelDeckKit
import SwiftUI

@main
struct LevelDeckApp: App {
    @State private var pairedAgents = PairedAgents(store: KeychainPairedAgentStore())

    var body: some Scene {
        WindowGroup {
            ContentView(pairedAgents: pairedAgents)
        }
    }
}
