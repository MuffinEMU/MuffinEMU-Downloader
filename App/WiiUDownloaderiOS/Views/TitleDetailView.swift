import SwiftUI
import WUDCore

struct TitleDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(AppConfig.self) private var config
    let entry: TitleEntry
    let database: [TitleEntry]
    let isQueued: Bool
    let onAdd: (TitleEntry) -> Void

    private enum VersionChoice: Hashable {
        case latest
        case known(Int)
        case custom
    }

    @State private var versionChoice: VersionChoice = .latest
    @State private var customVersion = ""
    @State private var sizeState: SizeState = .idle
    @State private var synopsisExpanded = false
    @State private var queuedRelated: Set<UInt64> = []

    private enum SizeState: Equatable {
        case idle, loading, loaded(UInt64), failed
    }

    private var info: GameInfo? { TitleMetadata.shared.info(for: entry.titleID) }
    private var knownVersions: [Int] { TitleMetadata.shared.knownVersions(for: entry.titleID) }

    /// nil = invalid custom entry; versionLatest = latest.
    private var selectedVersion: Int? {
        switch versionChoice {
        case .latest: return versionLatest
        case .known(let v): return v
        case .custom:
            guard let v = Int(customVersion.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "vV"))),
                  v >= 0, v <= 0xFFFF else { return nil }
            return v
        }
    }

    private var related: [TitleEntry] {
        guard config.suggestRelatedContent else { return [] }
        return [TitleIDHigh.game, TitleIDHigh.update, TitleIDHigh.dlc].compactMap {
            $0 == TitleDatabaseHelpers.titleIDHigh(entry.titleID) ? nil :
                TitleDatabaseHelpers.findRelatedTitle(for: entry, targetHigh: $0, in: database)
        } + relatedUpdateFallback
    }

    /// Updates aren't in the NUS title list, but every game's update lives at 0005000E-<low>.
    private var relatedUpdateFallback: [TitleEntry] {
        guard config.suggestRelatedContent,
              TitleDatabaseHelpers.titleIDHigh(entry.titleID) == TitleIDHigh.game,
              TitleDatabaseHelpers.findRelatedTitle(for: entry, targetHigh: TitleIDHigh.update, in: database) == nil
        else { return [] }
        let updateID = (UInt64(TitleIDHigh.update) << 32) | (entry.titleID & 0xFFFF_FFFF)
        guard !TitleMetadata.shared.knownVersions(for: updateID).isEmpty else { return [] }
        return [TitleEntry(name: entry.name, titleID: updateID, region: entry.region, key: 0, category: .update)]
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    header

                    versionSection
                        .padding(.horizontal)

                    Button {
                        guard let version = selectedVersion else { return }
                        var queued = entry
                        queued.version = version
                        onAdd(queued)
                        dismiss()
                    } label: {
                        Label(isQueued ? "Already in queue" : "Add to Queue", systemImage: isQueued ? "checkmark" : "plus")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled((isQueued && versionChoice == .latest) || selectedVersion == nil)
                    .padding(.horizontal)

                    if let info {
                        aboutSection(info)
                            .padding(.horizontal)
                    }

                    if !related.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Related")
                                .font(.headline)
                            VStack(spacing: 8) {
                                ForEach(related) { item in
                                    RelatedRow(entry: item, isQueued: queuedRelated.contains(item.titleID)) {
                                        onAdd(item)
                                        queuedRelated.insert(item.titleID)
                                        Haptics.tap()
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                    }

                    Spacer(minLength: 12)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .task(id: selectedVersion) { await fetchSize() }
        }
        .presentationDetents([.medium, .large])
    }

    private var header: some View {
        VStack(spacing: 14) {
            CoverArtView(entry: entry, width: 150, highQuality: true, enabled: config.showCoverArt)
                .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
                .padding(.top, 12)

            VStack(spacing: 4) {
                Text(entry.name.isEmpty ? (info?.title ?? entry.titleIDHex) : entry.name)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text(entry.titleIDHex)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .padding(.horizontal)

            HStack(spacing: 10) {
                InfoChip(label: Theme.label(for: entry.category), color: Theme.color(for: entry.category))
                InfoChip(label: TitleDatabaseHelpers.formattedRegion(entry.region), color: .secondary)
                InfoChip(label: TitleDatabaseHelpers.formattedKind(forTitleID: entry.titleID), color: .secondary)
            }
        }
    }

    private var versionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Version").font(.headline)
                Spacer()
                Picker("Version", selection: $versionChoice) {
                    Text("Latest").tag(VersionChoice.latest)
                    ForEach(knownVersions.reversed(), id: \.self) { v in
                        Text("v\(v)").tag(VersionChoice.known(v))
                    }
                    Text("Other…").tag(VersionChoice.custom)
                }
                .pickerStyle(.menu)
            }

            if versionChoice == .custom {
                TextField("Version code, e.g. 208", text: $customVersion)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                if !customVersion.isEmpty, selectedVersion == nil {
                    Text("Enter a valid version code.").font(.caption).foregroundStyle(.red)
                }
                Button("Look up version codes") {
                    openURL(URL(string: "https://wiiubrew.org/wiki/Title_database")!)
                }
                .font(.caption)
            }

            HStack(spacing: 6) {
                Image(systemName: "internaldrive")
                switch sizeState {
                case .idle:
                    Text(config.getSizeOnQueue ? "—" : "Size check is off in Settings")
                case .loading:
                    ProgressView().controlSize(.small)
                    Text("Fetching size…")
                case .loaded(let bytes):
                    Text(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
                case .failed:
                    Text("Couldn't fetch size")
                    Button("Retry") { Task { await fetchSize() } }
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .cardStyle()
    }

    private func aboutSection(_ info: GameInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("About").font(.headline)

            if let synopsis = info.synopsis {
                Text(synopsis)
                    .font(.callout)
                    .lineLimit(synopsisExpanded ? nil : 5)
                    .animation(.easeInOut, value: synopsisExpanded)
                Button(synopsisExpanded ? "Less" : "More") { synopsisExpanded.toggle() }
                    .font(.caption.weight(.semibold))
            }

            VStack(alignment: .leading, spacing: 4) {
                if let developer = info.developer { CreditRow(label: "Developer", value: developer) }
                if let publisher = info.publisher { CreditRow(label: "Publisher", value: publisher) }
                if let year = info.year { CreditRow(label: "Released", value: String(year)) }
                if !info.genres.isEmpty { CreditRow(label: "Genre", value: info.genres.joined(separator: ", ")) }
            }

            Button {
                openURL(URL(string: "https://www.gametdb.com/WiiU/\(info.gameTDBID)")!)
            } label: {
                Label("Details from GameTDB", systemImage: "arrow.up.right.square")
                    .font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .cardStyle()
    }

    private func fetchSize() async {
        guard config.getSizeOnQueue, let version = selectedVersion else {
            sizeState = .idle
            return
        }
        sizeState = .loading
        do {
            let size = try await Downloader().fetchTitleSize(titleIDHex: entry.titleIDHex, version: version)
            if !Task.isCancelled { sizeState = .loaded(size) }
        } catch {
            if !Task.isCancelled { sizeState = .failed }
        }
    }
}

private struct CreditRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .leading)
            Text(value)
        }
        .font(.caption)
    }
}

private struct InfoChip: View {
    let label: String
    let color: Color

    var body: some View {
        Text(label)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
    }
}

private struct RelatedRow: View {
    let entry: TitleEntry
    let isQueued: Bool
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            CategoryBadge(category: entry.category, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name.isEmpty ? entry.titleIDHex : entry.name)
                    .font(.subheadline)
                    .lineLimit(1)
                Text("\(Theme.label(for: entry.category)) · \(entry.titleIDHex)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onAdd) {
                Image(systemName: isQueued ? "checkmark.circle.fill" : "plus.circle.fill")
                    .font(.title3)
                    .foregroundStyle(isQueued ? .green : Color.accentColor)
            }
            .buttonStyle(.plain)
            .disabled(isQueued)
        }
        .padding(10)
        .cardStyle()
    }
}
