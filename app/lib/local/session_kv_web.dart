// Web session key-value backend: browser localStorage. flutter_secure_storage's
// web impl needs a secure context (it uses SubtleCrypto), so it throws over plain
// http — localStorage works in any context and is where the relay's own /ui/ JS
// client keeps its token too. A session bearer token doesn't need OS-keychain
// grade storage here.
//
// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:html' as html;

Future<String?> kvRead(String key) async => html.window.localStorage[key];

Future<void> kvWrite(String key, String value) async =>
    html.window.localStorage[key] = value;

Future<void> kvDelete(String key) async => html.window.localStorage.remove(key);
