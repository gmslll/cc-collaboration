import 'dart:io';

import 'config.dart';

// AgentResolver figures out how to actually launch an AI agent ('claude' or
// 'codex') on this machine. The PTY launcher (terminal_pane.dart) uses a bare
// `claude`/`codex` resolved via the shell PATH, which is fragile: a GUI app has
// a minimal PATH, and installs land in non-standard spots (~/.cac/bin, nvm, bun,
// homebrew). This resolves an absolute path up front (or honors a user override)
// so a fresh session reliably starts.
//
// Resolution order:
//   1. user override: config.toml claude_command / codex_command (abs path or a
//      full command/script) — used verbatim.
//   2. discovered absolute path: `<shell> -lic 'command -v <agent>'` (login +
//      interactive so the full PATH applies), else known install locations.
//   3. the bare name (last-resort PATH fallback).
//
// Discovery is cached per agent for the app's lifetime (the shell probe runs
// once); the override is re-read each call so a settings change applies to new
// sessions without a restart.
class AgentResolver {
  AgentResolver._();

  // agent -> discovered absolute path ('' = probed, not found).
  static final Map<String, String> _discovered = {};

  static Future<String> resolve(String agent) async {
    if (agent != 'claude' && agent != 'codex') return agent;
    final override = await _override(agent);
    if (override.isNotEmpty) return override;
    final abs = await _discover(agent);
    return abs.isNotEmpty ? abs : agent;
  }

  static Future<String> _override(String agent) async {
    final cfg = await AppConfig.load();
    if (cfg == null) return '';
    final v = agent == 'codex' ? cfg.codexCommand : cfg.claudeCommand;
    return v.trim();
  }

  static Future<String> _discover(String agent) async {
    final cached = _discovered[agent];
    if (cached != null) return cached;
    final found = await _probe(agent);
    _discovered[agent] = found;
    return found;
  }

  static Future<String> _probe(String agent) async {
    // Login + interactive shell so nvm/rc-file PATH additions apply.
    final shell = Platform.environment['SHELL'] ?? '/bin/sh';
    try {
      final r = await Process.run(shell, ['-lic', 'command -v $agent']);
      if (r.exitCode == 0) {
        // Take the last non-empty line (interactive shells may emit banners).
        final line = (r.stdout as String)
            .split('\n')
            .map((s) => s.trim())
            .lastWhere((s) => s.isNotEmpty, orElse: () => '');
        if (line.startsWith('/') && File(line).existsSync()) return line;
      }
    } catch (_) {}
    final home = Platform.environment['HOME'] ?? '';
    for (final p in <String>[
      '$home/.cac/bin/$agent',
      if (agent == 'claude') '$home/.claude/local/claude',
      '/opt/homebrew/bin/$agent',
      '/usr/local/bin/$agent',
      '$home/.bun/bin/$agent',
    ]) {
      if (File(p).existsSync()) return p;
    }
    return '';
  }
}
