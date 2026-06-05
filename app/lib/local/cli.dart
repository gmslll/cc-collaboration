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

  static String _esc(String s) => s.replaceAll("'", "'\\''");
}
