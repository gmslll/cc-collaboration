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

class GitBranch {
  final String name;
  final bool current;
  final bool remote;
  final String? remoteName;
  final String? localName;

  const GitBranch({
    required this.name,
    required this.current,
    required this.remote,
    this.remoteName,
    this.localName,
  });
}

class GitCommit {
  final String hash;
  final String shortHash;
  final String author;
  final DateTime date;
  final String subject;
  final String refs;

  const GitCommit({
    required this.hash,
    required this.shortHash,
    required this.author,
    required this.date,
    required this.subject,
    required this.refs,
  });
}

class GitStatusSummary {
  final String branch;
  final int staged;
  final int modified;
  final int untracked;
  final int conflicted;
  final int ahead;
  final int behind;

  const GitStatusSummary({
    required this.branch,
    required this.staged,
    required this.modified,
    required this.untracked,
    required this.conflicted,
    required this.ahead,
    required this.behind,
  });

  bool get clean =>
      staged == 0 && modified == 0 && untracked == 0 && conflicted == 0;
}

class GitChange {
  final String path;
  final String indexStatus;
  final String worktreeStatus;
  final String? oldPath;

  const GitChange({
    required this.path,
    required this.indexStatus,
    required this.worktreeStatus,
    this.oldPath,
  });

  bool get staged => indexStatus != ' ' && indexStatus != '?';
  bool get unstaged => worktreeStatus != ' ' || indexStatus == '?';
  bool get untracked => indexStatus == '?' || worktreeStatus == '?';
  bool get conflicted => indexStatus == 'U' || worktreeStatus == 'U';
  String get status => '$indexStatus$worktreeStatus'.trim().isEmpty
      ? 'M'
      : '$indexStatus$worktreeStatus'.trim();
}

// gitDiffWorking = all uncommitted changes (working tree + staged) vs HEAD.
Future<String> gitDiffWorking(String dir) => _git(dir, 'diff HEAD');

// gitDiffBase = what this branch added vs [base] (default origin/main):
// `git diff <base>...HEAD` (the merge-base diff).
Future<String> gitDiffBase(String dir, String base) {
  final b = base.trim().isEmpty ? 'origin/main' : base.trim();
  return _git(dir, 'diff ${shQuote(b)}...HEAD');
}

Future<String> gitDiffRefs(String dir, String left, String right) {
  final l = left.trim();
  final r = right.trim();
  if (l.isEmpty || r.isEmpty) throw GitException('compare ref 不能为空');
  return _git(dir, 'diff ${shQuote(l)}...${shQuote(r)}');
}

// gitStatus is the short porcelain status (for a quick "anything changed?").
Future<String> gitStatus(String dir) => _git(dir, 'status --porcelain');

Future<List<GitChange>> gitChanges(String dir) async {
  final out = await _git(dir, 'status --porcelain=v1 -z');
  final parts = out.split('\x00');
  final changes = <GitChange>[];
  var i = 0;
  while (i < parts.length) {
    final entry = parts[i++];
    if (entry.isEmpty || entry.length < 4) continue;
    final x = entry[0];
    final y = entry[1];
    var path = entry.substring(3);
    String? oldPath;
    if (x == 'R' || x == 'C') {
      if (i < parts.length) oldPath = parts[i++];
    }
    changes.add(
      GitChange(
        path: path,
        indexStatus: x,
        worktreeStatus: y,
        oldPath: oldPath,
      ),
    );
  }
  changes.sort((a, b) => a.path.compareTo(b.path));
  return changes;
}

Future<GitStatusSummary> gitStatusSummary(String dir) async {
  final out = await _git(dir, 'status --porcelain=v2 --branch');
  var branch = '';
  var staged = 0;
  var modified = 0;
  var untracked = 0;
  var conflicted = 0;
  var ahead = 0;
  var behind = 0;
  for (final line in out.split('\n')) {
    if (line.startsWith('# branch.head ')) {
      branch = line.substring('# branch.head '.length).trim();
      if (branch == '(detached)') branch = 'detached';
    } else if (line.startsWith('# branch.ab ')) {
      final parts = line.substring('# branch.ab '.length).trim().split(' ');
      if (parts.length >= 2) {
        ahead = int.tryParse(parts[0].replaceFirst('+', '')) ?? 0;
        behind = int.tryParse(parts[1].replaceFirst('-', '')) ?? 0;
      }
    } else if (line.startsWith('1 ') || line.startsWith('2 ')) {
      final xy = line.length >= 4 ? line.substring(2, 4) : '..';
      if (xy[0] != '.') staged++;
      if (xy[1] != '.') modified++;
    } else if (line.startsWith('? ')) {
      untracked++;
    } else if (line.startsWith('u ')) {
      conflicted++;
    }
  }
  if (branch.isEmpty) {
    branch = (await _git(dir, 'branch --show-current')).trim();
    if (branch.isEmpty) branch = 'detached';
  }
  return GitStatusSummary(
    branch: branch,
    staged: staged,
    modified: modified,
    untracked: untracked,
    conflicted: conflicted,
    ahead: ahead,
    behind: behind,
  );
}

Future<List<GitBranch>> gitBranches(String dir) async {
  final out = await _git(
    dir,
    'branch --all --format="%(HEAD)%09%(refname:short)"',
  );
  final seen = <String>{};
  final branches = <GitBranch>[];
  for (final raw in out.split('\n')) {
    final line = raw.trimRight();
    if (line.trim().isEmpty) continue;
    final parts = line.split('\t');
    if (parts.length < 2) continue;
    final current = parts[0].trim() == '*';
    var name = parts[1].trim();
    if (name.contains(' -> ')) continue;
    final remote = name.startsWith('remotes/');
    String? remoteName;
    String? localName;
    if (remote) {
      name = name.substring('remotes/'.length);
      final slash = name.indexOf('/');
      if (slash > 0 && slash < name.length - 1) {
        remoteName = name.substring(0, slash);
        localName = name.substring(slash + 1);
      }
    }
    if (!seen.add('${remote ? 'r' : 'l'}:$name')) continue;
    branches.add(
      GitBranch(
        name: name,
        current: current,
        remote: remote,
        remoteName: remoteName,
        localName: localName,
      ),
    );
  }
  branches.sort((a, b) {
    if (a.current != b.current) return a.current ? -1 : 1;
    if (a.remote != b.remote) return a.remote ? 1 : -1;
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  });
  return branches;
}

Future<void> gitCheckout(String dir, String branch) async {
  await _git(dir, 'checkout ${shQuote(branch)}');
}

Future<void> gitCheckoutBranch(String dir, GitBranch branch) async {
  if (!branch.remote) {
    await gitCheckout(dir, branch.name);
    return;
  }
  final local = branch.localName ?? branch.name.split('/').skip(1).join('/');
  if (local.trim().isEmpty) {
    await gitCheckout(dir, branch.name);
    return;
  }
  final locals = await _git(dir, 'branch --format="%(refname:short)"');
  final exists = locals.split('\n').map((s) => s.trim()).contains(local);
  if (exists) {
    await gitCheckout(dir, local);
  } else {
    await _git(
      dir,
      'checkout --track -b ${shQuote(local)} ${shQuote(branch.name)}',
    );
  }
}

Future<void> gitCreateBranch(String dir, String branch, {String? start}) async {
  final base = (start ?? '').trim();
  await _git(
    dir,
    base.isEmpty
        ? 'checkout -b ${shQuote(branch)}'
        : 'checkout -b ${shQuote(branch)} ${shQuote(base)}',
  );
}

Future<void> gitRenameBranch(String dir, String oldName, String newName) async {
  await _git(dir, 'branch -m ${shQuote(oldName)} ${shQuote(newName)}');
}

Future<void> gitDeleteBranch(
  String dir,
  String branch, {
  bool force = false,
}) async {
  await _git(dir, 'branch ${force ? '-D' : '-d'} ${shQuote(branch)}');
}

Future<void> gitPull(String dir) async {
  await _git(dir, 'pull --ff-only');
}

Future<void> gitFetch(String dir, {bool prune = false}) async {
  await _git(dir, prune ? 'fetch --all --prune' : 'fetch --all');
}

Future<void> gitPush(String dir, {bool setUpstream = false}) async {
  if (!setUpstream) {
    await _git(dir, 'push');
    return;
  }
  final branch = (await _git(dir, 'branch --show-current')).trim();
  if (branch.isEmpty) throw GitException('detached HEAD 无法设置 upstream');
  await _git(dir, 'push -u origin ${shQuote(branch)}');
}

Future<void> gitStageAll(String dir) async {
  await _git(dir, 'add -A');
}

Future<void> gitStageFiles(String dir, List<String> files) async {
  if (files.isEmpty) return;
  await _git(dir, 'add -- ${files.map(shQuote).join(' ')}');
}

Future<void> gitUnstageAll(String dir) async {
  await _git(dir, 'restore --staged .');
}

Future<void> gitUnstageFiles(String dir, List<String> files) async {
  if (files.isEmpty) return;
  await _git(dir, 'restore --staged -- ${files.map(shQuote).join(' ')}');
}

Future<void> gitCommit(String dir, String message) async {
  final msg = message.trim();
  if (msg.isEmpty) throw GitException('commit message 不能为空');
  await _git(dir, 'commit -m ${shQuote(msg)}');
}

Future<List<GitCommit>> gitLog(String dir, {int max = 80}) async {
  final out = await _git(
    dir,
    'log --date=iso-strict --pretty=format:%H%x1f%h%x1f%an%x1f%ad%x1f%D%x1f%s%x00 -n $max --decorate=short',
  );
  final commits = <GitCommit>[];
  for (final rec in out.split('\x00')) {
    if (rec.trim().isEmpty) continue;
    final parts = rec.split('\x1f');
    if (parts.length < 6) continue;
    commits.add(
      GitCommit(
        hash: parts[0],
        shortHash: parts[1],
        author: parts[2],
        date:
            DateTime.tryParse(parts[3]) ??
            DateTime.fromMillisecondsSinceEpoch(0),
        refs: parts[4],
        subject: parts.sublist(5).join('\x1f'),
      ),
    );
  }
  return commits;
}

Future<String> gitShowCommit(String dir, String hash) {
  if (hash.trim().isEmpty) throw GitException('commit hash 不能为空');
  return _git(dir, 'show --format= --find-renames ${shQuote(hash)}');
}

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
