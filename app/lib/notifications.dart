import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'brand.dart';

// Notifications wraps flutter_local_notifications for the SSE-driven local
// notifications (new handoff / comment / log alert while the app is alive).
// Degrades to a no-op on unsupported platforms. (True killed-app push needs
// FCM/APNs + relay support — out of scope.)
class Notifications {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _ready = false;
  static int _id = 0;

  static Future<void> init() async {
    try {
      const settings = InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(),
        macOS: DarwinInitializationSettings(),
      );
      await _plugin.initialize(settings: settings);
      await _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.requestNotificationsPermission();
      await _plugin
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >()
          ?.requestPermissions(alert: true, badge: true, sound: true);
      await _plugin
          .resolvePlatformSpecificImplementation<
            MacOSFlutterLocalNotificationsPlugin
          >()
          ?.requestPermissions(alert: true, badge: true, sound: true);
      _ready = true;
    } catch (_) {
      // notifications unavailable on this platform/config
    }
  }

  static Future<void> show(String title, String body) async {
    if (!_ready) return;
    try {
      const details = NotificationDetails(
        android: AndroidNotificationDetails(
          'cc_handoff',
          AppBrand.shortName,
          importance: Importance.high,
          priority: Priority.high,
        ),
        // presentAlert/Banner/Sound so the banner shows even with the app in the
        // foreground (iOS/macOS otherwise suppress notifications while active).
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentBanner: true,
          presentSound: true,
        ),
        macOS: DarwinNotificationDetails(
          presentAlert: true,
          presentBanner: true,
          presentSound: true,
        ),
      );
      await _plugin.show(
        id: _id++,
        title: title,
        body: body,
        notificationDetails: details,
      );
    } catch (_) {}
  }
}
