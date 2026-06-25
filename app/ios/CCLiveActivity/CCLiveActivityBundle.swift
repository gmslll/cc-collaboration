import SwiftUI
import WidgetKit

// Entry point of the CCLiveActivity widget extension. The extension's deployment
// target is 16.2, so the iOS 16.1-annotated CCAgentLiveActivity is unconditionally
// available here.
@main
struct CCLiveActivityBundle: WidgetBundle {
  var body: some Widget {
    CCAgentLiveActivity()
  }
}
