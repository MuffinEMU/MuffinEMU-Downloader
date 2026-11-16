import SwiftUI
import WUDCore

struct QueueView: View {
    @Environment(AppConfig.self) private var config
    @Environment(DownloadManager.self) private var downloadManager

    private var aggregateProgress: Double {
        let items = downloadManager.queue
        guard !items.isEmpty else { return 0 }
        let total = items.reduce(0.0) { $0 + $1.progressFraction }
        return total / Double(items.count)
    }

    /// Whole-queue estimate: bytes left in the running title, plus any queued titles whose size
    /// is already known, at the running title's current speed.
    private var queueETA: Double? {
        guard let current = downloadManager.currentItem, current.speedBytesPerSecond > 1024 else { return nil }
        let remaining = downloadManager.queue.reduce(Int64(0)) { sum, item in
            switch item.status {
            case .downloading, .queued: return sum + max(0, item.totalBytes - item.bytesDownloaded)
            default: return sum
            }
        }
        return remaining > 0 ? Double(remaining) / current.speedBytesPerSecond : nil
    }

    private var doneCount: Int {
        downloadManager.queue.filter { if case .done = $0.status { return true }; return false }.count
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if downloadManager.queue.isEmpty {
                    ContentUnavailableView("Queue is empty", systemImage: "tray", description: Text("Add titles from Browse to get started."))
                        .frame(maxHeight: .infinity)
                } else {
                    if let error = downloadManager.lastError, !downloadManager.isRunning {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal)
                            .padding(.top, 8)
                    }

                    if downloadManager.isRunning || doneCount > 0 {
                        QueueSummaryCard(progress: aggregateProgress, done: doneCount, total: downloadManager.queue.count, isPaused: downloadManager.isPaused, eta: queueETA)
                            .padding()
                    }

                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(downloadManager.queue) { item in
                                QueueRowView(item: item, showCover: config.showCoverArt) {
                                    withAnimation { downloadManager.cancel(item) }
                                }
                                    .contextMenu {
                                        if item.status == .downloading || item.status == .decrypting || item.status == .queued {
                                            Button(role: .destructive) {
                                                withAnimation { downloadManager.cancel(item) }
                                            } label: {
                                                Label("Cancel This Title", systemImage: "xmark.circle")
                                            }
                                        }
                                        if !downloadManager.isRunning || item.status != .downloading {
                                            Button(role: .destructive) {
                                                withAnimation { downloadManager.remove(item) }
                                            } label: {
                                                Label("Remove", systemImage: "trash")
                                            }
                                        }
                                    }
                            }
                        }
                        .padding(.horizontal)
                        .padding(.bottom, 100)
                    }
                }
            }
            .navigationTitle("Queue")
            .toolbar {
                if !downloadManager.queue.isEmpty, !downloadManager.isRunning {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Clear", role: .destructive) { withAnimation { downloadManager.clear() } }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !downloadManager.queue.isEmpty {
                    QueueControlBar()
                        .padding(12)
                        .liquidGlassRoundedRect(20, tint: Color.accentColor.opacity(0.15))
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                }
            }
        }
    }
}

private struct QueueSummaryCard: View {
    let progress: Double
    let done: Int
    let total: Int
    let isPaused: Bool
    var eta: Double?

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().stroke(Color.accentColor.opacity(0.2), lineWidth: 6)
                Circle()
                    .trim(from: 0, to: max(0.02, progress))
                    .stroke(Theme.accentGradient, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut, value: progress)
                Text("\(Int(progress * 100))%")
                    .font(.caption.weight(.semibold))
            }
            .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 2) {
                Text(isPaused ? "Paused" : "\(done) of \(total) complete")
                    .font(.headline)
                Text(isPaused ? "Tap Resume to continue" : (eta.map { "About \(ETAFormatter.string($0)) remaining" } ?? "Downloading"))
                    .monospacedDigit()
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .cardStyle()
    }
}

private struct QueueControlBar: View {
    @Environment(AppConfig.self) private var config
    @Environment(DownloadManager.self) private var downloadManager

    var body: some View {
        HStack(spacing: 12) {
            if downloadManager.isRunning {
                Button {
                    downloadManager.togglePause()
                } label: {
                    Label(downloadManager.isPaused ? "Resume" : "Pause", systemImage: downloadManager.isPaused ? "play.fill" : "pause.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button(role: .destructive) {
                    downloadManager.cancelAll()
                } label: {
                    Label("Cancel", systemImage: "xmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            } else {
                Button {
                    downloadManager.start(config: config)
                } label: {
                    Label("Start Downloads", systemImage: "arrow.down.circle.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .disabled(downloadManager.queue.allSatisfy { if case .done = $0.status { return true }; return false })
            }
        }
    }
}

struct QueueRowView: View {
    var item: QueueItem
    var showCover = true
    var onCancel: () -> Void = {}

    private var isActive: Bool {
        item.status == .downloading || item.status == .decrypting || item.status == .queued
    }

    var body: some View {
        HStack(spacing: 12) {
            if showCover {
                CoverArtView(entry: item.entry, width: 36)
            }
            RingProgressView(progress: ringProgress, category: item.entry.category)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.entry.name.isEmpty ? item.entry.titleIDHex : item.entry.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)

                if item.entry.version >= 0 {
                    Text("v\(item.entry.version) · \(item.entry.titleIDHex)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }

                statusView
            }
            Spacer()

            if isActive {
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel")
            }
        }
        .padding(12)
        .cardStyle()
    }

    private var ringProgress: Double {
        switch item.status {
        case .decrypting: return item.decryptionProgress
        case .done: return 1
        default: return item.progressFraction
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch item.status {
        case .queued:
            Text("Queued").font(.caption).foregroundStyle(.secondary)
        case .sizing:
            Text("Checking size…").font(.caption).foregroundStyle(.secondary)
        case .downloading:
            HStack(spacing: 6) {
                Text(byteString(item.bytesDownloaded) + " / " + byteString(item.totalBytes))
                Text("·")
                Text(byteString(Int64(item.speedBytesPerSecond)) + "/s")
                if let eta = item.etaSeconds {
                    Text("·")
                    Text("\(ETAFormatter.string(eta)) left")
                        .contentTransition(.numericText())
                }
            }
            .monospacedDigit()
            .font(.caption2)
            .foregroundStyle(.secondary)
        case .decrypting:
            Text("Decrypting \(Int(item.decryptionProgress * 100))%").font(.caption).foregroundStyle(.secondary)
        case .done:
            Label("Done", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red).lineLimit(2)
        case .cancelled:
            Text("Cancelled").font(.caption).foregroundStyle(.orange)
        }
    }

    private func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
