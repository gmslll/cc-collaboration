import 'dart:io';

import 'package:toml/toml.dart';

// AppConfig reads the same ~/.config/cc-handoff/config.toml the CLI uses, so the
// desktop app is auto-authenticated (no login UI in F1; login lands in F3) and
// can resolve a handoff's repo name to a local clone for pickup.
class AppConfig {
  final String relayUrl;
  final String token;
  final String identity;

  /// repo name -> absolute local path (from [[workspace.project]] entries).
  final Map<String, String> repos;

  AppConfig(this.relayUrl, this.token, this.identity, this.repos);

  String? repoPath(String name) => repos[name];

  static String configPath() => '${_home()}/.config/cc-handoff/config.toml';

  static Future<AppConfig?> load() async {
    final f = File(configPath());
    if (!await f.exists()) return null;
    final map = TomlDocument.parse(await f.readAsString()).toMap();

    final relay = (map['relay_url'] ?? '').toString();
    final token = (map['token'] ?? '').toString();
    final identity = (map['identity'] ?? '').toString();
    if (relay.isEmpty || token.isEmpty) return null;

    final repos = <String, String>{};
    final workspaces = (map['workspace'] as List?) ?? const [];
    for (final ws in workspaces.whereType<Map>()) {
      final wsName = (ws['name'] ?? '').toString();
      final wsPath = (ws['path'] ?? '').toString();
      final projects = (ws['project'] as List?) ?? const [];
      for (final p in projects.whereType<Map>()) {
        final name = (p['name'] ?? '').toString();
        if (name.isEmpty) continue;
        var path = _expand((p['path'] ?? '').toString());
        if (path.isNotEmpty && !path.startsWith('/')) {
          final base = wsPath.isNotEmpty
              ? _expand(wsPath)
              : '${_home()}/cc-handoff-workspaces/${wsName.isEmpty ? 'default' : wsName}';
          path = '$base/$path';
        }
        if (path.isNotEmpty) repos.putIfAbsent(name, () => path);
      }
    }

    return AppConfig(relay, token, identity, repos);
  }
}

String _home() => Platform.environment['HOME'] ?? '';

String _expand(String p) {
  if (p == '~') return _home();
  if (p.startsWith('~/')) return '${_home()}/${p.substring(2)}';
  return p;
}
