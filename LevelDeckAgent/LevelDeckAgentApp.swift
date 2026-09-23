import LevelDeckKit
import SwiftUI

@main
struct LevelDeckAgentApp: App {
    var body: some Scene {
        MenuBarExtra("LevelDeck", systemImage: "slider.vertical.3") {
            Text("LevelDeck · protocolo v\(ProtocolVersion.current)")
            Divider()
            Button("Salir") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}
