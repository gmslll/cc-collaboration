import 'dart:io';

import 'package:flutter/foundation.dart';

import '../local/prefs.dart';
import '../local/shell.dart';
import 'format_plugin.dart';

// PluginManager owns the runtime state of the format plugins: which host tools
// are present (detected by shelling `command -v`), which plugins the user has
// enabled (persisted in Prefs), and running a formatter in place on a file.
//
// Formatting runs on the local desktop only (Process.run). The remote/mobile
// viewer would need a separate host-exec channel — out of scope here.
class PluginManager extends ChangeNotifier {
  PluginManager._();
  static final PluginManager instance = PluginManager._();

  final Map<String, bool> _available = {}; // plugin.id -> tool found on PATH
  bool _detected = false;
  bool _detecting = false;

  bool get detected => _detected;

  static String _shell() => Platform.environment['SHELL'] ?? '/bin/sh';

  static Future<ProcessResult> _runLoginShell(
    String cmd, {
    String? workingDirectory,
  }) => Process.run(_shell(), ['-lc', cmd], workingDirectory: workingDirectory);

  // --- enable state (persisted, default on) ---

  String _enabledKey(String id) => 'plugin.$id.enabled';

  bool enabled(String id) => Prefs.getBool(_enabledKey(id), def: true);

  void setEnabled(String id, bool value) {
    if (enabled(id) == value) return;
    Prefs.setBool(_enabledKey(id), value);
    notifyListeners();
  }

  // --- availability ---

  // A built-in renderer is always available; a formatter is available once its
  // tool has been detected on the host PATH.
  bool available(FormatPlugin p) =>
      p.builtIn || (_available[p.id] ?? false);

  @visibleForTesting
  void debugSetAvailable(String id, bool value) {
    _available[id] = value;
    _detected = true;
  }

  // Detect every formatter's tool once (cached). Cheap `command -v` probes run
  // through the login shell so the GUI app sees the user's full PATH.
  Future<void> detectAll({bool force = false}) async {
    if (_detecting || (_detected && !force)) return;
    _detecting = true;
    try {
      final formatters = kFormatPlugins.where((p) => p.tool != null).toList();
      final results = await Future.wait(
        formatters.map((p) async => MapEntry(p.id, await _hasTool(p.tool!))),
      );
      _available
        ..clear()
        ..addEntries(results);
      _detected = true;
    } finally {
      _detecting = false;
      notifyListeners();
    }
  }

  Future<bool> _hasTool(String tool) async {
    try {
      final res = Platform.isWindows
          ? await Process.run('where', [tool])
          : await _runLoginShell('command -v ${shQuote(tool)}');
      return res.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  // --- lookups used by the editor ---

  // First catalog plugin handling [ext] that satisfies [test].
  FormatPlugin? _find(String ext, bool Function(FormatPlugin) test) {
    final e = ext.toLowerCase();
    for (final p in kFormatPlugins) {
      if (p.exts.contains(e) && test(p)) return p;
    }
    return null;
  }

  // The formatter that would run for [ext], honoring enabled + availability.
  FormatPlugin? formatterFor(String ext) => _find(
    ext,
    (p) => p.kind == PluginKind.formatter && enabled(p.id) && available(p),
  );

  // The catalog formatter for [ext] regardless of enabled/availability — lets
  // the UI show a disabled button with an "install <tool>" hint.
  FormatPlugin? formatterCatalogFor(String ext) =>
      _find(ext, (p) => p.kind == PluginKind.formatter);

  // The enabled renderer (e.g. Markdown preview) handling [ext], if any.
  FormatPlugin? rendererFor(String ext) =>
      _find(ext, (p) => p.kind == PluginKind.renderer && enabled(p.id));

  // Run the matching formatter in place on [file]. Returns trimmed stdout;
  // throws with the tool's stderr on failure. Caller reloads the file after.
  Future<String> format(String file) async {
    final ext = file.split('/').last.split('.').last;
    final p = formatterFor(ext);
    if (p == null) throw const FormatPluginException('没有可用的格式化插件');
    final argv = <String>[p.tool!, ...?p.args?.call(file)];
    final dir = File(file).parent.path;
    final ProcessResult res;
    if (Platform.isWindows) {
      res = await Process.run(
        argv.first,
        argv.sublist(1),
        workingDirectory: dir,
      );
    } else {
      res = await _runLoginShell(
        argv.map(shQuote).join(' '),
        workingDirectory: dir,
      );
    }
    if (res.exitCode != 0) {
      final err = (res.stderr as String).trim();
      throw FormatPluginException(
        err.isNotEmpty ? err : '格式化失败 (exit ${res.exitCode})',
      );
    }
    return (res.stdout as String).trim();
  }
}

class FormatPluginException implements Exception {
  final String message;
  const FormatPluginException(this.message);
  @override
  String toString() => message;
}
