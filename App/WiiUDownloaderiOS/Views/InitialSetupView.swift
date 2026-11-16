import SwiftUI
import UniformTypeIdentifiers
import WUDCore

/// A short, swipeable wizard: platform preset, regions, optional key import, then a summary.
struct InitialSetupView: View {
    @Environment(AppConfig.self) private var config

    @State private var page = 0
    @State private var wantsDecryptedCemuLayout = false
    @State private var europe = true
    @State private var usa = true
    @State private var japan = true
    @State private var showImporter = false
    @State private var importMessage: String?

    private let totalPages = 4

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                WelcomePage().tag(0)
                PlatformPage(wantsDecryptedCemuLayout: $wantsDecryptedCemuLayout).tag(1)
                RegionPage(europe: $europe, usa: $usa, japan: $japan).tag(2)
                KeysPage(showImporter: $showImporter, importMessage: $importMessage).tag(3)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .animation(.easeInOut, value: page)

            HStack(spacing: 8) {
                ForEach(0..<totalPages, id: \.self) { index in
                    Capsule()
                        .fill(index == page ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: index == page ? 20 : 6, height: 6)
                        .animation(.snappy, value: page)
                }
            }
            .padding(.top, 8)

            HStack {
                if page > 0 {
                    Button("Back") { withAnimation { page -= 1 } }
                }
                Spacer()
                if page < totalPages - 1 {
                    Button("Next") { withAnimation { page += 1 } }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Get Started") { finish() }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding()
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item]) { result in
            switch result {
            case .success(let url):
                do {
                    let imported = try KeyStore.shared.importKeysFile(at: url)
                    importMessage = "Imported: \(imported.map(\.displayName).sorted().joined(separator: ", "))"
                } catch {
                    importMessage = error.localizedDescription
                }
            case .failure(let error):
                importMessage = error.localizedDescription
            }
        }
    }

    private func finish() {
        var mask: UInt8 = 0
        if usa { mask |= MCPRegion.usa }
        if europe { mask |= MCPRegion.europe }
        if japan { mask |= MCPRegion.japan }
        config.selectedRegion = mask
        config.decryptContents = wantsDecryptedCemuLayout
        config.deleteEncryptedContents = wantsDecryptedCemuLayout
        config.didInitialSetup = true
    }
}

private struct SetupPageLayout<Content: View>: View {
    let icon: String
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: icon)
                    .font(.system(size: 56))
                    .foregroundStyle(Theme.accentGradient)
                    .padding(.top, 40)

                VStack(spacing: 6) {
                    Text(title).font(.title2.weight(.bold))
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                content
                    .padding(.horizontal)

                Spacer(minLength: 40)
            }
        }
    }
}

private struct WelcomePage: View {
    var body: some View {
        SetupPageLayout(icon: "arrow.down.circle.fill", title: "Muffin Downloader", subtitle: "Browse and download Wii U titles straight from Nintendo's own servers.") {
            EmptyView()
        }
    }
}

private struct PlatformPage: View {
    @Binding var wantsDecryptedCemuLayout: Bool

    var body: some View {
        SetupPageLayout(icon: "square.stack.3d.up.fill", title: "What's this for?", subtitle: "This changes the default output format — you can change it later in Settings.") {
            VStack(spacing: 12) {
                PlatformOption(title: "Wii U console", subtitle: "Keep downloads in raw NUS format", icon: "gamecontroller.fill", isSelected: !wantsDecryptedCemuLayout) {
                    wantsDecryptedCemuLayout = false
                }
                PlatformOption(title: "Cemu / decrypted", subtitle: "Decrypt automatically after downloading", icon: "desktopcomputer", isSelected: wantsDecryptedCemuLayout) {
                    wantsDecryptedCemuLayout = true
                }
            }
        }
    }
}

private struct PlatformOption: View {
    let title: String
    let subtitle: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.title2)
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            }
            .padding()
            .cardStyle()
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }
}

private struct RegionPage: View {
    @Binding var europe: Bool
    @Binding var usa: Bool
    @Binding var japan: Bool

    var body: some View {
        SetupPageLayout(icon: "globe", title: "Regions", subtitle: "Which regions should show up when you browse?") {
            VStack(spacing: 10) {
                RegionOption(flag: "🇺🇸", label: "USA", isOn: $usa)
                RegionOption(flag: "🇪🇺", label: "Europe", isOn: $europe)
                RegionOption(flag: "🇯🇵", label: "Japan", isOn: $japan)
            }
        }
    }
}

private struct RegionOption: View {
    let flag: String
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Text("\(flag) \(label)").font(.headline)
        }
        .padding()
        .cardStyle()
        .toggleStyle(.switch)
    }
}

private struct KeysPage: View {
    @Binding var showImporter: Bool
    @Binding var importMessage: String?

    var body: some View {
        SetupPageLayout(icon: "key.fill", title: "Decryption Keys", subtitle: "Optional — only needed if you want to decrypt downloads. Nothing is bundled with this app.") {
            VStack(spacing: 12) {
                Button {
                    showImporter = true
                } label: {
                    Label("Import keys.txt or otp.bin…", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.bordered)

                if let importMessage {
                    let ok = importMessage.hasPrefix("Imported")
                    Label(importMessage, systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(ok ? .green : .red)
                }

                Text("You can do this later from Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
