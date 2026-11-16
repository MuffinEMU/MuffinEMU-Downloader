import SwiftUI
import UniformTypeIdentifiers
import WUDCore

struct SettingsView: View {
    @Environment(AppConfig.self) private var config
    /// One importer drives both pickers: SwiftUI only honors the last `.fileImporter` attached
    /// to a view, so a second modifier silently disabled the keys button.
    private enum ImportTarget { case keys, folder }
    @State private var importTarget: ImportTarget = .keys
    @State private var showImporter = false
    @State private var importResult: String?
    @State private var importSucceeded = false
    @State private var folderError: String?

    var body: some View {
        @Bindable var config = config

        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 12) {
                        HStack(spacing: 10) {
                            KeyStatusRow(name: .wiiUCommon, label: "Wii U common key")
                            KeyStatusRow(name: .vWiiCommon, label: "vWii common key")
                        }
                        HStack(spacing: 10) {
                            KeyStatusRow(name: .wiiCommon, label: "Wii common key")
                            KeyStatusRow(name: .wiiKorean, label: "Wii Korean key")
                        }
                    }
                    .padding(.vertical, 4)

                    Button {
                        importTarget = .keys
                        showImporter = true
                    } label: {
                        Label("Import keys.txt or otp.bin…", systemImage: "square.and.arrow.down")
                    }

                    if let importResult {
                        Label(importResult, systemImage: importSucceeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(importSucceeded ? .green : .red)
                    }
                } header: {
                    Text("Decryption Keys")
                } footer: {
                    Text("This app ships with no decryption keys. Import a keys.txt or otp.bin from your own console to enable decryption — any keys.txt layout works, keys are recognized by fingerprint. Browsing and downloading raw (encrypted) titles works without one.")
                }

                Section {
                    Button {
                        importTarget = .folder
                        showImporter = true
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Download Folder").foregroundStyle(.primary)
                                Text(config.downloadFolderDisplayName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        } icon: { Image(systemName: "folder.fill").foregroundStyle(.blue) }
                    }
                    if config.hasCustomDownloadFolder {
                        Button("Use App Folder Instead", role: .destructive) { config.resetDownloadFolder() }
                    }
                    if let folderError {
                        Label(folderError, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("Destination")
                } footer: {
                    Text("Each title goes in its own \"Name [Kind] [Title ID]\" folder. Pick any folder in Files — iCloud Drive, a USB drive, or another app's folder.")
                }

                Section("Downloads") {
                    Label {
                        Toggle("Decrypt after download", isOn: $config.decryptContents)
                    } icon: { Image(systemName: "lock.open.fill").foregroundStyle(.blue) }

                    Label {
                        Toggle("Delete encrypted files after decrypting", isOn: $config.deleteEncryptedContents)
                            .disabled(!config.decryptContents)
                    } icon: { Image(systemName: "trash").foregroundStyle(.red) }

                    Label {
                        Toggle("Fetch size before queueing", isOn: $config.getSizeOnQueue)
                    } icon: { Image(systemName: "ruler").foregroundStyle(.orange) }

                    Label {
                        Toggle("Keep screen on while downloading", isOn: $config.keepScreenOn)
                    } icon: { Image(systemName: "sun.max.fill").foregroundStyle(.yellow) }

                    Label {
                        Toggle("Continue queue on error", isOn: $config.continueOnError)
                    } icon: { Image(systemName: "arrow.forward.circle").foregroundStyle(.green) }

                    Label {
                        Toggle("Suggest related updates/DLC", isOn: $config.suggestRelatedContent)
                    } icon: { Image(systemName: "wand.and.stars").foregroundStyle(.purple) }
                }

                Section("Browse") {
                    Label {
                        Toggle("Show cover art", isOn: $config.showCoverArt)
                    } icon: { Image(systemName: "photo.on.rectangle").foregroundStyle(.pink) }
                }

                Section("Region Filter") {
                    RegionToggleRow(mask: $config.selectedRegion, bit: MCPRegion.usa, label: "USA", flag: "🇺🇸")
                    RegionToggleRow(mask: $config.selectedRegion, bit: MCPRegion.europe, label: "Europe", flag: "🇪🇺")
                    RegionToggleRow(mask: $config.selectedRegion, bit: MCPRegion.japan, label: "Japan", flag: "🇯🇵")
                    RegionToggleRow(mask: $config.selectedRegion, bit: MCPRegion.china, label: "China", flag: "🇨🇳")
                    RegionToggleRow(mask: $config.selectedRegion, bit: MCPRegion.korea, label: "Korea", flag: "🇰🇷")
                    RegionToggleRow(mask: $config.selectedRegion, bit: MCPRegion.taiwan, label: "Taiwan", flag: "🇹🇼")
                }

                Section {
                    Button("Re-run Setup Assistant") { config.didInitialSetup = false }
                }

                Section("About") {
                    Text("Muffin Downloader, from MuffinEMU. Created by Void. A native iOS port of WiiUDownloader (GPLv3). Downloads titles from Nintendo's public NUS/CCS servers; decryption requires your own imported keys. Cover art and descriptions come from GameTDB; version lists from WiiUBrew.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Link(destination: URL(string: "https://wiiubrew.org/wiki/Title_database")!) {
                        Label("Title database (WiiUBrew)", systemImage: "list.bullet.rectangle")
                    }
                    Link(destination: URL(string: "https://www.gametdb.com/WiiU")!) {
                        Label("GameTDB", systemImage: "photo.stack")
                    }
                }
            }
            .navigationTitle("Settings")
            .fileImporter(isPresented: $showImporter, allowedContentTypes: importTarget == .keys ? [.item] : [.folder]) { result in
                switch importTarget {
                case .keys: handleImport(result)
                case .folder: handleFolder(result)
                }
            }
        }
    }

    private func handleFolder(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            do {
                try config.setDownloadFolder(url)
                folderError = nil
            } catch {
                folderError = error.localizedDescription
            }
        case .failure(let error):
            folderError = error.localizedDescription
        }
    }

    private func handleImport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            do {
                let imported = try KeyStore.shared.importKeysFile(at: url)
                importSucceeded = true
                importResult = "Imported: \(imported.map(\.displayName).sorted().joined(separator: ", "))"
            } catch {
                importSucceeded = false
                importResult = error.localizedDescription
            }
        case .failure(let error):
            importSucceeded = false
            importResult = error.localizedDescription
        }
    }
}

private struct KeyStatusRow: View {
    let name: KeyName
    let label: String
    @State private var hasKey = false

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: hasKey ? "checkmark.seal.fill" : "questionmark.circle")
                .font(.title3)
                .foregroundStyle(hasKey ? .green : .secondary)
            Text(label)
                .font(.caption2)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: Theme.smallCornerRadius).fill(.quaternary.opacity(0.3)))
        .onAppear { hasKey = KeyStore.shared.hasKey(name) }
        .onReceive(NotificationCenter.default.publisher(for: KeyStore.didChangeNotification).receive(on: RunLoop.main)) { _ in
            withAnimation { hasKey = KeyStore.shared.hasKey(name) }
        }
    }
}

private struct RegionToggleRow: View {
    @Binding var mask: UInt8
    let bit: UInt8
    let label: String
    let flag: String

    var body: some View {
        Toggle(isOn: Binding(
            get: { mask & bit != 0 },
            set: { isOn in mask = isOn ? (mask | bit) : (mask & ~bit) }
        )) {
            Text("\(flag) \(label)")
        }
    }
}
