import 'dart:io';

import 'shell.dart';

class GitException implements Exception {
  final String message;
  GitException(this.message);
  @override
  String toString() => message;
}

// _git runs a git command in [dir] and returns stdout, throwing
// GitException(stderr) on an unexpected exit. On POSIX it goes through the login
// shell so a double-clicked app inherits the user's PATH (same as
// worktrees.dart). On Windows there is no POSIX shell — and the GUI already
// inherits the full user environment — so git runs directly, with the
// shQuote-built command reversed into an argv list (cmd.exe can't parse the
// POSIX quotes, and wrapping git in cmd.exe would also swallow its exit code).
Future<String> _git(
  String dir,
  String args, {
  Set<int> okExit = const {0},
}) async {
  final ProcessResult r;
  if (Platform.isWindows) {
    r = await Process.run('git', splitPosixCommand('-C ${shQuote(dir)} $args'));
  } else {
    final shell = Platform.environment['SHELL'] ?? '/bin/sh';
    r = await Process.run(shell, ['-lc', 'git -C ${shQuote(dir)} $args']);
  }
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

class GitTag {
  final String name;
  final String hash;
  final DateTime? date;
  final String subject;

  const GitTag({
    required this.name,
    required this.hash,
    this.date,
    this.subject = '',
  });

  String get ref => 'refs/tags/$name';
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

  bool get hasStageableChanges => modified > 0 || untracked > 0;
  bool get hasStagedChanges => staged > 0;
  bool get hasAnyChanges => !clean;
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

// _ctx renders git's context-line flag. Default 3 = git's default (no change);
// a large value (e.g. 999999) makes a diff include the whole file as context —
// used by the diff viewer's 「全部」(full-file) toggle.
String _ctx(int context) => '--unified=$context';

// gitDiffWorking = all uncommitted changes (working tree + staged) vs HEAD.
Future<String> gitDiffWorking(String dir, {int context = 3}) =>
    _git(dir, 'diff ${_ctx(context)} HEAD');

Future<String> gitDiffFileWorking(String dir, String file, {int context = 3}) {
  final f = file.trim();
  if (f.isEmpty) throw GitException('file path 不能为空');
  return _git(dir, 'diff ${_ctx(context)} HEAD -- ${shQuote(f)}');
}

// gitDiffBase = what this branch added vs [base] (default origin/main):
// `git diff <base>...HEAD` (the merge-base diff).
Future<String> gitDiffBase(String dir, String base, {int context = 3}) {
  final b = base.trim().isEmpty ? 'origin/main' : base.trim();
  return _git(dir, 'diff ${_ctx(context)} ${shQuote(b)}...HEAD');
}

Future<String> gitDiffRefs(String dir, String left, String right,
    {int context = 3}) {
  final l = left.trim();
  final r = right.trim();
  if (l.isEmpty || r.isEmpty) throw GitException('compare ref 不能为空');
  return _git(dir, 'diff ${_ctx(context)} ${shQuote(l)}...${shQuote(r)}');
}

Future<String> gitDiffRefToWorking(String dir, String ref, {int context = 3}) {
  final r = ref.trim();
  if (r.isEmpty) throw GitException('compare ref 不能为空');
  return _git(dir, 'diff ${_ctx(context)} ${shQuote(r)} --');
}

// gitDiffUntracked presents an untracked file as fully added (vs /dev/null) so
// it can be viewed in the diff viewer. `git diff --no-index` exits 1 when the
// inputs differ — the normal case here — so exit 1 is allowed.
Future<String> gitDiffUntracked(String dir, String file, {int context = 3}) {
  final f = file.trim();
  if (f.isEmpty) throw GitException('file path 不能为空');
  return _git(
    dir,
    'diff ${_ctx(context)} --no-index -- /dev/null ${shQuote(f)}',
    okExit: {0, 1},
  );
}

// gitStatus is the short porcelain status (for a quick "anything changed?").
Future<String> gitStatus(String dir) => _git(dir, 'status --porcelain');

Future<List<GitChange>> gitChanges(String dir) async {
  // --untracked-files=all lists untracked files individually instead of
  // collapsing an untracked directory to a single 'dir/' entry — a commit tool
  // stages files, not directories, and a lone 'dir/' row can't be opened/diffed.
  final out = await _git(dir, 'status --porcelain=v1 -z --untracked-files=all');
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
  // --untracked-files=all so the untracked count matches gitChanges (which lists
  // untracked files individually), not the collapsed one-per-directory count.
  final out = await _git(
    dir,
    'status --porcelain=v2 --branch --untracked-files=all',
  );
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

Future<List<GitTag>> gitTags(String dir) async {
  final out = await _git(
    dir,
    'tag --format="%(refname:short)%09%(*objectname:short)%09%(objectname:short)%09%(creatordate:iso-strict)%09%(subject)" --sort=-creatordate',
  );
  final tags = <GitTag>[];
  for (final raw in out.split('\n')) {
    final line = raw.trimRight();
    if (line.trim().isEmpty) continue;
    final parts = line.split('\t');
    if (parts.isEmpty) continue;
    final name = parts[0].trim();
    if (name.isEmpty) continue;
    final peeledHash = parts.length > 1 ? parts[1].trim() : '';
    final objectHash = parts.length > 2 ? parts[2].trim() : '';
    final dateText = parts.length > 3 ? parts[3].trim() : '';
    tags.add(
      GitTag(
        name: name,
        hash: peeledHash.isNotEmpty ? peeledHash : objectHash,
        date: dateText.isEmpty ? null : DateTime.tryParse(dateText),
        subject: parts.length > 4 ? parts.sublist(4).join('\t') : '',
      ),
    );
  }
  return tags;
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

Future<void> gitPushTag(String dir, String tag) async {
  final t = tag.trim();
  if (t.isEmpty) throw GitException('tag 不能为空');
  await _git(dir, 'push origin ${shQuote('refs/tags/$t:refs/tags/$t')}');
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

Future<String> gitStashShow(String dir, String ref, {int context = 3}) async {
  final r = ref.trim();
  if (r.isEmpty) throw GitException('stash ref 不能为空');
  return _git(
      dir, 'stash show -p ${_ctx(context)} --find-renames ${shQuote(r)}');
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

Future<String> gitShowCommit(String dir, String hash, {int context = 3}) {
  if (hash.trim().isEmpty) throw GitException('commit hash 不能为空');
  return _git(
      dir, 'show ${_ctx(context)} --format= --find-renames ${shQuote(hash)}');
}

Future<String> gitShowCommitFile(String dir, String hash, String file,
    {int context = 3}) {
  final h = hash.trim();
  final f = file.trim();
  if (h.isEmpty) throw GitException('commit hash 不能为空');
  if (f.isEmpty) throw GitException('file path 不能为空');
  return _git(
    dir,
    'show ${_ctx(context)} --format= --find-renames ${shQuote(h)} -- ${shQuote(f)}',
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

// gitDiffToPatch builds a re-appliable unified patch for the given local changes
// (working tree vs HEAD), concatenating one per-file diff after another. Backs the
// Commit panel's "Create Patch from Local Changes…" / "Copy as Patch to Clipboard".
// Named apart from ts88's commit-oriented gitFormatPatch (`git format-patch`).
//
// Emits its own `git diff` (not the viewer's gitDiffFileWorking/gitDiffUntracked)
// so it can pass `--binary` — without it a binary change is only a non-appliable
// "Binary files differ" stub. A rename passes both the old (deletion) and new
// (addition) pathspecs so `git apply` reproduces the move; untracked files are a
// whole-file add via `--no-index` (exit 1 = "differ", the normal case here).
Future<String> gitDiffToPatch(
  String dir,
  List<GitChange> changes, {
  int context = 3,
}) async {
  final buf = StringBuffer();
  for (final c in changes) {
    final String part;
    if (c.untracked) {
      part = await _git(
        dir,
        'diff ${_ctx(context)} --binary --no-index -- /dev/null ${shQuote(c.path)}',
        okExit: {0, 1},
      );
    } else if (c.oldPath != null) {
      part = await _git(
        dir,
        'diff ${_ctx(context)} --binary HEAD -- '
            '${shQuote(c.oldPath!)} ${shQuote(c.path)}',
      );
    } else {
      part = await _git(
        dir,
        'diff ${_ctx(context)} --binary HEAD -- ${shQuote(c.path)}',
      );
    }
    buf.write(part);
    if (part.isNotEmpty && !part.endsWith('\n')) buf.write('\n');
  }
  return buf.toString();
}

// gitRemoveFile deletes a changed file from the working tree. Tracked files go
// through `git rm -f` (drops them from the index and disk in one step); untracked
// files aren't in the index, so `git clean -f` removes them from disk. Backs the
// Commit panel's per-file "Delete…". Destructive — callers gate it behind a
// confirm dialog.
Future<void> gitRemoveFile(
  String dir,
  String file, {
  required bool tracked,
}) async {
  final f = file.trim();
  if (f.isEmpty) throw GitException('file path 不能为空');
  if (tracked) {
    await _git(dir, 'rm -f -- ${shQuote(f)}');
  } else {
    await _git(dir, 'clean -f -- ${shQuote(f)}');
  }
}

// ===========================================================================
// ts88 · Git Log 三栏右键菜单新增命令(append-only)。破坏性命令由 UI 层的
// confirm 门控;所有命令都在「运行时用户打开的仓库」dir 上执行。
// ===========================================================================

// gitCheckoutPathAtRev overwrites [file] in the working tree with its content at
// [ref] (`git checkout <ref> -- <file>`). Backs the diff-tree "Get from
// Revision". Destructive to the working copy — gate behind a confirm.
Future<void> gitCheckoutPathAtRev(String dir, String ref, String file) async {
  final r = ref.trim();
  final f = file.trim();
  if (r.isEmpty) throw GitException('revision 不能为空');
  if (f.isEmpty) throw GitException('file path 不能为空');
  await _git(dir, 'checkout ${shQuote(r)} -- ${shQuote(f)}');
}

// gitDiffRefFileToWorking = one file's version at [ref] vs the working tree
// (`git diff <ref> -- <file>`). Path-scoped twin of gitDiffRefToWorking so git
// emits only that file — backs the diff-tree "Compare (Before) with Local".
Future<String> gitDiffRefFileToWorking(
  String dir,
  String ref,
  String file, {
  int context = 3,
}) {
  final r = ref.trim();
  final f = file.trim();
  if (r.isEmpty) throw GitException('compare ref 不能为空');
  if (f.isEmpty) throw GitException('file path 不能为空');
  return _git(dir, 'diff ${_ctx(context)} ${shQuote(r)} -- ${shQuote(f)}');
}

// gitApplyPatch applies a whole unified patch to the working tree, forward or
// (reverse:true) in reverse — `git apply [-R] --recount`. Backs the diff-tree
// "Cherry-Pick Selected Changes" (forward) / "Revert Selected Changes"
// (reverse). Distinct from gitApplyReverse, which is the per-hunk discard on the
// Commit panel; this one takes a full multi-hunk file patch (a FileDiff.raw
// block). Throws GitException if the patch no longer applies cleanly.
Future<void> gitApplyPatch(
  String dir,
  String patch, {
  bool reverse = false,
}) async {
  final tmpDir = await Directory.systemTemp.createTemp('cc-apply');
  try {
    final tmp = File('${tmpDir.path}/p.patch');
    await tmp.writeAsString(patch.endsWith('\n') ? patch : '$patch\n');
    await _git(
      dir,
      'apply ${reverse ? '-R ' : ''}--recount ${shQuote(tmp.path)}',
    );
  } finally {
    await tmpDir.delete(recursive: true);
  }
}

// ---- commit-level history ops (Git Log 中栏右键) ----

// gitReset moves the current branch to [ref]. mode: soft (keep index+worktree),
// mixed (default, reset index), hard (discard worktree changes — destructive).
Future<void> gitReset(String dir, String ref, {String mode = 'mixed'}) async {
  final r = ref.trim();
  if (r.isEmpty) throw GitException('reset 目标不能为空');
  const allowed = {'soft', 'mixed', 'hard', 'keep', 'merge'};
  final m = allowed.contains(mode) ? mode : 'mixed';
  await _git(dir, 'reset --$m ${shQuote(r)}');
}

// gitTag creates a tag at [ref] (default HEAD). With a [message] it's an
// annotated tag (`git tag -a -m`), otherwise a lightweight tag.
Future<void> gitTag(
  String dir,
  String name, {
  String? ref,
  String? message,
}) async {
  final n = name.trim();
  if (n.isEmpty) throw GitException('tag 名不能为空');
  final target = (ref ?? '').trim();
  final tail = target.isEmpty ? '' : ' ${shQuote(target)}';
  final msg = (message ?? '').trim();
  if (msg.isEmpty) {
    await _git(dir, 'tag ${shQuote(n)}$tail');
  } else {
    await _git(dir, 'tag -a ${shQuote(n)} -m ${shQuote(msg)}$tail');
  }
}

Future<void> gitDeleteTag(String dir, String name) async {
  final n = name.trim();
  if (n.isEmpty) throw GitException('tag 名不能为空');
  await _git(dir, 'tag -d ${shQuote(n)}');
}

// gitFormatPatch returns the mail-formatted patch of a single commit
// (`git format-patch -1 --stdout <hash>`). Commit-oriented — distinct from
// ts89's gitDiffToPatch (working-tree changes) and gitApplyPatch (apply a diff).
Future<String> gitFormatPatch(String dir, String hash) {
  final h = hash.trim();
  if (h.isEmpty) throw GitException('commit hash 不能为空');
  return _git(dir, 'format-patch -1 --stdout ${shQuote(h)}');
}

// gitRemoteWebUrl turns origin's fetch URL into a browsable https URL (drops the
// trailing .git, rewrites scp/ssh/git schemes). Returns null when there's no
// origin. Backs "Open on GitHub".
Future<String?> gitRemoteWebUrl(String dir) async {
  String raw;
  try {
    raw = (await _git(dir, 'remote get-url origin')).trim();
  } catch (_) {
    return null;
  }
  if (raw.isEmpty) return null;
  var url = raw;
  final scp = RegExp(r'^[^@]+@([^:]+):(.+?)(?:\.git)?/?$').firstMatch(url);
  if (scp != null) {
    return 'https://${scp.group(1)}/${scp.group(2)}';
  }
  url = url.replaceFirst(RegExp(r'^ssh://[^@]+@'), 'https://');
  url = url.replaceFirst(RegExp(r'^git://'), 'https://');
  if (url.endsWith('.git')) url = url.substring(0, url.length - 4);
  return url;
}

// gitPushUpTo pushes commits up to and including [hash] onto origin's copy of the
// current branch (`git push origin <hash>:refs/heads/<branch>`). Backs
// "Push All up to Here".
Future<void> gitPushUpTo(String dir, String hash) async {
  final h = hash.trim();
  if (h.isEmpty) throw GitException('commit hash 不能为空');
  final branch = (await _git(dir, 'branch --show-current')).trim();
  if (branch.isEmpty) throw GitException('detached HEAD 无法 push up to here');
  await _git(dir, 'push origin ${shQuote('$h:refs/heads/$branch')}');
}

// _gitEnvRun is _git with extra environment (merged onto the parent env). Only
// the scripted interactive-rebase helpers need this — they pass
// GIT_SEQUENCE_EDITOR / GIT_EDITOR so the rebase runs unattended. Keeping it
// separate leaves the shared _git untouched.
Future<String> _gitEnvRun(
  String dir,
  String args,
  Map<String, String> env,
) async {
  final ProcessResult r;
  if (Platform.isWindows) {
    r = await Process.run(
      'git',
      splitPosixCommand('-C ${shQuote(dir)} $args'),
      environment: env,
    );
  } else {
    final shell = Platform.environment['SHELL'] ?? '/bin/sh';
    r = await Process.run(
      shell,
      ['-lc', 'git -C ${shQuote(dir)} $args'],
      environment: env,
    );
  }
  if (r.exitCode != 0) {
    final e = (r.stderr as String).trim();
    throw GitException(e.isNotEmpty ? e : 'git 失败 (exit ${r.exitCode})');
  }
  return r.stdout.toString();
}

// _rebaseTodo runs a non-interactive `git rebase -i <base>` whose todo is edited
// by a generated GIT_SEQUENCE_EDITOR script: it rewrites the command word on
// line [todoLine] to [action] (reword/drop/fixup/squash). When [newMessage] is
// non-null a GIT_EDITOR script writes it (reword); otherwise the editor accepts
// git's default (squash's pre-filled combined message / never invoked for
// fixup+drop). --autostash preserves the user's uncommitted work. A conflict
// leaves the repo mid-rebase, surfaced by the existing operation banner.
//
// Line targeting instead of hash matching: for reword/drop the target commit is
// the first (and only interesting) todo entry when basing on `<hash>^`; for
// fixup/squash-into-parent we base on `<hash>^^` so the parent is line 1 and the
// commit to meld is line 2.
Future<void> _rebaseTodo(
  String dir,
  String base, {
  required int todoLine,
  required String action,
  String? newMessage,
}) async {
  final tmp = await Directory.systemTemp.createTemp('cc-rebase');
  try {
    final seq = File('${tmp.path}/seq.sh');
    await seq.writeAsString(
      'awk -v n=$todoLine \'NR==n && /^[a-z]+ /'
      '{sub(/^[a-z]+/,"$action")}1\' "\$1" > "\$1.cc" && mv "\$1.cc" "\$1"\n',
    );
    final env = <String, String>{'GIT_SEQUENCE_EDITOR': 'sh ${seq.path}'};
    if (newMessage != null) {
      final msg = File('${tmp.path}/msg.txt');
      await msg.writeAsString(
        newMessage.endsWith('\n') ? newMessage : '$newMessage\n',
      );
      final ed = File('${tmp.path}/ed.sh');
      await ed.writeAsString('cat "${msg.path}" > "\$1"\n');
      env['GIT_EDITOR'] = 'sh ${ed.path}';
    } else {
      env['GIT_EDITOR'] = 'true';
    }
    await _gitEnvRun(dir, 'rebase -i --autostash ${shQuote(base)}', env);
  } finally {
    await tmp.delete(recursive: true);
  }
}

// gitRewordCommit rewrites [hash]'s message. For HEAD the UI uses gitCommitAmend
// instead; this handles older commits via a scripted reword rebase.
Future<void> gitRewordCommit(String dir, String hash, String message) async {
  final h = hash.trim();
  if (h.isEmpty) throw GitException('commit hash 不能为空');
  if (message.trim().isEmpty) throw GitException('commit message 不能为空');
  await _rebaseTodo(dir, '$h^', todoLine: 1, action: 'reword', newMessage: message);
}

// gitDropCommit removes [hash] from history, replaying its descendants.
Future<void> gitDropCommit(String dir, String hash) async {
  final h = hash.trim();
  if (h.isEmpty) throw GitException('commit hash 不能为空');
  await _rebaseTodo(dir, '$h^', todoLine: 1, action: 'drop');
}

// gitFixupIntoParent melds [hash] into its parent — fixup discards [hash]'s
// message, keepMessage:true squashes and keeps both messages.
Future<void> gitFixupIntoParent(
  String dir,
  String hash, {
  bool keepMessage = false,
}) async {
  final h = hash.trim();
  if (h.isEmpty) throw GitException('commit hash 不能为空');
  await _rebaseTodo(
    dir,
    '$h^^',
    todoLine: 2,
    action: keepMessage ? 'squash' : 'fixup',
  );
}
