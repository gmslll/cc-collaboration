import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

// LiveActivity bridges Dart → native iOS ActivityKit (Dynamic Island + Lock
// Screen) over a MethodChannel. It is web-safe (no dart:io) so it can be used
// from the phone client screen, which is also compiled into the web bundle.
//
// Everything is a graceful no-op off iOS, on iOS < 16.1, when the user has
// Live Activities disabled, or before the native handler is registered: each
// call is guarded by platform + wrapped in try/catch so a missing handler
// (MissingPluginException) never surfaces to the UI. The native side lives in
// app/ios/Runner/LiveActivityController.swift + the CCLiveActivity extension.
class LiveActivity {
  static const MethodChannel _ch = MethodChannel(
    'dev.cchandoff.app/liveactivity',
  );

  static bool get _supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  // areEnabled reports whether Live Activities can actually be shown (iOS ≥
  // 16.1 and not disabled by the user). false everywhere else.
  static Future<bool> areEnabled() async {
    if (!_supported) return false;
    try {
      return (await _ch.invokeMethod<bool>('areActivitiesEnabled')) ?? false;
    } catch (_) {
      return false;
    }
  }

  // start begins (or restarts) the Activity for a watched session. Safe to call
  // even if one is already running — the native side ends the prior one first.
  static Future<void> start({
    required String title,
    required String sessionId,
  }) async {
    if (!_supported) return;
    try {
      await _ch.invokeMethod('startActivity', {
        'sessionTitle': title,
        'sessionId': sessionId,
      });
    } catch (_) {}
  }

  // update pushes the latest working/idle state + text into the Activity.
  static Future<void> update({
    required bool working,
    required String text,
  }) async {
    if (!_supported) return;
    try {
      await _ch.invokeMethod('updateActivity', {
        'working': working,
        'text': text,
      });
    } catch (_) {}
  }

  // end dismisses the Activity (leaving the session / closing the screen).
  static Future<void> end() async {
    if (!_supported) return;
    try {
      await _ch.invokeMethod('endActivity');
    } catch (_) {}
  }
}
