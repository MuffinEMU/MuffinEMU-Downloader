import ActivityKit
import Foundation

/// Shared between the app and the widget extension (both targets compile this same file) so a
/// Live Activity can show the current download's progress on the Lock Screen / Dynamic Island.
struct DownloadActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var bytesDownloaded: Int64
        var totalBytes: Int64
        var speedBytesPerSecond: Double
        var statusText: String
        var isPaused: Bool
        var isDone: Bool
    }

    var titleName: String
}
