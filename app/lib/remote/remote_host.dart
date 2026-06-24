import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../local/git.dart';
import '../local/worktrees.dart';
import '../screens/terminal_pane.dart';
import '../widgets.dart' show kIgnoredEntries;
import 'remote_channel.dart';

// A project root the host exposes to remote clients (workspace = owning ws name).
class RemoteRoot {
  final String name;
  final String path;
  final String workspace;
  const RemoteRoot(this.name, this.path, this.workspace);
}

// RemoteHost shares this desktop's workspace (terminal sessions + project files)
// to the user's phone, brokered by the relay (see RemoteChannel for transport).
// Opt-in: nothing is exposed until [enable]. The relay only pipes between the
// SAME identity, so only the user's own devices can connect. File access is
// hard-scoped to the advertised project roots (traversal is normalized away).
class RemoteHost extends RemoteChannel {
  final List<TerminalSession> Function() sessions;
  final List<RemoteRoot> Function() roots;
  // Write actions that must touch WorkspacePage state (launch/close/rename a
  // session). Null on hosts that only expose read access.
  final void Function(String projectPath, String agent)? onNewSession;
  final void Function(String sid)? onCloseSession;
  final void Function(String sid, String name)? onRenameSession;
  // Config mutations (worktree/workspace/project add/remove) — run the matching
  // Cli command, reload config, then call broadcastRoots. Null = read-only host.
  final Future<void> Function(String action, Map<String, dynamic> args)?
  onConfigAction;

  RemoteHost({
    required super.relayUrl,
    required super.token,
    required this.sessions,
    required this.roots,
    this.onNewSession,
    this.onCloseSession,
    this.onRenameSession,
    this.onConfigAction,
  }) : super(role: 'host');

  int _clients = 0;
  final Map<String, Set<int>> _watchers = {}; // session id -> watching clients
  static const int _maxRead = 2 * 1024 * 1024; // 2MB file-read cap

  bool get sharing => active;
  int get clientCount => _clients;

  Future<void> enable() async => start();
  void disable() => stop();

  @override
  void onDisconnected() {
    _clients = 0;
    _detachAllSessions();
  }

  @override
  void onPeer(int connId, String role, bool connected) {
    if (role != 'client') return;
    if (connected) {
      _clients++;
    } else {
      _clients--;
      _dropClient(connId);
    }
    notifyListeners();
  }

  @override
  void onFrame(Map<String, dynamic> f) {
    switch (f['t']) {
      case 'list':
        final from = (f['from'] as num?)?.toInt();
        if (from != null) _replyList(from);
      case 'term.open':
        _termOpen(f);
      case 'term.input':
        _sessionById(f['sid'] as String?)?.sendText((f['d'] as String?) ?? '');
      case 'term.resize':
        _sessionById(f['sid'] as String?)?.resizeFromRemote(
          (f['rows'] as num?)?.toInt() ?? 0,
          (f['cols'] as num?)?.toInt() ?? 0,
        );
      case 'session.new':
        onNewSession?.call(
          (f['project'] as String?) ?? '',
          (f['agent'] as String?) ?? 'claude',
        );
      case 'session.close':
        final sid = f['sid'] as String?;
        if (sid != null) onCloseSession?.call(sid);
      case 'session.rename':
        final sid = f['sid'] as String?;
        final name = f['name'] as String?;
        if (sid != null && name != null) onRenameSession?.call(sid, name);
      case 'fs.list':
        _fsList(f);
      case 'fs.read':
        _fsRead(f);
      case 'fs.write':
        _fsWrite(f);
      case 'git.status':
        _gitStatus(f);
      case 'git.diff':
        _gitDiff(f);
      case 'git.show':
        _gitShow(f);
      case 'git.stage':
      case 'git.unstage':
      case 'git.stageAll':
      case 'git.unstageAll':
      case 'git.discard':
      case 'git.discardAll':
      case 'git.commit':
      case 'git.push':
      case 'git.pull':
      case 'git.fetch':
      case 'git.checkout':
      case 'git.createBranch':
      case 'git.stash':
      case 'git.stashPop':
        _gitOp(f);
      case 'git.branches':
        _gitBranches(f);
      case 'wt.add':
      case 'wt.remove':
      case 'ws.new':
      case 'ws.remove':
      case 'proj.add':
      case 'proj.remove':
        _cfgOp(f);
      case 'wt.list':
        _wtList(f);
    }
  }

  List<Map<String, dynamic>> _sessionItems() => sessions()
      .map(
        (s) => {
          'sid': s.id,
          'title': s.label,
          'workdir': s.workdir,
          'agent': s.command.contains('codex') ? 'codex' : 'claude',
        },
      )
      .toList();

  List<Map<String, dynamic>> _rootItems() => roots()
      .map((r) => {'name': r.name, 'path': r.path, 'workspace': r.workspace})
      .toList();

  void _replyList(int to) {
    send({'t': 'sessions', 'to': to, 'items': _sessionItems()});
    send({'t': 'roots', 'to': to, 'items': _rootItems()});
  }

  // broadcastSessions/Roots push the current lists to ALL connected clients
  // (to:0) after a change, so phones stay in sync without re-requesting.
  void broadcastSessions() {
    if (connected) send({'t': 'sessions', 'to': 0, 'items': _sessionItems()});
  }

  void broadcastRoots() {
    if (connected) send({'t': 'roots', 'to': 0, 'items': _rootItems()});
  }

  TerminalSession? _sessionById(String? sid) {
    if (sid == null) return null;
    for (final s in sessions()) {
      if (s.id == sid) return s;
    }
    return null;
  }

  void _termOpen(Map<String, dynamic> f) {
    final sid = f['sid'] as String?;
    final from = (f['from'] as num?)?.toInt();
    final s = _sessionById(sid);
    if (s == null || from == null) return;
    // Replay recent output to just this client so it sees the current screen /
    // scrollback immediately instead of a blank terminal until the next redraw.
    // This method runs synchronously (no await) so no PTY chunk can interleave
    // between the replay and the remoteSink wiring below — no gap, no dup.
    final bl = s.backlog;
    if (bl.isNotEmpty) {
      send({'t': 'term.output', 'to': from, 'sid': s.id, 'd': bl});
    }
    (_watchers[s.id] ??= {}).add(from);
    // Setting remoteSink starts mirroring this session's output to the phone and
    // hands it authority over the PTY size (see TerminalSession.onResize).
    s.remoteSink = (chunk) {
      for (final c in _watchers[s.id] ?? const <int>{}) {
        send({'t': 'term.output', 'to': c, 'sid': s.id, 'd': chunk});
      }
    };
  }

  void _dropClient(int connId) {
    for (final entry in _watchers.entries.toList()) {
      entry.value.remove(connId);
      if (entry.value.isEmpty) {
        // Last watcher gone: stop mirroring and restore the desktop's full width.
        final s = _sessionById(entry.key);
        if (s != null) {
          s.remoteSink = null;
          s.restoreLocalSize();
        }
        _watchers.remove(entry.key);
      }
    }
  }

  void _detachAllSessions() {
    // Only the watched sessions hold a remoteSink — leave unwatched local
    // sessions untouched (no spurious resize).
    for (final sid in _watchers.keys) {
      final s = _sessionById(sid);
      if (s != null) {
        s.remoteSink = null;
        s.restoreLocalSize();
      }
    }
    _watchers.clear();
  }

  // _norm resolves '.'/'..' segments so a client can't traverse out of a root.
  String _norm(String p) {
    final parts = <String>[];
    for (final seg in p.split('/')) {
      if (seg.isEmpty || seg == '.') continue;
      if (seg == '..') {
        if (parts.isNotEmpty) parts.removeLast();
        continue;
      }
      parts.add(seg);
    }
    return '/${parts.join('/')}';
  }

  String? _safePath(String? path) {
    if (path == null || path.isEmpty) return null;
    final norm = _norm(path);
    for (final r in roots()) {
      final rn = _norm(r.path);
      if (norm == rn || norm.startsWith('$rn/')) return norm;
    }
    return null;
  }

  Future<void> _fsList(Map<String, dynamic> f) async {
    final to = (f['from'] as num?)?.toInt();
    final path = _safePath(f['path'] as String?);
    if (to == null) return;
    if (path == null) {
      send({'t': 'fs.err', 'to': to, 'path': f['path'], 'msg': 'forbidden'});
      return;
    }
    final entries = <Map<String, dynamic>>[];
    try {
      await for (final e in Directory(path).list(followLinks: false)) {
        final name = e.path.split('/').last;
        if (kIgnoredEntries.contains(name)) continue;
        final isDir = e is Directory;
        var size = 0;
        if (!isDir) {
          try {
            size = await (e as File).length();
          } catch (_) {}
        }
        entries.add({'name': name, 'dir': isDir, 'size': size});
      }
    } catch (e) {
      send({'t': 'fs.err', 'to': to, 'path': path, 'msg': '$e'});
      return;
    }
    entries.sort((a, b) {
      final ad = a['dir'] as bool, bd = b['dir'] as bool;
      if (ad != bd) return ad ? -1 : 1;
      return (a['name'] as String).toLowerCase().compareTo(
        (b['name'] as String).toLowerCase(),
      );
    });
    send({'t': 'fs.list.ok', 'to': to, 'path': path, 'entries': entries});
  }

  Future<void> _fsRead(Map<String, dynamic> f) async {
    final to = (f['from'] as num?)?.toInt();
    final path = _safePath(f['path'] as String?);
    if (to == null) return;
    if (path == null) {
      send({'t': 'fs.err', 'to': to, 'path': f['path'], 'msg': 'forbidden'});
      return;
    }
    try {
      final file = File(path);
      final len = await file.length();
      if (len > _maxRead) {
        send({'t': 'fs.err', 'to': to, 'path': path, 'msg': '文件过大'});
        return;
      }
      final bytes = await file.readAsBytes();
      final content = const Utf8Decoder(allowMalformed: true).convert(bytes);
      send({'t': 'fs.read.ok', 'to': to, 'path': path, 'content': content});
    } catch (e) {
      send({'t': 'fs.err', 'to': to, 'path': path, 'msg': '$e'});
    }
  }

  // fs.write: save edited content back to a file (scoped to a project root),
  // preserving the file's existing line ending like the desktop editor does.
  Future<void> _fsWrite(Map<String, dynamic> f) async {
    final to = (f['from'] as num?)?.toInt();
    final path = _safePath(f['path'] as String?);
    final content = f['content'] as String?;
    if (to == null) return;
    if (path == null || content == null) {
      send({
        't': 'fs.write.err',
        'to': to,
        'path': f['path'],
        'msg': 'forbidden',
      });
      return;
    }
    try {
      var out = content;
      try {
        final existing = await File(path).readAsString();
        if (existing.contains('\r\n')) out = content.replaceAll('\n', '\r\n');
      } catch (_) {}
      await File(path).writeAsString(out);
      send({'t': 'fs.write.ok', 'to': to, 'path': path});
    } catch (e) {
      send({'t': 'fs.write.err', 'to': to, 'path': path, 'msg': '$e'});
    }
  }

  // git.status: working-tree changes + recent commits for a (root) repo.
  Future<void> _gitStatus(Map<String, dynamic> f) async {
    final to = (f['from'] as num?)?.toInt();
    final path = _safePath(f['path'] as String?);
    if (to == null) return;
    if (path == null) {
      send({'t': 'git.err', 'to': to, 'msg': 'forbidden'});
      return;
    }
    try {
      final (changes, commits) = await (
        gitChanges(path),
        gitLog(path, max: 30),
      ).wait;
      send({
        't': 'git.status.ok',
        'to': to,
        'path': path,
        'changes': [
          for (final c in changes)
            {
              'path': c.path,
              'status': c.status,
              'staged': c.staged,
              'untracked': c.untracked,
              'conflicted': c.conflicted,
            },
        ],
        'commits': [
          for (final c in commits)
            {
              'hash': c.hash,
              'short': c.shortHash,
              'author': c.author,
              'date': c.date.toIso8601String(),
              'subject': c.subject,
            },
        ],
      });
    } catch (e) {
      send({'t': 'git.err', 'to': to, 'msg': '$e'});
    }
  }

  // git.diff: unified diff of a file's working-tree changes.
  Future<void> _gitDiff(Map<String, dynamic> f) async {
    final to = (f['from'] as num?)?.toInt();
    final path = _safePath(f['path'] as String?);
    final file = f['file'] as String?;
    if (to == null) return;
    if (path == null || file == null || file.contains('..')) {
      send({'t': 'git.err', 'to': to, 'msg': 'forbidden'});
      return;
    }
    try {
      final diff = await gitDiffFileWorking(path, file);
      send({'t': 'git.diff.ok', 'to': to, 'file': file, 'diff': diff});
    } catch (e) {
      send({'t': 'git.err', 'to': to, 'msg': '$e'});
    }
  }

  // git.show: full diff of a commit (hash validated to avoid arg injection).
  Future<void> _gitShow(Map<String, dynamic> f) async {
    final to = (f['from'] as num?)?.toInt();
    final path = _safePath(f['path'] as String?);
    final hash = f['hash'] as String?;
    if (to == null) return;
    if (path == null ||
        hash == null ||
        !RegExp(r'^[0-9a-fA-F]{4,40}$').hasMatch(hash)) {
      send({'t': 'git.err', 'to': to, 'msg': 'forbidden'});
      return;
    }
    try {
      final diff = await gitShowCommit(path, hash);
      send({'t': 'git.show.ok', 'to': to, 'hash': hash, 'diff': diff});
    } catch (e) {
      send({'t': 'git.err', 'to': to, 'msg': '$e'});
    }
  }

  // _gitOp runs a mutating git command (reusing lib/local/git.dart) and replies
  // git.op.ok / git.err. The client refreshes status on ok. All scoped to a root.
  Future<void> _gitOp(Map<String, dynamic> f) async {
    final to = (f['from'] as num?)?.toInt();
    final op = f['t'] as String?;
    final path = _safePath(f['path'] as String?);
    if (to == null) return;
    if (path == null) {
      send({'t': 'git.err', 'to': to, 'msg': 'forbidden'});
      return;
    }
    final file = f['file'] as String?;
    final branch = f['branch'] as String?;
    try {
      switch (op) {
        case 'git.stage':
          if (file != null) await gitStageFiles(path, [file]);
        case 'git.unstage':
          if (file != null) await gitUnstageFiles(path, [file]);
        case 'git.stageAll':
          await gitStageAll(path);
        case 'git.unstageAll':
          await gitUnstageAll(path);
        case 'git.discard':
          if (file != null) await gitRestore(path, file);
        case 'git.discardAll':
          await gitRestoreChanges(path, await gitChanges(path));
        case 'git.commit':
          final msg = (f['message'] as String?)?.trim() ?? '';
          if (msg.isEmpty) throw Exception('提交信息不能为空');
          await gitCommit(path, msg);
          if (f['push'] == true) {
            try {
              await gitPush(path);
            } catch (_) {
              await gitPush(path, setUpstream: true);
            }
          }
        case 'git.push':
          try {
            await gitPush(path);
          } catch (_) {
            await gitPush(path, setUpstream: true);
          }
        case 'git.pull':
          await gitPull(path);
        case 'git.fetch':
          await gitFetch(path);
        case 'git.checkout':
          if (branch != null) await gitCheckout(path, branch);
        case 'git.createBranch':
          if (branch != null) {
            await gitCreateBranch(path, branch, start: f['start'] as String?);
          }
        case 'git.stash':
          await gitStashPush(path, (f['message'] as String?) ?? '');
        case 'git.stashPop':
          final ref = f['ref'] as String?;
          if (ref != null) await gitStashPop(path, ref);
      }
      send({'t': 'git.op.ok', 'to': to, 'op': op});
    } catch (e) {
      send({'t': 'git.err', 'to': to, 'msg': '$e'});
    }
  }

  Future<void> _gitBranches(Map<String, dynamic> f) async {
    final to = (f['from'] as num?)?.toInt();
    final path = _safePath(f['path'] as String?);
    if (to == null) return;
    if (path == null) {
      send({'t': 'git.err', 'to': to, 'msg': 'forbidden'});
      return;
    }
    try {
      final branches = await gitBranches(path);
      send({
        't': 'git.branches.ok',
        'to': to,
        'branches': [
          for (final b in branches)
            {
              'name': b.name,
              'current': b.current,
              'remote': b.remote,
              'ahead': b.ahead,
              'behind': b.behind,
            },
        ],
      });
    } catch (e) {
      send({'t': 'git.err', 'to': to, 'msg': '$e'});
    }
  }

  // _cfgOp runs a config mutation (worktree/workspace/project) through the
  // WorkspacePage callback (which shells the Cli, reloads config, rebroadcasts).
  Future<void> _cfgOp(Map<String, dynamic> f) async {
    final to = (f['from'] as num?)?.toInt();
    final action = f['t'] as String?;
    if (to == null) return;
    if (action == null || onConfigAction == null) {
      send({'t': 'cfg.err', 'to': to, 'msg': '不支持'});
      return;
    }
    try {
      await onConfigAction!(action, f);
      send({'t': 'cfg.ok', 'to': to, 'op': action});
    } catch (e) {
      send({'t': 'cfg.err', 'to': to, 'msg': '$e'});
    }
  }

  // wt.list: enumerate a project's worktrees (read-only; reuses listWorktrees).
  Future<void> _wtList(Map<String, dynamic> f) async {
    final to = (f['from'] as num?)?.toInt();
    final path = _safePath(f['path'] as String?);
    if (to == null) return;
    if (path == null) {
      send({'t': 'cfg.err', 'to': to, 'msg': 'forbidden'});
      return;
    }
    try {
      final wts = await listWorktrees(path);
      send({
        't': 'wt.list.ok',
        'to': to,
        'path': path,
        'worktrees': [
          for (final w in wts) {'path': w.path, 'branch': w.branch},
        ],
      });
    } catch (e) {
      send({'t': 'cfg.err', 'to': to, 'msg': '$e'});
    }
  }
}
