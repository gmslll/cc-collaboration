import 'dart:io';

import 'package:path_provider/path_provider.dart';

// Native persistence backend for Prefs: a JSON file under appSupport. The path
// is resolved once and cached so saves (one per setX) don't re-hit path_provider.
String? _path;

Future<String> _pathFor() async =>
    _path ??= '${(await getApplicationSupportDirectory()).path}/ui_prefs.json';

Future<String?> prefsLoadRaw() async {
  try {
    final f = File(await _pathFor());
    return await f.exists() ? await f.readAsString() : null;
  } catch (_) {
    return null;
  }
}

Future<void> prefsSaveRaw(String json) async {
  try {
    await File(await _pathFor()).writeAsString(json);
  } catch (_) {}
}
