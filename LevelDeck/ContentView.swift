import LevelDeckKit
import SwiftUI

struct ContentView: View {
    var body: some View {
        ContentUnavailableView(
            "LevelDeck",
            systemImage: "slider.vertical.3",
            description: Text("Protocolo v\(ProtocolVersion.current)")
        )
    }
}

#Preview {
    ContentView()
}
