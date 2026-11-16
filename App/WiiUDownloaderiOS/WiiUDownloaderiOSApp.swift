import SwiftUI
import WUDCore

@main
struct WiiUDownloaderiOSApp: App {
    @State private var config = AppConfig()
    @State private var downloadManager = DownloadManager()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(config)
                .environment(downloadManager)
        }
    }
}

struct RootView: View {
    @Environment(AppConfig.self) private var config

    var body: some View {
        if config.didInitialSetup {
            ContentView()
        } else {
            InitialSetupView()
        }
    }
}
