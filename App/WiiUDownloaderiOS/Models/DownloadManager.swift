import Foundation
import UIKit
import WUDCore

/// Drives the download queue: one title at a time (matching the upstream tool's per-title
/// concurrency — contents within a title still download in parallel via ``Downloader``),
/// bridging ``WUDCore/ProgressReporter`` callbacks onto the observable ``QueueItem`` the UI reads.
@Observable
final class DownloadManager {
    var queue: [QueueItem] = []
    var isRunning = false
    var isPaused = false
    var currentItem: QueueItem?
    var lastError: String?

    private let downloader = Downloader()
    private var runTask: Task<Void, Never>?
    private var titleDatabase: [TitleEntry] = []
    /// Items the user cancelled individually; the reporter checks this so only that title stops.
    private(set) var cancelledItemIDs: Set<UUID> = []
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    func setTitleDatabase(_ db: [TitleEntry]) {
        titleDatabase = db
    }

    func add(_ entry: TitleEntry) {
        if let index = queue.firstIndex(where: { $0.entry.titleID == entry.titleID }) {
            // Re-adding with a different version replaces a not-yet-started entry.
            let existing = queue[index]
            guard existing.status == .queued, existing.entry.version != entry.version else { return }
            queue[index] = QueueItem(entry: entry)
            return
        }
        queue.append(QueueItem(entry: entry))
    }

    /// Stops one title: the running one is cancelled mid-download, a queued one is skipped.
    func cancel(_ item: QueueItem) {
        cancelledItemIDs.insert(item.id)
        if item.status == .queued { item.status = .cancelled }
    }

    func remove(_ item: QueueItem) {
        cancelledItemIDs.insert(item.id)
        queue.removeAll { $0.id == item.id }
    }

    func clear() {
        guard !isRunning else { return }
        queue.removeAll()
    }

    func start(config: AppConfig) {
        guard !isRunning, !queue.isEmpty else { return }
        isRunning = true
        isPaused = false
        lastError = nil

        cancelledItemIDs = []
        for item in queue where isFailed(item.status) || item.status == .cancelled {
            item.status = .queued
        }

        let destination: (root: URL, stop: () -> Void)
        do {
            destination = try config.openDownloadDestination()
        } catch {
            isRunning = false
            lastError = error.localizedDescription
            Haptics.error()
            return
        }

        UIApplication.shared.isIdleTimerDisabled = config.keepScreenOn
        // iOS gives a short grace period after backgrounding; downloads resume from their
        // journal if the app gets suspended anyway.
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Muffin Downloader queue") { [weak self] in
            self?.endBackgroundTask()
        }

        runTask = Task {
            for item in queue where item.status == .queued {
                if Task.isCancelled { break }
                if cancelledItemIDs.contains(item.id) { continue }
                let succeeded = await run(item: item, config: config, root: destination.root)
                if !succeeded, !config.continueOnError, !cancelledItemIDs.contains(item.id) { break }
            }
            destination.stop()
            await MainActor.run {
                self.isRunning = false
                self.currentItem = nil
                UIApplication.shared.isIdleTimerDisabled = false
                self.endBackgroundTask()
            }
        }
    }

    func togglePause() {
        isPaused.toggle()
    }

    func cancelAll() {
        runTask?.cancel()
        isRunning = false
        isPaused = false
        currentItem = nil
        UIApplication.shared.isIdleTimerDisabled = false
        endBackgroundTask()
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private func isFailed(_ status: QueueItemStatus) -> Bool {
        if case .failed = status { return true }
        return false
    }

    /// Returns false when the title failed (not when it was cancelled).
    private func run(item: QueueItem, config: AppConfig, root: URL) async -> Bool {
        await MainActor.run {
            self.currentItem = item
            item.status = .downloading
            LiveActivityManager.shared.start(titleName: item.entry.name.isEmpty ? item.entry.titleIDHex : item.entry.name)
        }

        let reporter = QueueItemProgressReporter(item: item, manager: self)
        let options = Downloader.Options(
            titleIDHex: item.entry.titleIDHex,
            outputDirectory: root.appendingPathComponent(item.entry.outputFolderName, isDirectory: true),
            version: item.entry.version,
            decryptContents: config.decryptContents,
            deleteEncryptedAfterDecrypt: config.decryptContents && config.deleteEncryptedContents,
            decryptOutputDirectory: nil,
            titleDatabase: titleDatabase
        )

        do {
            try await downloader.downloadTitle(options, progress: reporter)
            if reporter.isCancelled {
                await markCancelled(item)
                return true
            }
            await MainActor.run {
                item.status = .done
                Haptics.success()
                LiveActivityManager.shared.finish(statusText: "Complete", success: true)
            }
            return true
        } catch {
            if error is CancellationError || reporter.isCancelled {
                await markCancelled(item)
                return true
            }
            await MainActor.run {
                item.status = .failed(error.localizedDescription)
                self.lastError = error.localizedDescription
                Haptics.error()
                LiveActivityManager.shared.finish(statusText: "Failed", success: false)
            }
            return false
        }
    }

    private func markCancelled(_ item: QueueItem) async {
        await MainActor.run {
            item.status = .cancelled
            LiveActivityManager.shared.end()
        }
    }
}

/// Bridges the core library's progress callbacks onto the observable queue item. Bytes are
/// tracked per file because several files (and segments of one file) download at once; the
/// item's total is their sum. Speed is smoothed so the ETA doesn't jitter.
final class QueueItemProgressReporter: ProgressReporter {
    private let item: QueueItem
    private weak var manager: DownloadManager?
    private var fileBytes: [String: Int64] = [:]
    private var lastSpeedSample = Date()
    private var lastSpeedBytes: Int64 = 0
    private var smoothedSpeed: Double = 0

    init(item: QueueItem, manager: DownloadManager) {
        self.item = item
        self.manager = manager
    }

    func setGameTitle(_ title: String) {
        Task { @MainActor in self.item.entry.name = title.isEmpty ? self.item.entry.name : title }
    }

    func updateDownloadProgress(downloaded: Int64, filename: String) {
        Task { @MainActor in
            self.fileBytes[filename, default: 0] += downloaded
            self.publish()
        }
    }

    func setTotalDownloaded(_ downloaded: Int64, forFile filename: String) {
        Task { @MainActor in
            self.fileBytes[filename] = downloaded
            self.publish()
        }
    }

    /// Recomputes the item total, speed and ETA. Runs on the main actor, so the dictionary is
    /// only touched from one thread.
    @MainActor private func publish() {
        item.bytesDownloaded = fileBytes.values.reduce(0, +)
        let now = Date()
        let elapsed = now.timeIntervalSince(lastSpeedSample)
        guard elapsed >= 0.5 else { return }

        let instant = max(0, Double(item.bytesDownloaded - lastSpeedBytes) / elapsed)
        smoothedSpeed = smoothedSpeed == 0 ? instant : smoothedSpeed * 0.7 + instant * 0.3
        lastSpeedSample = now
        lastSpeedBytes = item.bytesDownloaded
        item.speedBytesPerSecond = smoothedSpeed

        let remaining = item.totalBytes - item.bytesDownloaded
        item.etaSeconds = (smoothedSpeed > 1024 && item.totalBytes > 0 && remaining > 0) ? Double(remaining) / smoothedSpeed : nil

        let etaText = item.etaSeconds.map { " · \(ETAFormatter.string($0)) left" } ?? ""
        LiveActivityManager.shared.update(
            bytesDownloaded: item.bytesDownloaded,
            totalBytes: item.totalBytes,
            speedBytesPerSecond: smoothedSpeed,
            statusText: "Downloading\(etaText)",
            isPaused: manager?.isPaused ?? false
        )
    }

    func updateDecryptionProgress(_ progress: Double) {
        Task { @MainActor in
            self.item.status = .decrypting
            self.item.decryptionProgress = progress
            self.item.etaSeconds = nil
            LiveActivityManager.shared.update(
                bytesDownloaded: self.item.totalBytes,
                totalBytes: self.item.totalBytes,
                speedBytesPerSecond: 0,
                statusText: "Decrypting \(Int(progress * 100))%",
                isPaused: false
            )
        }
    }

    func setDownloadSize(_ size: Int64) {
        Task { @MainActor in self.item.totalBytes = size }
    }

    func resetTotals() {
        Task { @MainActor in
            self.fileBytes = [:]
            self.item.bytesDownloaded = 0
            self.item.totalBytes = 0
            self.item.etaSeconds = nil
            self.smoothedSpeed = 0
            self.lastSpeedBytes = 0
        }
    }

    func markFileAsDone(_ filename: String) {}

    func setStartTime(_ date: Date) {
        Task { @MainActor in
            self.lastSpeedSample = date
            self.lastSpeedBytes = self.item.bytesDownloaded
        }
    }

    var isCancelled: Bool {
        guard let manager else { return true }
        return manager.runTaskIsCancelled || manager.cancelledItemIDs.contains(item.id)
    }

    func waitIfPaused() async -> Bool {
        guard let manager else { return false }
        while manager.isPaused {
            if isCancelled { return false }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return !isCancelled
    }
}

enum ETAFormatter {
    private static let formatter: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.allowedUnits = [.hour, .minute, .second]
        f.unitsStyle = .abbreviated
        f.maximumUnitCount = 2
        return f
    }()

    static func string(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "—" }
        return formatter.string(from: seconds.rounded()) ?? "—"
    }
}

extension DownloadManager {
    var runTaskIsCancelled: Bool {
        runTask?.isCancelled ?? false
    }
}
