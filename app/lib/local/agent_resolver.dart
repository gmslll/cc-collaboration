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
    if (Platform.isWindows) return _probeWindows(agent);
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

  // _probeWindows resolves the agent on Windows: `where` (the PATH lookup the
  // GUI inherits the full environment for), then the npm-global install spot
  // (%AppData%\npm\<agent>.cmd) most CLIs land in. Returns '' to fall back to
  // the bare name. POSIX `command -v` / ~/.cac|.bun paths don't apply here.
  static Future<String> _probeWindows(String agent) async {
    try {
      final r = await Process.run('where', [agent]);
      if (r.exitCode == 0) {
        final lines = (r.stdout as String)
            .split('\n')
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toList();
        // where.exe lists EVERY match. An npm-installed agent has both an
        // extensionless Unix wrapper (`claude`, a sh script cmd.exe can't run)
        // and a `claude.cmd` shim — and where lists the Unix one first. Prefer a
        // shim cmd.exe can actually launch via `/c` (.cmd/.bat/.exe), else fall
        // back to the first hit.
        if (lines.isNotEmpty) {
          final pick = lines.firstWhere(_runnableOnWindows, orElse: () => lines.first);
          if (File(pick).existsSync()) return pick;
        }
      }
    } catch (_) {}
    final appData = Platform.environment['APPDATA'] ?? '';
    if (appData.isNotEmpty) {
      for (final p in <String>[
        '$appData\\npm\\$agent.cmd',
        '$appData\\npm\\$agent.exe',
      ]) {
        if (File(p).existsSync()) return p;
      }
    }
    return '';
  }

  // _runnableOnWindows is true for a path cmd.exe can launch via `/c` — one
  // ending in a PATHEXT executable extension. Excludes npm's extensionless sh
  // shim and the .ps1 variant, which cmd.exe can't execute.
  static bool _runnableOnWindows(String path) {
    final p = path.toLowerCase();
    return p.endsWith('.cmd') ||
        p.endsWith('.exe') ||
        p.endsWith('.bat') ||
        p.endsWith('.com');
  }
}
