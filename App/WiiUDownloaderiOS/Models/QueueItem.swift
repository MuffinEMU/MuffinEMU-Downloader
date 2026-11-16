import Foundation
import WUDCore

enum QueueItemStatus: Equatable {
    case queued
    case sizing
    case downloading
    case decrypting
    case done
    case failed(String)
    case cancelled
}

@Observable
final class QueueItem: Identifiable {
    let id = UUID()
    var entry: TitleEntry
    var status: QueueItemStatus = .queued
    var bytesDownloaded: Int64 = 0
    var totalBytes: Int64 = 0
    var speedBytesPerSecond: Double = 0
    var decryptionProgress: Double = 0
    /// Seconds left at the current smoothed speed; nil until there's enough data.
    var etaSeconds: Double?

    init(entry: TitleEntry) {
        self.entry = entry
    }

    var progressFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1.0, Double(bytesDownloaded) / Double(totalBytes))
    }
}
