import ActivityKit
import SwiftUI
import WidgetKit

// The Live Activity UI: a Lock-Screen / banner view plus the Dynamic Island
// presentations (expanded / compact / minimal). Driven by CCAgentActivityAttributes.
@available(iOS 16.1, *)
struct CCAgentLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: CCAgentActivityAttributes.self) { context in
      CCLockScreenView(context: context)
        .activityBackgroundTint(Color.black.opacity(0.55))
        .activitySystemActionForegroundColor(.white)
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          Label {
            Text(context.attributes.sessionTitle).font(.caption).lineLimit(1)
          } icon: {
            Image(systemName: context.state.working ? "hourglass" : "checkmark.circle.fill")
              .foregroundStyle(context.state.working ? .orange : .green)
          }
        }
        DynamicIslandExpandedRegion(.trailing) {
          Text(context.state.working ? "干活中" : "完成")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        DynamicIslandExpandedRegion(.bottom) {
          Text(context.state.latestText.isEmpty ? "…" : context.state.latestText)
            .font(.caption)
            .lineLimit(3)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      } compactLeading: {
        Image(systemName: context.state.working ? "hourglass" : "checkmark.circle.fill")
          .foregroundStyle(context.state.working ? .orange : .green)
      } compactTrailing: {
        if context.state.working {
          ProgressView().scaleEffect(0.6)
        } else {
          Image(systemName: "checkmark").foregroundStyle(.green)
        }
      } minimal: {
        Image(systemName: context.state.working ? "hourglass" : "checkmark.circle.fill")
          .foregroundStyle(context.state.working ? .orange : .green)
      }
    }
  }
}

// Lock-screen / notification-banner presentation.
@available(iOS 16.1, *)
struct CCLockScreenView: View {
  let context: ActivityViewContext<CCAgentActivityAttributes>
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        Image(systemName: context.state.working ? "hourglass" : "checkmark.circle.fill")
          .foregroundStyle(context.state.working ? .orange : .green)
        Text(context.attributes.sessionTitle)
          .font(.headline)
          .lineLimit(1)
        Spacer()
        Text(context.state.working ? "AI 干活中" : "已完成")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Text(context.state.latestText.isEmpty ? "…" : context.state.latestText)
        .font(.subheadline)
        .lineLimit(2)
        .foregroundStyle(.primary)
    }
    .padding(14)
  }
}
