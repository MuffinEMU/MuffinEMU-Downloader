import SwiftUI
import WUDCore

struct ContentView: View {
    var body: some View {
        TabView {
            TitleListView()
                .tabItem { Label("Browse", systemImage: "square.grid.2x2") }

            QueueView()
                .tabItem { Label("Queue", systemImage: "arrow.down.circle") }

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}
