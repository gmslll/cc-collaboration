import 'dart:convert';

import 'prefs_store.dart';

// Prefs is a tiny key→bool store for UI layout state (panel collapse, section
// fold) persisted via a per-platform backend (appSupport JSON on desktop/mobile,
// no-op on web), so the cockpit layout is remembered across launches. Loaded
// once at startup; reads are synchronous against the cache.
class Prefs {
  static final Map<String, dynamic> _data = {};

  static Future<void> load() async {
    try {
      final raw = await prefsLoadRaw();
      if (raw == null) return;
      final m = jsonDecode(raw);
      if (m is Map) _data.addAll(m.cast<String, dynamic>());
    } catch (_) {}
  }

  static bool getBool(String key, {bool def = false}) =>
      _data[key] is bool ? _data[key] as bool : def;

  static void setBool(String key, bool value) {
    _data[key] = value;
    _save();
  }

  static double getDouble(String key, {required double def}) {
    final v = _data[key];
    return v is num ? v.toDouble() : def;
  }

  static void setDouble(String key, double value) {
    _data[key] = value;
    _save();
  }

  static String getString(String key, {required String def}) {
    final v = _data[key];
    return v is String ? v : def;
  }

  static void setString(String key, String value) {
    _data[key] = value;
    _save();
  }

  static void remove(String key) {
    _data.remove(key);
    _save();
  }

  static void removeAll(Iterable<String> keys) {
    for (final key in keys) {
      _data.remove(key);
    }
    _save();
  }

  static Future<void> _save() async {
    try {
      await prefsSaveRaw(jsonEncode(_data));
    } catch (_) {}
  }
}
