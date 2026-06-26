import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

// Native session key-value backend: the platform secure store (Keychain on iOS/
// macOS, Keystore on Android, libsecret/DPAPI on desktop).
//
// Fallback: if the secure store is unavailable we degrade to a plaintext JSON
// file in the app-support dir instead of failing. This unblocks macOS when the
// keychain entitlement is missing or signing rejects it — SecItem throws -34018
// (errSecMissingEntitlement) there, which would otherwise abort login/logout.
// The desktop already keeps a plaintext token in ~/.config/cc-handoff/config.toml,
// so the file fallback is no weaker; when the keychain works nothing touches it.
const _s = FlutterSecureStorage();

Future<String?> kvRead(String key) async {
  try {
    return await _s.read(key: key);
  } catch (_) {
    return (await _fileMap())[key];
  }
}

Future<void> kvWrite(String key, String value) async {
  try {
    await _s.write(key: key, value: value);
  } catch (_) {
    final m = await _fileMap();
    m[key] = value;
    await _fileSave(m);
  }
}

Future<void> kvDelete(String key) async {
  try {
    await _s.delete(key: key);
  } catch (_) {
    final m = await _fileMap();
    m.remove(key);
    await _fileSave(m);
  }
}

Future<File> _fileHandle() async =>
    File('${(await getApplicationSupportDirectory()).path}/session_kv.json');

Future<Map<String, String>> _fileMap() async {
  try {
    final f = await _fileHandle();
    if (!await f.exists()) return {};
    final d = jsonDecode(await f.readAsString());
    if (d is! Map) return {};
    return d.map((k, v) => MapEntry(k.toString(), v.toString()));
  } catch (_) {
    return {};
  }
}

Future<void> _fileSave(Map<String, String> m) async {
  try {
    await (await _fileHandle()).writeAsString(jsonEncode(m));
  } catch (_) {}
}
