// Web persistence backend for Prefs: no-op. UI layout prefs (panel sizes/folds)
// fall back to defaults each page load — acceptable for the browser client,
// which is a transient remote view. Could be backed by window.localStorage later.
Future<String?> prefsLoadRaw() async => null;

Future<void> prefsSaveRaw(String json) async {}
