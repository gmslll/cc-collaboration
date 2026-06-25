import ActivityKit
import Foundation

// Shared between the Runner app (which starts/updates/ends the activity) and the
// CCLiveActivity widget extension (which renders it). ActivityKit is iOS 16.1+,
// so the conformance is availability-gated — which lets this file also compile
// in the iOS 13.0 Runner target (the annotation guards the 16.1-only protocol).
@available(iOS 16.1, *)
struct CCAgentActivityAttributes: ActivityAttributes {
  // The live, changing part: whether the AI is working and the latest snippet.
  public struct ContentState: Codable, Hashable {
    var working: Bool
    var latestText: String
    var updatedAt: Date
  }

  // Static for the activity's lifetime: which session this island represents.
  var sessionTitle: String
  var sessionId: String
}
