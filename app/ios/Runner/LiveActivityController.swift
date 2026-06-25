import Flutter
import Foundation

#if canImport(ActivityKit)
import ActivityKit
#endif

// LiveActivityController drives the CCAgentActivityAttributes Live Activity from
// the Runner app. Every ActivityKit call is gated to iOS 16.1+ and wrapped so it
// is a clean no-op on older OS / when the user has Live Activities disabled —
// the Flutter bridge must never throw into Dart.
final class LiveActivityController {
  static let shared = LiveActivityController()
  private init() {}

  // The current activity, stored as Any? so the property itself needs no
  // availability annotation (Activity<…> is 16.1-only). Accessed only inside
  // #available guards below.
  private var _activity: Any?

  func areActivitiesEnabled() -> Bool {
    if #available(iOS 16.1, *) {
      return ActivityAuthorizationInfo().areActivitiesEnabled
    }
    return false
  }

  func start(title: String, sessionId: String) {
    guard #available(iOS 16.1, *) else { return }
    guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
    end() // one island per screen; drop any prior one first
    let attrs = CCAgentActivityAttributes(sessionTitle: title, sessionId: sessionId)
    let state = CCAgentActivityAttributes.ContentState(
      working: true, latestText: "思考中…", updatedAt: Date())
    do {
      if #available(iOS 16.2, *) {
        _activity = try Activity.request(
          attributes: attrs,
          content: ActivityContent(state: state, staleDate: nil))
      } else {
        _activity = try Activity.request(attributes: attrs, contentState: state)
      }
    } catch {
      _activity = nil
    }
  }

  func update(working: Bool, text: String) {
    guard #available(iOS 16.1, *),
      let activity = _activity as? Activity<CCAgentActivityAttributes>
    else { return }
    let state = CCAgentActivityAttributes.ContentState(
      working: working, latestText: text, updatedAt: Date())
    Task {
      if #available(iOS 16.2, *) {
        await activity.update(ActivityContent(state: state, staleDate: nil))
      } else {
        await activity.update(using: state)
      }
    }
  }

  func end() {
    guard #available(iOS 16.1, *),
      let activity = _activity as? Activity<CCAgentActivityAttributes>
    else { return }
    _activity = nil
    Task {
      if #available(iOS 16.2, *) {
        await activity.end(nil, dismissalPolicy: .immediate)
      } else {
        await activity.end(dismissalPolicy: .immediate)
      }
    }
  }
}

// LiveActivityPlugin bridges the dev.cchandoff.app/liveactivity MethodChannel to
// the controller. Registered from AppDelegate via the implicit engine's plugin
// registry, so it works with this app's FlutterImplicitEngine setup.
final class LiveActivityPlugin: NSObject, FlutterPlugin {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "dev.cchandoff.app/liveactivity",
      binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(LiveActivityPlugin(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "areActivitiesEnabled":
      result(LiveActivityController.shared.areActivitiesEnabled())
    case "startActivity":
      LiveActivityController.shared.start(
        title: args["sessionTitle"] as? String ?? "AI",
        sessionId: args["sessionId"] as? String ?? "")
      result(true)
    case "updateActivity":
      LiveActivityController.shared.update(
        working: args["working"] as? Bool ?? false,
        text: args["text"] as? String ?? "")
      result(nil)
    case "endActivity":
      LiveActivityController.shared.end()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
