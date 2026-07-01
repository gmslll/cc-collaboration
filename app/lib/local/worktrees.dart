import 'dart:io';

import 'path_utils.dart';
import 'shell.dart';

class Worktree {
  final String path;
  final String branch; // short branch; empty when detached
  const Worktree(this.path, this.branch);

  String get name {
    final name = pathBaseName(path);
    return name.isEmpty ? path : name;
  }

  // handoff-pickup worktrees use branch h_<shortid>[_<branch>] (config.HandoffWorktreeBranch).
  bool get isHandoff => branch.startsWith('h_');
}

// listWorktrees runs `git worktree list --porcelain` in [projectPath] (via the
// login shell so a double-clicked app inherits the user's PATH) and parses the
// path + branch of each worktree. Returns [] on any error (not a repo, no git).
Future<List<Worktree>> listWorktrees(String projectPath) async {
  try {
    final ProcessResult r;
    if (Platform.isWindows) {
      // No POSIX shell on Windows; run git directly (the GUI inherits PATH).
      r = await Process.run('git', [
        '-C',
        projectPath,
        'worktree',
        'list',
        '--porcelain',
      ]);
    } else {
      final shell = Platform.environment['SHELL'] ?? '/bin/sh';
      r = await Process.run(shell, [
        '-lc',
        'git -C ${shQuote(projectPath)} worktree list --porcelain',
      ]);
    }
    if (r.exitCode != 0) return const [];

    final res = <Worktree>[];
    String? path;
    String branch = '';
    for (final line in r.stdout.toString().split('\n')) {
      if (line.startsWith('worktree ')) {
        if (path != null) res.add(Worktree(path, branch));
        path = line.substring('worktree '.length).trim();
        branch = '';
      } else if (line.startsWith('branch ')) {
        var b = line.substring('branch '.length).trim();
        if (b.startsWith('refs/heads/')) b = b.substring('refs/heads/'.length);
        branch = b;
      }
    }
    if (path != null) res.add(Worktree(path, branch));
    return res;
  } catch (_) {
    return const [];
  }
}
