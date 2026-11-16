import ActivityKit
import SwiftUI
import WidgetKit

struct DownloadLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DownloadActivityAttributes.self) { context in
            LockScreenView(attributes: context.attributes, state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: context.state.isPaused ? "pause.circle.fill" : "arrow.down.circle.fill")
                        .foregroundStyle(.blue)
                        .font(.title2)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(percentString(context.state))
                        .font(.headline.monospacedDigit())
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(context.attributes.titleName)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        ProgressView(value: fraction(context.state))
                            .tint(.blue)
                        Text(context.state.statusText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(.blue)
            } compactTrailing: {
                Text(percentString(context.state)).font(.caption2.monospacedDigit())
            } minimal: {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(.blue)
            }
        }
    }
}

private func fraction(_ state: DownloadActivityAttributes.ContentState) -> Double {
    guard state.totalBytes > 0 else { return 0 }
    return min(1, Double(state.bytesDownloaded) / Double(state.totalBytes))
}

private func percentString(_ state: DownloadActivityAttributes.ContentState) -> String {
    "\(Int(fraction(state) * 100))%"
}

private struct LockScreenView: View {
    let attributes: DownloadActivityAttributes
    let state: DownloadActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: state.isDone ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                .font(.largeTitle)
                .foregroundStyle(state.isDone ? .green : .blue)

            VStack(alignment: .leading, spacing: 6) {
                Text(attributes.titleName)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)

                ProgressView(value: fraction(state))
                    .tint(.blue)

                Text(state.statusText)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
            }
            Spacer()
            Text(percentString(state))
                .font(.title3.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white)
        }
        .padding()
    }
}
