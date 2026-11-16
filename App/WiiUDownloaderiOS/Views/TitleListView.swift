import SwiftUI
import WUDCore

struct TitleListView: View {
    @Environment(AppConfig.self) private var config
    @Environment(DownloadManager.self) private var downloadManager

    @State private var allEntries: [TitleEntry] = []
    @State private var searchText = ""
    @State private var category: TitleCategory = .game
    @State private var loadError: String?
    @State private var isLoading = false
    @State private var showAddByTitleID = false
    @State private var selectedEntry: TitleEntry?
    @State private var justAddedID: UInt64?
    @State private var databaseSource: TitleDatabaseLoader.Source?
    @State private var refreshNotice: String?

    private static let categories: [TitleCategory] = [.game, .update, .dlc, .demo, .all]

    private var filteredEntries: [TitleEntry] {
        TitleDatabaseHelpers.entries(in: allEntries, category: category)
            .filter { config.selectedRegion == 0 || $0.region & config.selectedRegion != 0 }
            .filter { TitleSearch.matches(query: searchText, titleName: $0.name, titleIDHex: $0.titleIDHex) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                CategoryPillRow(selection: $category, categories: Self.categories)

                if let refreshNotice {
                    Label(refreshNotice, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .transition(.opacity)
                }

                Group {
                    if isLoading && allEntries.isEmpty {
                        ProgressView("Loading title database…")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let loadError, allEntries.isEmpty {
                        ContentUnavailableView("Couldn't load title database", systemImage: "wifi.slash", description: Text(loadError))
                    } else if filteredEntries.isEmpty {
                        ContentUnavailableView.search(text: searchText)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 10) {
                                ForEach(filteredEntries) { entry in
                                    TitleRowView(
                                        entry: entry,
                                        showCover: config.showCoverArt,
                                        isQueued: downloadManager.queue.contains { $0.entry.titleID == entry.titleID },
                                        justAdded: justAddedID == entry.titleID
                                    ) {
                                        addToQueue(entry)
                                    } onTap: {
                                        selectedEntry = entry
                                    }
                                }
                            }
                            .padding(.horizontal)
                            .padding(.bottom, 20)
                        }
                    }
                }
            }
            .navigationTitle("Browse")
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search titles or paste a title ID")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showAddByTitleID = true } label: {
                        Image(systemName: "number")
                    }
                }
            }
            .sheet(isPresented: $showAddByTitleID) {
                AddByTitleIDView { entry in addToQueue(entry) }
            }
            .sheet(item: $selectedEntry) { entry in
                TitleDetailView(entry: entry, database: allEntries, isQueued: downloadManager.queue.contains { $0.entry.titleID == entry.titleID }) { chosen in
                    addToQueue(chosen)
                }
            }
            .task { await loadDatabase() }
            .refreshable { await refreshFromNetwork(userInitiated: true) }
        }
    }

    private func addToQueue(_ entry: TitleEntry) {
        downloadManager.add(entry)
        Haptics.tap()
        withAnimation(.snappy) { justAddedID = entry.titleID }
        Task {
            try? await Task.sleep(nanoseconds: 900_000_000)
            withAnimation { if justAddedID == entry.titleID { justAddedID = nil } }
        }
    }

    /// Shows the best local copy immediately (cached download, else the bundled snapshot),
    /// then tries the live server in the background. A network failure never blanks the list.
    private func loadDatabase() async {
        if allEntries.isEmpty {
            isLoading = true
            do {
                let local = try TitleDatabaseLoader.loadLocal()
                apply(local.entries, source: local.source)
            } catch {
                loadError = error.localizedDescription
            }
            isLoading = false
        }
        await refreshFromNetwork(userInitiated: false)
    }

    private func refreshFromNetwork(userInitiated: Bool) async {
        do {
            let result = try await TitleDatabaseLoader.refresh()
            apply(result.entries, source: result.source)
            withAnimation { refreshNotice = nil }
        } catch {
            if allEntries.isEmpty {
                loadError = error.localizedDescription
            } else if userInitiated {
                // The bundled list is complete on its own, so a failed background refresh stays
                // silent; only an explicit pull-to-refresh reports that the server is down.
                withAnimation {
                    refreshNotice = "The title database server isn't reachable, so the list wasn't updated. All titles are still available."
                }
                Task {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    withAnimation { refreshNotice = nil }
                }
            }
        }
    }

    private func apply(_ entries: [TitleEntry], source: TitleDatabaseLoader.Source) {
        allEntries = entries
        databaseSource = source
        downloadManager.setTitleDatabase(entries)
        loadError = nil
    }
}

struct TitleRowView: View {
    let entry: TitleEntry
    var showCover = true
    let isQueued: Bool
    let justAdded: Bool
    let onAdd: () -> Void
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            CoverArtView(entry: entry, width: 40, enabled: showCover)

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name.isEmpty ? entry.titleIDHex : entry.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(TitleDatabaseHelpers.formattedRegion(entry.region))
                    Text("·")
                    Text(entry.titleIDHex).font(.system(.caption2, design: .monospaced))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button(action: onAdd) {
                Image(systemName: justAdded ? "checkmark.circle.fill" : (isQueued ? "checkmark.circle.fill" : "plus.circle.fill"))
                    .symbolEffect(.bounce, value: justAdded)
                    .font(.title2)
                    .foregroundStyle(isQueued || justAdded ? .green : Color.accentColor)
            }
            .buttonStyle(.plain)
            .disabled(isQueued)
        }
        .padding(12)
        .cardStyle()
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}
