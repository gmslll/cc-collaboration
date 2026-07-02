// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:html' as html;

const String _key = 'cc-handoff.ui_prefs.v1';

Future<String?> prefsLoadRaw() async => html.window.localStorage[_key];

Future<void> prefsSaveRaw(String json) async {
  html.window.localStorage[_key] = json;
}
