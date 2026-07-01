import 'dart:convert';
import 'dart:io';

import 'shell.dart';

class PickupResult {
  final String worktreeDir;
  final String materializeDir;
  final String agentCmd;
  final bool acked;
  PickupResult(this.worktreeDir, this.materializeDir, this.agentCmd, this.acked);
}

class CliException implements Exception {
  final String message;
  CliException(this.message);
  @override
  String toString() => message;
}

// Cli shells the existing `cc-handoff` binary for local ops the relay can't do.
// It runs through the user's login shell so PATH resolves even when the GUI app
// is launched outside a terminal (a double-clicked .app has a minimal PATH).
class Cli {
  static String _shell() => Platform.environment['SHELL'] ?? '/bin/sh';

  static String? _binPath;

  // _bin resolves the cc-handoff executable. Desktop packaging drops a copy next
  // to the GUI executable (see scripts/package.sh / package.ps1) so the app
  // works with no system install; if none is bundled (dev runs, or a system
  // install), fall back to the bare name resolved via PATH.
  static String _bin() {
    final cached = _binPath;
    if (cached != null) return cached;
    final name = Platform.isWindows ? 'cc-handoff.exe' : 'cc-handoff';
    // Packaging drops the binary next to the GUI executable (.app/Contents/MacOS
    // on macOS, the runner Release\ dir on Windows).
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final bundled = '$exeDir${Platform.pathSeparator}$name';
    if (File(bundled).existsSync()) return _binPath = bundled;
    return _binPath = name; // PATH fallback (dev runs / system install)
  }

  // binPath exposes the resolved cc-handoff executable so the app can hand its
  // absolute path to spawned sessions (CC_HANDOFF_BIN) — a bundled binary isn't
  // on the agent's PATH, so `"$CC_HANDOFF_BIN" msg …` is the stable invocation.
  static String binPath() => _bin();

  // _exec runs cc-handoff with [args]. On POSIX it goes through the login shell
  // so the binary inherits the user's PATH (a double-clicked .app has a minimal
  // PATH) and can find git / claude / codex; on Windows the GUI already inherits
  // the full user environment, so the executable is run directly.
  static Future<ProcessResult> _exec(List<String> args) {
    final bin = _bin();
    if (Platform.isWindows) return Process.run(bin, args);
    final cmd = '${shQuote(bin)} ${args.map(shQuote).join(' ')}';
    return Process.run(_shell(), ['-lc', cmd]);
  }

  // installBusHooks wires the local-bus PostToolUse + Stop hooks into the user's
  // agent config (claude ~/.claude/settings.json, codex ~/.codex/hooks.json) so
  // a sibling's message can interrupt a busy agent session mid-turn. Idempotent
  // and env-guarded ($CC_BUS_DIR) so it stays scoped to app-spawned sessions;
  // fire-and-forget on app start with errors swallowed.
  static Future<void> installBusHooks() async {
    try {
      await _exec(['bus-hook', 'install']);
    } catch (_) {}
  }

  // pickup carves a worktree for the handoff in repoPath and returns the
  // worktree dir + the interactive agent command to run in the terminal.
  static Future<PickupResult> pickup(String id, String repoPath) async {
    final res = await _exec([
      'pickup', id, '--repo', repoPath, '--worktree', '--json',
    ]);
    if (res.exitCode != 0) {
      final err = (res.stderr as String).trim();
      throw CliException(err.isNotEmpty ? err : 'pickup 失败 (exit ${res.exitCode})');
    }
    final out = (res.stdout as String).trim();
    final Map<String, dynamic> j;
    try {
      j = jsonDecode(out) as Map<String, dynamic>;
    } catch (_) {
      throw CliException('无法解析 pickup 输出: $out');
    }
    return PickupResult(
      (j['worktree_dir'] ?? '').toString(),
      (j['materialize_dir'] ?? '').toString(),
      (j['agent_cmd'] ?? '').toString(),
      j['acked'] == true,
    );
  }

  // run executes `cc-handoff <args>` and returns trimmed stdout; throws
  // CliException(stderr) on non-zero exit.
  static Future<String> run(List<String> args) async {
    final res = await _exec(args);
    if (res.exitCode != 0) {
      final err = (res.stderr as String).trim();
      throw CliException(err.isNotEmpty ? err : '命令失败 (exit ${res.exitCode})');
    }
    return (res.stdout as String).trim();
  }

  // --- workspace / project management (config.toml round-trips via SaveUser) ---

  // --path goes BEFORE the name so this works even against an older cc-handoff
  // whose `workspace create` uses plain flag.Parse (stops at the first
  // positional) — flags-first parses cleanly there; the fixed CLI (parseFlexible)
  // accepts either order.
  static Future<void> workspaceCreate(String name, {String? path}) => run([
        'workspace', 'create',
        if (path != null && path.trim().isNotEmpty) ...['--path', path.trim()],
        name,
      ]);

  static Future<void> workspaceAdd(String name, String source) =>
      run(['workspace', 'add', name, source]);

  // workspaceImport scans [dir] for git repos and registers each as a project
  // (in place — never moved/cloned) in workspace [name] (default: basename of
  // dir). Returns the CLI's --json summary: {workspace, created, scanned,
  // added[], skipped[]}.
  static Future<String> workspaceImport(String dir, {String? name}) => run([
        'workspace', 'import', dir,
        if (name != null && name.trim().isNotEmpty) ...['--name', name.trim()],
        '--json',
      ]);

  static Future<void> workspaceRemove(String name) =>
      run(['workspace', 'remove', name]);

  static Future<void> projectRemove(String wsName, String projName) =>
      run(['workspace', 'remove', wsName, projName]);

  // --- worktree management (pure git; project resolved by name + workspace) ---

  static Future<void> worktreeAdd(String project, String branch,
          {String? workspace, String? start}) =>
      run([
        'worktree', 'add', project, branch,
        if (workspace != null && workspace.isNotEmpty) ...['--workspace', workspace],
        if (start != null && start.trim().isNotEmpty) ...['--start', start.trim()],
      ]);

  static Future<void> worktreeRemove(String project, String branch,
          {String? workspace, bool force = false}) =>
      run([
        'worktree', 'remove', project, branch,
        if (workspace != null && workspace.isNotEmpty) ...['--workspace', workspace],
        if (force) '--force',
      ]);

  // --- config editing (user-level + per-workspace; round-trips via SaveUser) ---

  // configSet writes the user-level config fields. Pass only what you want to
  // change (null = leave; '' = clear). One atomic `config set` per call.
  static Future<void> configSet({
    String? relayUrl,
    String? token,
    String? identity,
    String? agent,
    String? claudeCommand,
    String? codexCommand,
    String? workspaceRoot,
    String? gradeCommand,
    String? linearToken,
    String? githubToken,
    String? terminalApp,
  }) =>
      run([
        'config', 'set',
        if (relayUrl != null) ...['--relay-url', relayUrl],
        if (token != null) ...['--token', token],
        if (identity != null) ...['--identity', identity],
        if (agent != null) ...['--agent', agent],
        if (claudeCommand != null) ...['--claude-command', claudeCommand],
        if (codexCommand != null) ...['--codex-command', codexCommand],
        if (workspaceRoot != null) ...['--workspace-root', workspaceRoot],
        if (gradeCommand != null) ...['--grade-command', gradeCommand],
        if (linearToken != null) ...['--linear-token', linearToken],
        if (githubToken != null) ...['--github-token', githubToken],
        if (terminalApp != null) ...['--terminal-app', terminalApp],
      ]);

  static Future<void> workspaceSet(String name,
          {String? preLaunch, String? editor, String? agent}) =>
      run([
        'workspace', 'set', name,
        if (preLaunch != null) ...['--pre-launch', preLaunch],
        if (editor != null) ...['--editor', editor],
        if (agent != null) ...['--agent', agent],
      ]);
}
