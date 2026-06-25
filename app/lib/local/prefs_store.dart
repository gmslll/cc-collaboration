// Prefs persistence backend, picked per platform: a JSON file under appSupport
// (dart:io) on desktop/mobile, a no-op on web. Keeps dart:io out of prefs.dart
// so the Flutter Web client compiles. Both expose prefsLoadRaw / prefsSaveRaw.
export 'prefs_store_io.dart' if (dart.library.html) 'prefs_store_web.dart';
