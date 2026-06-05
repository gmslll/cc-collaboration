import 'dart:convert';
import 'dart:io';

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

  // pickup carves a worktree for the handoff in repoPath and returns the
  // worktree dir + the interactive agent command to run in the terminal.
  static Future<PickupResult> pickup(String id, String repoPath) async {
    final cmd =
        "cc-handoff pickup '${_esc(id)}' --repo '${_esc(repoPath)}' --worktree --json";
    final res = await Process.run(_shell(), ['-lc', cmd]);
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

  // run executes `cc-handoff <args>` via the login shell and returns trimmed
  // stdout; throws CliException(stderr) on non-zero exit. Each arg is
  // single-quoted so paths / branches with spaces are safe.
  static Future<String> run(List<String> args) async {
    final cmd = 'cc-handoff ${args.map((a) => "'${_esc(a)}'").join(' ')}';
    final res = await Process.run(_shell(), ['-lc', cmd]);
    if (res.exitCode != 0) {
      final err = (res.stderr as String).trim();
      throw CliException(err.isNotEmpty ? err : '命令失败 (exit ${res.exitCode})');
    }
    return (res.stdout as String).trim();
  }

  // --- workspace / project management (config.toml round-trips via SaveUser) ---

  static Future<void> workspaceCreate(String name, {String? path}) => run([
        'workspace', 'create', name,
        if (path != null && path.trim().isNotEmpty) ...['--path', path.trim()],
      ]);

  static Future<void> workspaceAdd(String name, String source) =>
      run(['workspace', 'add', name, source]);

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
    String? workspaceRoot,
    String? gradeCommand,
    String? linearToken,
    String? githubToken,
  }) =>
      run([
        'config', 'set',
        if (relayUrl != null) ...['--relay-url', relayUrl],
        if (token != null) ...['--token', token],
        if (identity != null) ...['--identity', identity],
        if (agent != null) ...['--agent', agent],
        if (workspaceRoot != null) ...['--workspace-root', workspaceRoot],
        if (gradeCommand != null) ...['--grade-command', gradeCommand],
        if (linearToken != null) ...['--linear-token', linearToken],
        if (githubToken != null) ...['--github-token', githubToken],
      ]);

  static Future<void> workspaceSet(String name,
          {String? preLaunch, String? editor, String? agent}) =>
      run([
        'workspace', 'set', name,
        if (preLaunch != null) ...['--pre-launch', preLaunch],
        if (editor != null) ...['--editor', editor],
        if (agent != null) ...['--agent', agent],
      ]);

  static String _esc(String s) => s.replaceAll("'", "'\\''");
}
