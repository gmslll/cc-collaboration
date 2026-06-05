import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

// Prefs is a tiny key→bool store for UI layout state (panel collapse, section
// fold) persisted to appSupport, so the cockpit layout is remembered across
// launches. Loaded once at startup; reads are synchronous against the cache.
class Prefs {
  static final Map<String, dynamic> _data = {};
  static String? _path;

  static Future<void> load() async {
    try {
      _path = '${(await getApplicationSupportDirectory()).path}/ui_prefs.json';
      final f = File(_path!);
      if (await f.exists()) {
        final m = jsonDecode(await f.readAsString());
        if (m is Map) _data.addAll(m.cast<String, dynamic>());
      }
    } catch (_) {}
  }

  static bool getBool(String key, {bool def = false}) =>
      _data[key] is bool ? _data[key] as bool : def;

  static void setBool(String key, bool value) {
    _data[key] = value;
    _save();
  }

  static Future<void> _save() async {
    final p = _path;
    if (p == null) return;
    try {
      await File(p).writeAsString(jsonEncode(_data));
    } catch (_) {}
  }
}
