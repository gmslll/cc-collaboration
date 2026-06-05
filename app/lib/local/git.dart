import 'dart:io';

import 'shell.dart';

class GitException implements Exception {
  final String message;
  GitException(this.message);
  @override
  String toString() => message;
}

// _git runs a git command in [dir] via the login shell (so a double-clicked app
// inherits the user's PATH, same as worktrees.dart) and returns stdout. Throws
// GitException(stderr) on a non-zero exit.
Future<String> _git(String dir, String args) async {
  final shell = Platform.environment['SHELL'] ?? '/bin/sh';
  final r = await Process.run(shell, ['-lc', 'git -C ${shQuote(dir)} $args']);
  if (r.exitCode != 0) {
    final err = (r.stderr as String).trim();
    throw GitException(err.isNotEmpty ? err : 'git 失败 (exit ${r.exitCode})');
  }
  return r.stdout.toString();
}

// gitDiffWorking = all uncommitted changes (working tree + staged) vs HEAD.
Future<String> gitDiffWorking(String dir) => _git(dir, 'diff HEAD');

// gitDiffBase = what this branch added vs [base] (default origin/main):
// `git diff <base>...HEAD` (the merge-base diff).
Future<String> gitDiffBase(String dir, String base) {
  final b = base.trim().isEmpty ? 'origin/main' : base.trim();
  return _git(dir, 'diff ${shQuote(b)}...HEAD');
}

// gitStatus is the short porcelain status (for a quick "anything changed?").
Future<String> gitStatus(String dir) => _git(dir, 'status --porcelain');

// gitRestore discards a file's uncommitted changes (git checkout -- <file>),
// taking it back to HEAD/index. [file] is relative to [dir].
Future<void> gitRestore(String dir, String file) async {
  await _git(dir, 'checkout -- ${shQuote(file)}');
}

// gitApplyReverse reverts a single-hunk patch (a file header + one `@@` hunk)
// against the working tree — `git apply -R --recount`. Used for per-hunk
// discard. Throws GitException if the hunk no longer applies.
Future<void> gitApplyReverse(String dir, String patch) async {
  final tmpDir = await Directory.systemTemp.createTemp('cc-revert');
  try {
    final tmp = File('${tmpDir.path}/p.patch');
    await tmp.writeAsString(patch.endsWith('\n') ? patch : '$patch\n');
    await _git(dir, 'apply -R --recount ${shQuote(tmp.path)}');
  } finally {
    await tmpDir.delete(recursive: true);
  }
}
