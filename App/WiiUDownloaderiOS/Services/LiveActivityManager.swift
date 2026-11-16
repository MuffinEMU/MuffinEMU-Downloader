import ActivityKit
import Foundation

/// Drives a single Live Activity for whichever title is currently downloading. Only one runs
/// at a time (matching the queue's one-at-a-time execution model) — starting a new one ends
/// whatever was running before.
@MainActor
final class LiveActivityManager {
    static let shared = LiveActivityManager()

    private var activity: Activity<DownloadActivityAttributes>?

    private init() {}

    var isSupported: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    func start(titleName: String) {
        guard isSupported else { return }
        end(immediately: true)

        let attributes = DownloadActivityAttributes(titleName: titleName)
        let state = DownloadActivityAttributes.ContentState(
            bytesDownloaded: 0, totalBytes: 0, speedBytesPerSecond: 0,
            statusText: "Starting…", isPaused: false, isDone: false
        )
        activity = try? Activity.request(attributes: attributes, content: .init(state: state, staleDate: nil))
    }

    func update(bytesDownloaded: Int64, totalBytes: Int64, speedBytesPerSecond: Double, statusText: String, isPaused: Bool) {
        guard let activity else { return }
        let state = DownloadActivityAttributes.ContentState(
            bytesDownloaded: bytesDownloaded, totalBytes: totalBytes, speedBytesPerSecond: speedBytesPerSecond,
            statusText: statusText, isPaused: isPaused, isDone: false
        )
        Task { await activity.update(.init(state: state, staleDate: nil)) }
    }

    func finish(statusText: String, success: Bool) {
        guard let activity else { return }
        let last = activity.content.state
        let state = DownloadActivityAttributes.ContentState(
            bytesDownloaded: success ? last.totalBytes : last.bytesDownloaded,
            totalBytes: last.totalBytes, speedBytesPerSecond: 0,
            statusText: statusText, isPaused: false, isDone: true
        )
        Task {
            await activity.end(.init(state: state, staleDate: nil), dismissalPolicy: .after(.now.addingTimeInterval(4)))
        }
        self.activity = nil
    }

    func end(immediately: Bool = false) {
        guard let activity else { return }
        Task { await activity.end(nil, dismissalPolicy: immediately ? .immediate : .default) }
        self.activity = nil
    }
}
