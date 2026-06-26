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
Future<String> _git(
  String dir,
  String args, {
  Set<int> okExit = const {0},
}) async {
  final shell = Platform.environment['SHELL'] ?? '/bin/sh';
  final r = await Process.run(shell, ['-lc', 'git -C ${shQuote(dir)} $args']);
  if (!okExit.contains(r.exitCode)) {
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
  final String upstream;
  final int ahead;
  final int behind;
  final String lastHash;
  final String lastSubject;
  final DateTime? lastDate;

  const GitBranch({
    required this.name,
    required this.current,
    required this.remote,
    this.remoteName,
    this.localName,
    this.upstream = '',
    this.ahead = 0,
    this.behind = 0,
    this.lastHash = '',
    this.lastSubject = '',
    this.lastDate,
  });
}

class GitCommit {
  final String hash;
  final String shortHash;
  final String author;
  final DateTime date;
  final String subject;
  final String refs;
  final List<String> parents; // full parent hashes, child -> older parent

  const GitCommit({
    required this.hash,
    required this.shortHash,
    required this.author,
    required this.date,
    required this.subject,
    required this.refs,
    this.parents = const [],
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

class GitBlameLine {
  final int line;
  final String hash;
  final String author;
  final DateTime date;
  final String summary;
  final String content;

  const GitBlameLine({
    required this.line,
    required this.hash,
    required this.author,
    required this.date,
    required this.summary,
    required this.content,
  });
}

class GitStash {
  final String ref;
  final String branch;
  final String subject;

  const GitStash({
    required this.ref,
    required this.branch,
    required this.subject,
  });
}

class GitOperationState {
  final String kind;
  final String label;
  final bool canContinue;
  final bool canAbort;

  const GitOperationState({
    required this.kind,
    required this.label,
    required this.canContinue,
    required this.canAbort,
  });
}

// gitDiffWorking = all uncommitted changes (working tree + staged) vs HEAD.
Future<String> gitDiffWorking(String dir) => _git(dir, 'diff HEAD');

Future<String> gitDiffFileWorking(String dir, String file) {
  final f = file.trim();
  if (f.isEmpty) throw GitException('file path 不能为空');
  return _git(dir, 'diff HEAD -- ${shQuote(f)}');
}

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

Future<String> gitDiffRefToWorking(String dir, String ref) {
  final r = ref.trim();
  if (r.isEmpty) throw GitException('compare ref 不能为空');
  return _git(dir, 'diff ${shQuote(r)} --');
}

// gitDiffUntracked presents an untracked file as fully added (vs /dev/null) so
// it can be viewed in the diff viewer. `git diff --no-index` exits 1 when the
// inputs differ — the normal case here — so exit 1 is allowed.
Future<String> gitDiffUntracked(String dir, String file) {
  final f = file.trim();
  if (f.isEmpty) throw GitException('file path 不能为空');
  return _git(
    dir,
    'diff --no-index -- /dev/null ${shQuote(f)}',
    okExit: {0, 1},
  );
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

Future<GitOperationState?> gitOperationState(String dir) async {
  final gitDir = (await _git(dir, 'rev-parse --git-dir')).trim();
  final root = Directory(dir);
  final stateDir = gitDir.startsWith('/')
      ? Directory(gitDir)
      : Directory('${root.path}/$gitDir');
  bool exists(String name) => File('${stateDir.path}/$name').existsSync();
  bool dirExists(String name) =>
      Directory('${stateDir.path}/$name').existsSync();

  if (dirExists('rebase-merge') || dirExists('rebase-apply')) {
    return const GitOperationState(
      kind: 'rebase',
      label: 'Rebase in progress',
      canContinue: true,
      canAbort: true,
    );
  }
  if (exists('MERGE_HEAD')) {
    return const GitOperationState(
      kind: 'merge',
      label: 'Merge in progress',
      canContinue: true,
      canAbort: true,
    );
  }
  if (exists('CHERRY_PICK_HEAD')) {
    return const GitOperationState(
      kind: 'cherry-pick',
      label: 'Cherry-pick in progress',
      canContinue: true,
      canAbort: true,
    );
  }
  if (exists('REVERT_HEAD')) {
    return const GitOperationState(
      kind: 'revert',
      label: 'Revert in progress',
      canContinue: true,
      canAbort: true,
    );
  }
  return null;
}

Future<List<GitBranch>> gitBranches(String dir) async {
  final out = await _git(
    dir,
    'branch --all --format="%(HEAD)%09%(refname:short)%09%(upstream:short)%09%(ahead-behind:HEAD)%09%(objectname:short)%09%(committerdate:iso-strict)%09%(contents:subject)"',
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
    final upstream = parts.length > 2 ? parts[2].trim() : '';
    final aheadBehind = parts.length > 3 ? parts[3].trim() : '';
    var ahead = 0;
    var behind = 0;
    final abParts = aheadBehind.split(RegExp(r'\s+'));
    if (abParts.length >= 2) {
      ahead = int.tryParse(abParts[0].replaceFirst('+', '')) ?? 0;
      behind = int.tryParse(abParts[1].replaceFirst('-', '')) ?? 0;
    }
    final lastHash = parts.length > 4 ? parts[4].trim() : '';
    final lastDateText = parts.length > 5 ? parts[5].trim() : '';
    final lastDate = lastDateText.isEmpty
        ? null
        : DateTime.tryParse(lastDateText);
    final lastSubject = parts.length > 6 ? parts.sublist(6).join('\t') : '';
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
        upstream: upstream,
        ahead: ahead,
        behind: behind,
        lastHash: lastHash,
        lastSubject: lastSubject,
        lastDate: lastDate,
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

Future<void> gitPushDeleteRemoteBranch(String dir, GitBranch branch) async {
  if (!branch.remote) throw GitException('只能删除远端分支');
  final remote = (branch.remoteName ?? '').trim();
  final local = (branch.localName ?? '').trim();
  if (remote.isEmpty || local.isEmpty) {
    throw GitException('远端分支格式不正确');
  }
  await _git(dir, 'push ${shQuote(remote)} --delete ${shQuote(local)}');
}

Future<void> gitMergeBranch(String dir, String branch) async {
  final b = branch.trim();
  if (b.isEmpty) throw GitException('branch 不能为空');
  await _git(dir, 'merge --no-ff ${shQuote(b)}');
}

Future<void> gitRebaseOnto(String dir, String branch) async {
  final b = branch.trim();
  if (b.isEmpty) throw GitException('branch 不能为空');
  await _git(dir, 'rebase ${shQuote(b)}');
}

Future<void> gitPull(String dir) async {
  await _git(dir, 'pull --ff-only');
}

Future<void> gitPullRebase(String dir) async {
  await _git(dir, 'pull --rebase');
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

Future<void> gitPushBranch(
  String dir,
  String branch, {
  bool setUpstream = false,
}) async {
  final b = branch.trim();
  if (b.isEmpty) throw GitException('branch 不能为空');
  await _git(dir, 'push ${setUpstream ? '-u ' : ''}origin ${shQuote(b)}');
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

Future<void> gitCommitAmend(String dir, String message) async {
  final msg = message.trim();
  if (msg.isEmpty) {
    await _git(dir, 'commit --amend --no-edit');
    return;
  }
  await _git(dir, 'commit --amend -m ${shQuote(msg)}');
}

Future<List<GitStash>> gitStashes(String dir) async {
  final out = await _git(dir, 'stash list --format=%gd%x1f%gs');
  final stashes = <GitStash>[];
  for (final line in out.split('\n')) {
    if (line.trim().isEmpty) continue;
    final parts = line.split('\x1f');
    final ref = parts.first.trim();
    final subject = parts.length > 1 ? parts.sublist(1).join('\x1f') : '';
    var branch = '';
    final m = RegExp(r'^On ([^:]+):\s*(.*)$').firstMatch(subject);
    if (m != null) branch = m.group(1) ?? '';
    stashes.add(GitStash(ref: ref, branch: branch, subject: subject));
  }
  return stashes;
}

Future<void> gitStashPush(
  String dir,
  String message, {
  bool includeUntracked = true,
  List<String> files = const [],
}) async {
  final msg = message.trim();
  final include = includeUntracked ? '-u ' : '';
  final pathspec = files.isEmpty ? '' : ' -- ${files.map(shQuote).join(' ')}';
  await _git(
    dir,
    'stash push $include-m ${shQuote(msg.isEmpty ? 'WIP' : msg)}$pathspec',
  );
}

Future<String> gitStashShow(String dir, String ref) async {
  final r = ref.trim();
  if (r.isEmpty) throw GitException('stash ref 不能为空');
  return _git(dir, 'stash show -p --find-renames ${shQuote(r)}');
}

Future<void> gitStashApply(String dir, String ref) async {
  await _git(dir, 'stash apply ${shQuote(ref)}');
}

Future<void> gitStashPop(String dir, String ref) async {
  await _git(dir, 'stash pop ${shQuote(ref)}');
}

Future<void> gitStashDrop(String dir, String ref) async {
  await _git(dir, 'stash drop ${shQuote(ref)}');
}

Future<List<GitCommit>> gitLog(
  String dir, {
  int max = 80,
  bool allBranches = false,
  String ref = '',
  String pathFilter = '',
}) async {
  final r = ref.trim();
  final path = pathFilter.trim();
  final pathspec = path.isEmpty ? '' : ' -- ${shQuote(path)}';
  final scope = r.isNotEmpty ? '${shQuote(r)} ' : (allBranches ? '--all ' : '');
  final out = await _git(
    dir,
    'log $scope--date=iso-strict --topo-order --pretty=format:%H%x1f%h%x1f%an%x1f%ad%x1f%D%x1f%P%x1f%s%x00 -n $max --decorate=short$pathspec',
  );
  return parseGitLog(out);
}

Future<List<GitCommit>> gitLogFile(
  String dir,
  String file, {
  int max = 80,
}) async {
  final f = file.trim();
  if (f.isEmpty) throw GitException('file path 不能为空');
  final out = await _git(
    dir,
    'log --follow --date=iso-strict --pretty=format:%H%x1f%h%x1f%an%x1f%ad%x1f%D%x1f%P%x1f%s%x00 -n $max --decorate=short -- ${shQuote(f)}',
  );
  return parseGitLog(out);
}

List<GitCommit> parseGitLog(String out) {
  final commits = <GitCommit>[];
  for (final rec in out.split('\x00')) {
    // git 在记录之间插入 \n,split('\x00') 后除首条外每条都带前导 \n,会污染
    // parts[0](hash)成 "\n<hash>",令 computeGraphRows 的 present.contains(parent)
    // 恒为 false、拓扑连接边全丢。trim 去掉首尾(首=该 \n,尾=subject 末尾空白)。
    final trimmed = rec.trim();
    if (trimmed.isEmpty) continue;
    final parts = trimmed.split('\x1f');
    if (parts.length < 7) continue;
    commits.add(
      GitCommit(
        hash: parts[0],
        shortHash: parts[1],
        author: parts[2],
        date:
            DateTime.tryParse(parts[3]) ??
            DateTime.fromMillisecondsSinceEpoch(0),
        refs: parts[4],
        parents: parts[5].split(' ').where((s) => s.isNotEmpty).toList(),
        subject: parts.sublist(6).join('\x1f'),
      ),
    );
  }
  return commits;
}

Future<String> gitShowCommit(String dir, String hash) {
  if (hash.trim().isEmpty) throw GitException('commit hash 不能为空');
  return _git(dir, 'show --format= --find-renames ${shQuote(hash)}');
}

Future<String> gitShowCommitFile(String dir, String hash, String file) {
  final h = hash.trim();
  final f = file.trim();
  if (h.isEmpty) throw GitException('commit hash 不能为空');
  if (f.isEmpty) throw GitException('file path 不能为空');
  return _git(
    dir,
    'show --format= --find-renames ${shQuote(h)} -- ${shQuote(f)}',
  );
}

Future<void> gitCherryPick(String dir, String hash) async {
  final h = hash.trim();
  if (h.isEmpty) throw GitException('commit hash 不能为空');
  await _git(dir, 'cherry-pick ${shQuote(h)}');
}

Future<void> gitRevertCommit(String dir, String hash) async {
  final h = hash.trim();
  if (h.isEmpty) throw GitException('commit hash 不能为空');
  await _git(dir, 'revert --no-edit ${shQuote(h)}');
}

Future<void> gitContinueOperation(String dir, String kind) async {
  switch (kind) {
    case 'rebase':
      await _git(dir, 'rebase --continue');
    case 'merge':
      await _git(dir, 'merge --continue');
    case 'cherry-pick':
      await _git(dir, 'cherry-pick --continue');
    case 'revert':
      await _git(dir, 'revert --continue');
    default:
      throw GitException('$kind 不支持 continue');
  }
}

Future<void> gitAbortOperation(String dir, String kind) async {
  switch (kind) {
    case 'rebase':
      await _git(dir, 'rebase --abort');
    case 'merge':
      await _git(dir, 'merge --abort');
    case 'cherry-pick':
      await _git(dir, 'cherry-pick --abort');
    case 'revert':
      await _git(dir, 'revert --abort');
    default:
      throw GitException('$kind 不支持 abort');
  }
}

Future<List<GitBlameLine>> gitBlame(String dir, String file) async {
  final out = await _git(dir, 'blame --line-porcelain -- ${shQuote(file)}');
  final lines = <GitBlameLine>[];
  String hash = '';
  var lineNo = 0;
  var author = '';
  var time = 0;
  var summary = '';
  for (final raw in out.split('\n')) {
    if (raw.isEmpty) continue;
    final header = RegExp(r'^([0-9a-f]{40}) \d+ (\d+)').firstMatch(raw);
    if (header != null) {
      hash = header.group(1)!;
      lineNo = int.tryParse(header.group(2)!) ?? 0;
      author = '';
      time = 0;
      summary = '';
    } else if (raw.startsWith('author ')) {
      author = raw.substring('author '.length);
    } else if (raw.startsWith('author-time ')) {
      time = int.tryParse(raw.substring('author-time '.length)) ?? 0;
    } else if (raw.startsWith('summary ')) {
      summary = raw.substring('summary '.length);
    } else if (raw.startsWith('\t')) {
      lines.add(
        GitBlameLine(
          line: lineNo,
          hash: hash,
          author: author,
          date: DateTime.fromMillisecondsSinceEpoch(time * 1000),
          summary: summary,
          content: raw.substring(1),
        ),
      );
    }
  }
  return lines;
}

// gitRestore discards a file's uncommitted changes (git checkout -- <file>),
// taking it back to HEAD/index. [file] is relative to [dir].
Future<void> gitRestore(String dir, String file) async {
  await _git(dir, 'checkout -- ${shQuote(file)}');
}

Future<void> gitRestoreChanges(String dir, List<GitChange> changes) async {
  if (changes.isEmpty) return;
  final untracked = changes
      .where((c) => c.untracked)
      .map((c) => c.path)
      .toList();
  final tracked = changes
      .where((c) => !c.untracked)
      .map((c) => c.path)
      .toList();
  if (tracked.isNotEmpty) {
    await _git(
      dir,
      'restore --staged --worktree -- ${tracked.map(shQuote).join(' ')}',
    );
  }
  if (untracked.isNotEmpty) {
    await _git(dir, 'clean -f -- ${untracked.map(shQuote).join(' ')}');
  }
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
