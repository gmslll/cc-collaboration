import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show min;

import '../local/git.dart';
import '../local/hook_activity.dart';
import '../local/path_utils.dart';
import '../local/session_overview.dart';
import '../local/worktrees.dart';
import '../screen_share/webrtc.dart';
import '../screens/terminal_pane.dart';
import '../widgets.dart' show kIgnoredEntries;
import 'file_fs.dart';
import 'file_transfer.dart';
import 'remote_channel.dart';

// A project root the host exposes to remote clients (workspace = owning ws name).
class RemoteRoot {
  final String name;
  final String path;
  final String workspace;
  final String projectId;
  const RemoteRoot(this.name, this.path, this.workspace, [this.projectId = '']);
}

bool remoteGitFilePathAllowed(String? file) {
  final raw = (file ?? '').trim();
  if (raw.isEmpty) return false;
  final path = normalizePathSeparators(raw);
  if (path.startsWith('/') || path.startsWith('//')) return false;
  if (RegExp(r'^[A-Za-z]:/').hasMatch(path)) return false;
  if (path.startsWith(':(')) return false; // git pathspec magic
  for (final part in path.split('/')) {
    if (part.isEmpty || part == '.' || part == '..') return false;
  }
  return true;
}

bool remoteGitRefNameAllowed(String? value) {
  final ref = (value ?? '').trim();
  if (ref.isEmpty || ref.length > 200) return false;
  if (ref == '@' ||
      ref == 'HEAD' ||
      ref.startsWith('-') ||
      ref.startsWith('/') ||
      ref.endsWith('/') ||
      ref.startsWith('refs/')) {
    return false;
  }
  if (ref.contains(r'\') ||
      ref.contains('..') ||
      ref.contains('@{') ||
      ref.contains('//')) {
    return false;
  }
  if (ref.endsWith('.') || ref.endsWith('.lock')) return false;
  for (final part in ref.split('/')) {
    if (part.startsWith('.') || part.endsWith('.lock')) return false;
  }
  return !RegExp(r'[\x00-\x20\x7f~^:?*\[]').hasMatch(ref);
}

bool remoteGitStartRefAllowed(String? value) {
  final ref = (value ?? '').trim();
  if (ref.isEmpty) return true;
  return remoteGitRefNameAllowed(ref) ||
      RegExp(r'^[0-9a-fA-F]{4,40}$').hasMatch(ref);
}

bool remoteGitStashRefAllowed(String? value) =>
    RegExp(r'^stash@\{[0-9]+\}$').hasMatch((value ?? '').trim());

bool remoteConfigMutationAllowed(String? action, Map<String, dynamic> frame) {
  switch (action) {
    case 'wt.add':
      return _remoteConfigTextAllowed(frame['project'], maxLength: 256) &&
          _remoteConfigTextAllowed(
            frame['workspace'],
            optional: true,
            allowBlank: true,
          ) &&
          _remoteConfigGitRefAllowed(frame['branch']) &&
          _remoteConfigGitStartAllowed(frame['start']);
    case 'wt.remove':
      return _remoteConfigTextAllowed(frame['project'], maxLength: 256) &&
          _remoteConfigTextAllowed(
            frame['workspace'],
            optional: true,
            allowBlank: true,
          ) &&
          _remoteConfigGitRefAllowed(frame['branch']);
    case 'ws.new':
      return _remoteConfigTextAllowed(frame['name'], maxLength: 256) &&
          _remoteConfigTextAllowed(
            frame['path'],
            optional: true,
            maxLength: 4096,
          );
    case 'ws.remove':
      return _remoteConfigTextAllowed(frame['name'], maxLength: 256);
    case 'proj.add':
      return _remoteConfigTextAllowed(
            frame['workspace'],
            optional: true,
            allowBlank: true,
            maxLength: 256,
          ) &&
          _remoteConfigTextAllowed(frame['source'], maxLength: 4096);
    case 'proj.remove':
      return _remoteConfigTextAllowed(
            frame['workspace'],
            optional: true,
            allowBlank: true,
            maxLength: 256,
          ) &&
          _remoteConfigTextAllowed(frame['project'], maxLength: 256);
    default:
      return false;
  }
}

bool _remoteConfigTextAllowed(
  Object? value, {
  bool optional = false,
  bool allowBlank = false,
  int maxLength = 512,
}) {
  if (value == null) return optional;
  if (value is! String) return false;
  final text = value.trim();
  if (text.isEmpty) return optional && allowBlank && value.isEmpty;
  if (text.length > maxLength) return false;
  return !RegExp(r'[\x00-\x1f\x7f]').hasMatch(text);
}

bool _remoteConfigGitRefAllowed(Object? value) =>
    value is String && remoteGitRefNameAllowed(value);

bool _remoteConfigGitStartAllowed(Object? value) {
  if (value == null) return true;
  return value is String &&
      value.trim().isNotEmpty &&
      remoteGitStartRefAllowed(value);
}

// _isHighSurrogate reports whether [u] is the leading half of a UTF-16 surrogate
// pair, so backlog replay never splits an astral char (emoji) across two frames.
bool _isHighSurrogate(int u) => u >= 0xd800 && u <= 0xdbff;

// Max chars per term.output frame: the coalescer's flush threshold and the
// backlog-replay slice size. Bounds frame size (and worst-case latency).
const int _maxFrameChars = 64 * 1024;

// _OutputBatcher coalesces a session's PTY output before it goes on the wire.
// Without it every PTY chunk became one WS frame + one synchronous terminal.write
// on the phone — the main cause of mirror jank under streaming output. It uses
// leading-edge throttling: the first chunk after an idle gap flushes immediately
// (typing echo stays crisp), while a burst is collapsed to at most one frame per
// [window]; the buffer also flushes early once it reaches [_maxFrameChars].
class _OutputBatcher {
  _OutputBatcher(this._send);
  final void Function(String data) _send;
  final StringBuffer _buf = StringBuffer();
  Timer? _timer;
  final Stopwatch _since = Stopwatch()..start();

  static const Duration window = Duration(milliseconds: 8); // tunable knob

  void add(String chunk) {
    _buf.write(chunk);
    if (_buf.length >= _maxFrameChars) {
      _flush(); // bound frame size + worst-case latency
      return;
    }
    if (_timer != null) return; // a flush is already scheduled
    final waited = _since.elapsed;
    if (waited >= window) {
      _flush(); // leading edge: idle long enough, send now
    } else {
      _timer = Timer(window - waited, _flush); // trailing edge for the burst
    }
  }

  void _flush() {
    _timer?.cancel();
    _timer = null;
    if (_buf.isEmpty) return;
    final data = _buf.toString();
    _buf.clear();
    _since.reset();
    _send(data);
  }

  // dispose drops any buffered output without sending — used when the last
  // watcher leaves, so there is no one to receive it anyway.
  void dispose() {
    _timer?.cancel();
    _timer = null;
    _buf.clear();
  }
}

// RemoteHost shares this desktop's workspace (terminal sessions + project files)
// to the user's phone, brokered by the relay (see RemoteChannel for transport).
// Opt-in: nothing is exposed until [enable]. The relay only pipes between the
// SAME identity, so only the user's own devices can connect. File access is
// hard-scoped to the advertised project roots (traversal is normalized away).
class RemoteHost extends RemoteChannel {
  final List<TerminalSession> Function() sessions;
  final List<RemoteRoot> Function() roots;
  // workspaces lists ALL workspace names (incl. ones with no projects yet) so a
  // phone can show + add projects to an empty workspace — roots only carries
  // projects, so an empty workspace would otherwise be invisible. Null = none.
  final List<String> Function()? workspaces;
  // Write actions that must touch WorkspacePage state (launch/close/rename a
  // session). Null on hosts that only expose read access.
  // workdir is an optional worktree path under the project; the handler validates
  // it against the project root / its .worktrees/ before launching (the desktop
  // layer owns the real project list, so the check lives there, not here).
  final void Function(String projectPath, String agent, String? workdir)?
  onNewSession;
  final void Function(String sid)? onCloseSession;
  final void Function(String sid, String name)? onRenameSession;
  // Config mutations (worktree/workspace/project add/remove) — run the matching
  // Cli command, reload config, then call broadcastRoots. Null = read-only host.
  final Future<void> Function(String action, Map<String, dynamic> args)?
  onConfigAction;
  // onAssignTodo runs a phone's remote todo-assign request on this desktop:
  // dispatch the todo to an existing local session, or spawn a new one and
  // dispatch — then bind the todo (assignee + session resume trio). The phone
  // has no local session/filesystem to do this itself, so it delegates here.
  // Returns null on success or a human-readable error. Null on read-only hosts.
  final Future<String?> Function(Map<String, dynamic> req)? onAssignTodo;

  RemoteHost({
    required super.relayUrl,
    required super.token,
    required this.sessions,
    required this.roots,
    this.workspaces,
    this.onNewSession,
    this.onCloseSession,
    this.onRenameSession,
    this.onConfigAction,
    this.onAssignTodo,
  }) : super(role: 'host');

  int _clients = 0;
  final Map<String, Set<int>> _watchers = {}; // session id -> watching clients
  final Map<String, _OutputBatcher> _batchers =
      {}; // session id -> output coalescer
  static const int _maxRead = 2 * 1024 * 1024; // 2MB file-read cap

  bool get sharing => active;
  int get clientCount => _clients;

  // watching reports whether any phone is currently viewing [sid] (so the
  // workspace only does reply-text work when someone's listening).
  bool watching(String sid) => _watchers[sid]?.isNotEmpty ?? false;

  // onSessionWatched fires when a phone opens (subscribes to) a session — the
  // workspace baselines that session's voice reading cursor.
  void Function(String sid)? onSessionWatched;

  // onFileReceived fires when a phone-sent file finishes landing in
  // ~/Downloads/cc-recv (the workspace pops a desktop notification).
  void Function(String name, String path)? onFileReceived;

  // onSessionFile fires when a phone sends a file from inside a session (the
  // offer carried a sid — e.g. an image picked in the terminal screen) and it
  // finished landing. The host has already pasted the saved path into that
  // session's terminal (mirroring the desktop paste-image flow) so the agent can
  // read it from disk; this callback just lets the workspace surface a toast.
  void Function(String sid, String name, String path)? onSessionFile;

  // _fileRx assembles inbound file.* frames from clients into ~/Downloads/cc-recv.
  // No onOffer handler → the host auto-accepts (it trusts its own user's phone
  // pushes), immediately acking so the phone's sender starts streaming.
  FileReceiver? _fileRxInst;
  FileReceiver get _fileRx => _fileRxInst ??= FileReceiver(
    openSink: (info) => openReceiveSink(info, host: true),
    sendFrame: send,
    onComplete: _onFileComplete,
  );

  NativeShareHost? _shareHostInst;
  NativeShareHost get _shareHost =>
      _shareHostInst ??= NativeShareHost(sendFrame: send);

  // _onFileComplete routes a finished inbound file: a session-tagged file (sid)
  // is pasted into that session's terminal as a path the agent can read; an
  // untagged push just notifies via onFileReceived.
  void _onFileComplete(IncomingFile info, String path) {
    final sid = info.sid;
    if (sid != null) {
      _sessionById(sid)?.pasteText(path);
      onSessionFile?.call(sid, info.name, path);
    } else {
      onFileReceived?.call(info.name, path);
    }
  }

  // Connected phones by connId → display name (from their hello frame), so a
  // desktop→phone send can fan out to each and label its progress row.
  final Map<int, String> _clientNames = {};

  // Outgoing transfers to phones (active + recent, newest first) — drives the
  // desktop send dialog's per-device progress rows. _outById routes a phone's
  // file.accept / file.reject back to the matching send handle's consent gate.
  final List<FileXfer> outgoing = [];
  final Map<String, FileSendHandle> _outById = {};

  FileXfer? _xfer(String xid) {
    for (final x in outgoing) {
      if (x.xid == xid) return x;
    }
    return null;
  }

  // sendFileToClients announces [path] to every connected phone (broadcast):
  // each phone gets its own offer and decides 接受/拒绝 independently, and an
  // accepted one streams with its own progress row. Returns the batch of FileXfer
  // rows created (empty when no phone is connected); the desktop UI watches
  // `outgoing` for live progress.
  List<FileXfer> sendFileToClients(String path) {
    final name = sanitizeFileName(pathBaseName(path));
    final batch = <FileXfer>[];
    for (final connId in _clientNames.keys.toList()) {
      final peerName = _clientNames[connId] ?? '手机';
      late final FileSendHandle h;
      h = sendFileOverChannel(
        path: path,
        send: send,
        to: connId,
        requireAccept: true,
        onProgress: (sent, total) {
          final x = _xfer(h.xid);
          if (x != null) {
            x.sent = sent;
            x.size = total;
            x.status = XferStatus.active;
            notifyListeners();
          }
        },
        onDone: (ok, msg) {
          final x = _xfer(h.xid);
          if (x != null) {
            x.status = ok
                ? XferStatus.done
                : msg.contains('拒绝')
                ? XferStatus.rejected
                : msg.contains('取消')
                ? XferStatus.cancelled
                : XferStatus.failed;
            notifyListeners();
          }
          _outById.remove(h.xid);
        },
      );
      _outById[h.xid] = h;
      final x = FileXfer(
        xid: h.xid,
        name: name,
        size: 0,
        dir: XferDir.send,
        peer: connId,
        peerName: peerName,
        status: XferStatus.waiting,
        path: path,
      );
      outgoing.insert(0, x);
      batch.add(x);
    }
    while (outgoing.length > 100) {
      outgoing.removeLast();
    }
    notifyListeners();
    return batch;
  }

  // _cancelClientXfers aborts any in-flight send to a phone that just dropped, so
  // its progress row doesn't hang at "传输中".
  void _cancelClientXfers(int connId) {
    for (final x in outgoing) {
      if (x.peer == connId && x.inFlight) {
        x.status = XferStatus.cancelled;
        _outById.remove(x.xid)
          ?..reject()
          ..cancel();
      }
    }
  }

  // _dispatchFile routes a file.* frame: accept/reject/ack and a cancel of one of
  // OUR outgoing xids resolve the matching send handle's gate; everything else
  // (offer/chunk/end from a phone push, or a cancel of an inbound transfer) goes
  // to the receiver.
  void _dispatchFile(String t, Map<String, dynamic> f) {
    final xid = f['xid'] as String?;
    switch (t) {
      case 'file.accept':
        if (xid != null) _outById[xid]?.accept();
        return;
      case 'file.reject':
        if (xid != null) {
          _outById[xid]?.reject();
          final x = _xfer(xid);
          if (x != null) {
            x.status = XferStatus.rejected;
            notifyListeners();
          }
        }
        return;
      case 'file.ack':
        if (xid != null && f['ok'] == false) {
          final x = _xfer(xid);
          if (x != null && x.inFlight) {
            x.status = XferStatus.failed;
            notifyListeners();
          }
        }
        return;
      case 'file.cancel':
        if (xid != null && _outById.containsKey(xid)) {
          _outById[xid]
            ?..reject()
            ..cancel();
          return;
        }
    }
    _fileRx.dispatch(f);
  }

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
      _cancelClientXfers(connId); // abort any in-flight send to this phone
      if (_shareHostInst?.viewer == connId) unawaited(_shareHost.stop());
      _clientNames.remove(connId);
    }
    notifyListeners();
  }

  @override
  void onFrame(Map<String, dynamic> f) {
    final t = f['t'];
    // File transfer frames split by role: a phone's accept/reject/ack for a file
    // WE are sending routes to its handle; its offer/chunk/end (a phone push) go
    // to the receiver. See _dispatchFile.
    if (t is String && t.startsWith('file.')) {
      _dispatchFile(t, f);
      return;
    }
    if (t is String && t.startsWith('share.')) {
      unawaited(_dispatchShare(t, f));
      return;
    }
    switch (t) {
      case 'hello':
        // A phone announcing its display name (for the send list / progress).
        final from = (f['from'] as num?)?.toInt();
        final name = (f['name'] as String?)?.trim();
        if (from != null) {
          _clientNames[from] = (name == null || name.isEmpty) ? '手机' : name;
          notifyListeners();
        }
      case 'list':
        final from = (f['from'] as num?)?.toInt();
        if (from != null) _replyList(from);
      case 'term.open':
        _termOpen(f);
      case 'term.input':
        final s = _sessionById(f['sid'] as String?);
        final d = (f['d'] as String?) ?? '';
        // Remote/phone keystrokes are real user input, the third input funnel
        // (besides the desktop hardware-key and IME paths): mark the row dirty so
        // a delivered peer message parks in the inbox instead of pasting over what
        // the phone user is typing. markUserInput clears on a submit (CR).
        s?.markUserInput(d);
        s?.sendText(d);
        // A submit (Enter) sent to an agent session means it's now working —
        // flip the phone's Live Activity to "thinking" until onAgentDone.
        if (s != null && s.isAgent && (d.contains('\r') || d.contains('\n'))) {
          broadcastStatus(
            s.id,
            true,
            '思考中…',
            usage: s.usage.value?.shortLabel(),
          );
        }
      case 'screen':
        // One-shot current-screen snapshot for the phone's quick-reply popup —
        // the live terminal (incl. any permission prompt), without opening the
        // full mirror. Re-requested on a timer while the popup is open.
        final from = (f['from'] as num?)?.toInt();
        final s = _sessionById(f['sid'] as String?);
        if (from != null) {
          final snap = s?.snapshotSized();
          send({
            't': 'screen',
            'to': from,
            'sid': f['sid'],
            'text': snap?.ansi ?? '', // coloured tail (ANSI)
            // source geometry so the phone renders at the computer's width
            // (full-screen TUIs format to width) instead of reflowing.
            'cols': snap?.cols ?? 0,
            'rows': snap?.rows ?? 0,
          });
        }
      case 'term.resize':
        final sid = f['sid'] as String?;
        final from = (f['from'] as num?)?.toInt();
        if (sid != null &&
            from != null &&
            (_watchers[sid]?.contains(from) ?? false)) {
          _sessionById(sid)?.resizeFromRemote(
            (f['rows'] as num?)?.toInt() ?? 0,
            (f['cols'] as num?)?.toInt() ?? 0,
          );
        }
      case 'session.new':
        onNewSession?.call(
          (f['project'] as String?) ?? '',
          (f['agent'] as String?) ?? 'claude',
          f['workdir'] as String?,
        );
      case 'todo.assign':
        // The phone asks this desktop to assign a todo to an existing/new local
        // session (it can't dispatch/spawn/materialize itself). Run it via
        // onAssignTodo and reply ok/err directed back to the requesting client.
        final from = (f['from'] as num?)?.toInt();
        if (from != null) {
          final todoId = ((f['todoId'] as String?) ?? '').trim();
          unawaited(
            _replyTodoAssign(
              {...f, 'todoId': todoId},
              from: from,
              todoId: todoId,
            ),
          );
        }
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

  Future<void> _replyTodoAssign(
    Map<String, dynamic> frame, {
    required int from,
    required String todoId,
  }) async {
    String? err;
    try {
      final handler = onAssignTodo;
      err = handler == null ? '桌面版不支持远程指派,请升级桌面 App' : await handler(frame);
    } catch (e) {
      err = '远程指派失败: $e';
    }
    send({
      't': err == null ? 'todo.assign.ok' : 'todo.assign.err',
      'to': from,
      'todoId': todoId,
      'msg': ?err,
    });
  }

  Future<void> _dispatchShare(String t, Map<String, dynamic> f) async {
    final from = (f['from'] as num?)?.toInt();
    if (from == null) return;
    try {
      switch (t) {
        case 'share.sources':
          final sources = await _shareHost.listSources();
          send({
            't': 'share.sources.ok',
            'to': from,
            'items': [for (final s in sources) s.toJson()],
          });
        case 'share.start':
          final sourceId = (f['sourceId'] as String?) ?? '';
          if (sourceId.isEmpty) {
            send({'t': 'share.err', 'to': from, 'msg': 'source required'});
            return;
          }
          final currentViewer = _shareHostInst?.viewer;
          if (currentViewer != null && currentViewer != from) {
            send({'t': 'share.err', 'to': from, 'msg': '屏幕共享正在被另一台设备观看'});
            return;
          }
          await _shareHost.start(from, sourceId);
        case 'share.answer':
          if (_shareHostInst?.viewer != from) return;
          await _shareHost.applyAnswer(f['sdp']);
        case 'share.ice':
          if (_shareHostInst?.viewer != from) return;
          await _shareHost.addIce(f['candidate']);
        case 'share.stop':
          if (_shareHostInst?.viewer != from) return;
          await _shareHost.stop();
          send({'t': 'share.stopped', 'to': from});
      }
    } catch (e) {
      send({'t': 'share.err', 'to': from, 'msg': _shareErrorText(e)});
    }
  }

  String _shareErrorText(Object error) {
    final msg = '$error';
    if (msg.contains('NotAllowedError') || msg.contains('Permission')) {
      return '电脑端没有屏幕录制权限，请在系统设置里允许 cc-handoff 录制屏幕';
    }
    if (msg.contains('NotFoundError')) {
      return '电脑端找不到这个屏幕或窗口，请刷新共享源后重试';
    }
    return msg;
  }

  RemoteRoot? _rootForWorkdir(String workdir) {
    RemoteRoot? best;
    for (final root in roots()) {
      if (!pathWithin(workdir, root.path)) continue;
      if (best == null || root.path.length > best.path.length) best = root;
    }
    return best;
  }

  List<Map<String, dynamic>> _sessionItems() => sessions().map((s) {
    final root = _rootForWorkdir(s.workdir);
    return {
      'sid': s.id,
      'title': s.label,
      'workdir': s.workdir,
      'agent': s.agentKind,
      if (root != null) ...{
        'project': root.name,
        'workspace': root.workspace,
        'project_id': root.projectId,
      },
    };
  }).toList();

  List<Map<String, dynamic>> _rootItems() => roots()
      .map(
        (r) => {
          'name': r.name,
          'path': r.path,
          'workspace': r.workspace,
          'project_id': r.projectId,
        },
      )
      .toList();

  // _rootsPayload is the `roots` frame body: the project list plus ALL workspace
  // names (so empty workspaces show on the phone). Shared by reply + broadcast.
  Map<String, dynamic> _rootsPayload() => {
    'items': _rootItems(),
    'workspaces': workspaces?.call() ?? const <String>[],
  };

  void _replyList(int to) {
    send({'t': 'sessions', 'to': to, 'items': _sessionItems()});
    send({'t': 'roots', 'to': to, ..._rootsPayload()});
    // A newly-connected phone gets the latest rich overview snapshot (status +
    // usage + reply preview per session) so its 总览 grid is populated at once,
    // without waiting for the next turn-boundary broadcast.
    send({'t': 'overview', 'to': to, 'items': _overview});
  }

  // _overview caches the latest session-overview snapshot (built by the
  // workspace, which owns the live sessions + can read transcripts). The host
  // just relays it: setOverview swaps the cache, broadcastOverview pushes it to
  // all phones, and _replyList replays it on connect.
  List<Map<String, dynamic>> _overview = const [];
  void setOverview(List<SessionCard> cards) =>
      _overview = [for (final c in cards) c.toJson()];
  void broadcastOverview() {
    if (connected) send({'t': 'overview', 'to': 0, 'items': _overview});
  }

  // broadcastSessions/Roots push the current lists to ALL connected clients
  // (to:0) after a change, so phones stay in sync without re-requesting.
  void broadcastSessions() {
    if (connected) send({'t': 'sessions', 'to': 0, 'items': _sessionItems()});
  }

  void broadcastRoots() {
    if (connected) send({'t': 'roots', 'to': 0, ..._rootsPayload()});
  }

  // broadcastNotify pushes a one-shot notification (e.g. an agent finished a
  // turn) to every connected phone. Host→client only — no onFrame case needed.
  // Transient/fire-and-forget: a phone connecting later won't see it (unlike the
  // sessions/roots snapshots, which replay on connect).
  void broadcastNotify(String title, String body, {String? sid}) {
    if (!connected) return;
    send({'t': 'notify', 'to': 0, 'title': title, 'body': body, 'sid': ?sid});
  }

  // broadcastReply pushes an agent's clean reply text to the phones watching
  // [sid] so they can read it aloud (phone-side TTS). Only watchers receive it.
  void broadcastReply(String sid, String text) {
    if (!connected) return;
    for (final c in _watchers[sid] ?? const <int>{}) {
      send({'t': 'reply', 'to': c, 'sid': sid, 'text': text});
    }
  }

  // broadcastStatus pushes an agent's working/idle state (+ a short text) to the
  // phones watching [sid] so they can drive a Live Activity / Dynamic Island
  // while the user is in another app. Only watchers receive it.
  void broadcastStatus(String sid, bool working, String text, {String? usage}) {
    if (!connected) return;
    for (final c in _watchers[sid] ?? const <int>{}) {
      final m = {
        't': 'status',
        'to': c,
        'sid': sid,
        'working': working,
        'text': text,
      };
      if (usage != null && usage.isNotEmpty) m['usage'] = usage;
      send(m);
    }
  }

  void broadcastActivity(String sid, List<HookActivity> items) {
    if (!connected) return;
    final payload = [for (final a in items) a.toJson()];
    for (final c in _watchers[sid] ?? const <int>{}) {
      send({'t': 'activity', 'to': c, 'sid': sid, 'items': payload});
    }
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
    // Replay history as PLAIN TEXT (not the raw byte backlog) so it stays
    // readable on a phone narrower than this computer: the raw stream bakes in
    // the computer's width (full-screen TUIs format to width) and renders
    // mis-wrapped ("乱码") at the phone's width. historyText() strips ANSI/colour
    // so the phone re-wraps each line at its own width; the live stream below is
    // still raw (colour intact) and, after the phone's resize, the agent redraws
    // the current screen at the phone's width. Trade-off: replayed history loses
    // colour. Runs synchronously (no await) so no PTY chunk interleaves before
    // the remoteSink wiring below — no gap, no dup. <=64KB frames so the phone
    // yields between writes; never split a surrogate pair across frames.
    // historyMode picks how the phone wants pre-connect history rendered:
    // 'ansi' = coloured re-wrap (historyAnsi), anything else = plain text
    // (default). Both re-wrap at the phone's width; 'text' drops colour.
    // If the client told us its viewport, size the PTY to the phone BEFORE
    // replaying — so a full-screen agent redraws its current screen at the
    // phone's width (not the desktop's), and the history below is extracted from
    // a buffer already at the phone's width. Without this, a non-active session
    // replays at the desktop width and overflows the phone, and the idle agent
    // never redraws to correct it.
    final cols = (f['cols'] as num?)?.toInt() ?? 0;
    final rows = (f['rows'] as num?)?.toInt() ?? 0;
    (_watchers[s.id] ??= {}).add(from);
    onSessionWatched?.call(s.id); // baseline voice reading for this session
    // Setting remoteSink starts mirroring this session's output to the phone and
    // hands it authority over the PTY size (see TerminalSession.onResize). Output
    // is coalesced per session (see _OutputBatcher) then fanned out to watchers.
    final batcher = _batchers[s.id] ??= _OutputBatcher((data) {
      for (final c in _watchers[s.id] ?? const <int>{}) {
        send({'t': 'term.output', 'to': c, 'sid': s.id, 'd': data});
      }
    });
    s.remoteSink = batcher.add;
    if (cols >= 2 && rows >= 2) s.resizeFromRemote(rows, cols);
    final wasDormant = s.deferred && !s.started;
    if (wasDormant) {
      s.deferred = false;
      s.start();
      notifyListeners(); // repaint the desktop tree: clear the 休眠 glyph.
    }
    final mode = (f['historyMode'] ?? 'text').toString();
    // Replay the FULL backlog so the phone can scroll back through history; the
    // phone re-wraps the plain text at its own width, so this stays readable.
    final bl = mode == 'ansi' ? s.historyAnsi() : s.historyText();
    for (var i = 0; i < bl.length;) {
      var end = min(i + _maxFrameChars, bl.length);
      if (end < bl.length && _isHighSurrogate(bl.codeUnitAt(end - 1))) end++;
      send({
        't': 'term.output',
        'to': from,
        'sid': s.id,
        'd': bl.substring(i, end),
      });
      i = end;
    }
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
        _batchers.remove(entry.key)?.dispose();
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
    for (final b in _batchers.values) {
      b.dispose();
    }
    _batchers.clear();
    _watchers.clear();
  }

  RemoteRoot? _rootForPath(String path) {
    RemoteRoot? best;
    var bestLen = -1;
    for (final r in roots()) {
      if (pathWithin(path, r.path) && r.path.length > bestLen) {
        best = r;
        bestLen = r.path.length;
      }
    }
    return best;
  }

  Future<String?> _safePath(String? path) async {
    if (path == null || path.isEmpty) return null;
    final root = _rootForPath(path);
    if (root == null) return null;
    if (!await _resolvedPathStaysInRoot(path, root.path)) return null;
    return path;
  }

  Future<bool> _resolvedPathStaysInRoot(String path, String rootPath) async {
    try {
      final rootReal = Directory(rootPath).resolveSymbolicLinksSync();
      final rel = pathRelativeTo(rootPath, path);
      if (rel.isEmpty) return true;
      var current = rootPath;
      for (final part in rel.split('/')) {
        if (part.isEmpty) continue;
        current = pathJoin(current, part);
        final type = FileSystemEntity.typeSync(current, followLinks: false);
        if (type == FileSystemEntityType.notFound) return true;
        final real = switch (type) {
          FileSystemEntityType.directory => Directory(
            current,
          ).resolveSymbolicLinksSync(),
          FileSystemEntityType.file => File(current).resolveSymbolicLinksSync(),
          FileSystemEntityType.link => Link(current).resolveSymbolicLinksSync(),
          _ => current,
        };
        if (!pathWithin(real, rootReal)) return false;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _fsList(Map<String, dynamic> f) async {
    final to = (f['from'] as num?)?.toInt();
    final path = await _safePath(f['path'] as String?);
    if (to == null) return;
    if (path == null) {
      send({'t': 'fs.err', 'to': to, 'path': f['path'], 'msg': 'forbidden'});
      return;
    }
    final entries = <Map<String, dynamic>>[];
    try {
      await for (final e in Directory(path).list(followLinks: false)) {
        final name = pathBaseName(e.path);
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
    final path = await _safePath(f['path'] as String?);
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
    } on PathNotFoundException {
      // "Does not exist" — callers match this stable message to seed a
      // brand-new file. Other errors (permission, etc.) are surfaced as-is.
      send({'t': 'fs.err', 'to': to, 'path': path, 'msg': '文件不存在'});
    } catch (e) {
      send({'t': 'fs.err', 'to': to, 'path': path, 'msg': '$e'});
    }
  }

  // fs.write: save edited content back to a file (scoped to a project root),
  // preserving the file's existing line ending like the desktop editor does.
  Future<void> _fsWrite(Map<String, dynamic> f) async {
    final to = (f['from'] as num?)?.toInt();
    final path = await _safePath(f['path'] as String?);
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
      // Create missing parent dirs (e.g. .cc-handoff/supervisor/) so saving a
      // brand-new file in a not-yet-existing subdir succeeds.
      await Directory(path).parent.create(recursive: true);
      await File(path).writeAsString(out);
      send({'t': 'fs.write.ok', 'to': to, 'path': path});
    } catch (e) {
      send({'t': 'fs.write.err', 'to': to, 'path': path, 'msg': '$e'});
    }
  }

  // git.status: working-tree changes + recent commits for a (root) repo.
  Future<void> _gitStatus(Map<String, dynamic> f) async {
    final to = (f['from'] as num?)?.toInt();
    final path = await _safePath(f['path'] as String?);
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
    final path = await _safePath(f['path'] as String?);
    final file = f['file'] as String?;
    if (to == null) return;
    if (path == null || !remoteGitFilePathAllowed(file)) {
      send({'t': 'git.err', 'to': to, 'msg': 'forbidden'});
      return;
    }
    try {
      // full=true → whole-file context (the diff viewer's 「全部」 toggle).
      final full = f['full'] == true;
      final diff = await gitDiffFileWorking(
        path,
        file!,
        context: full ? 999999 : 3,
      );
      send({'t': 'git.diff.ok', 'to': to, 'file': file, 'diff': diff});
    } catch (e) {
      send({'t': 'git.err', 'to': to, 'msg': '$e'});
    }
  }

  // git.show: full diff of a commit (hash validated to avoid arg injection).
  Future<void> _gitShow(Map<String, dynamic> f) async {
    final to = (f['from'] as num?)?.toInt();
    final path = await _safePath(f['path'] as String?);
    final hash = f['hash'] as String?;
    if (to == null) return;
    if (path == null ||
        hash == null ||
        !RegExp(r'^[0-9a-fA-F]{4,40}$').hasMatch(hash)) {
      send({'t': 'git.err', 'to': to, 'msg': 'forbidden'});
      return;
    }
    try {
      final full = f['full'] == true;
      final diff = await gitShowCommit(path, hash, context: full ? 999999 : 3);
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
    final path = await _safePath(f['path'] as String?);
    if (to == null) return;
    if (path == null) {
      send({'t': 'git.err', 'to': to, 'msg': 'forbidden'});
      return;
    }
    final file = f['file'] as String?;
    final branch = f['branch'] as String?;
    final start = f['start'] as String?;
    final stashRef = f['ref'] as String?;
    final isFileOp =
        op == 'git.stage' || op == 'git.unstage' || op == 'git.discard';
    if (isFileOp && !remoteGitFilePathAllowed(file)) {
      send({'t': 'git.err', 'to': to, 'msg': 'forbidden'});
      return;
    }
    if (op == 'git.checkout' && !remoteGitRefNameAllowed(branch)) {
      send({'t': 'git.err', 'to': to, 'msg': 'forbidden'});
      return;
    }
    if (op == 'git.createBranch' &&
        (!remoteGitRefNameAllowed(branch) ||
            !remoteGitStartRefAllowed(start))) {
      send({'t': 'git.err', 'to': to, 'msg': 'forbidden'});
      return;
    }
    if (op == 'git.stashPop' && !remoteGitStashRefAllowed(stashRef)) {
      send({'t': 'git.err', 'to': to, 'msg': 'forbidden'});
      return;
    }
    try {
      switch (op) {
        case 'git.stage':
          await gitStageFiles(path, [file!]);
        case 'git.unstage':
          await gitUnstageFiles(path, [file!]);
        case 'git.stageAll':
          await gitStageAll(path);
        case 'git.unstageAll':
          await gitUnstageAll(path);
        case 'git.discard':
          await gitRestore(path, file!);
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
            await gitCreateBranch(path, branch, start: start);
          }
        case 'git.stash':
          await gitStashPush(path, (f['message'] as String?) ?? '');
        case 'git.stashPop':
          if (stashRef != null) await gitStashPop(path, stashRef);
      }
      send({'t': 'git.op.ok', 'to': to, 'op': op});
    } catch (e) {
      send({'t': 'git.err', 'to': to, 'msg': '$e'});
    }
  }

  Future<void> _gitBranches(Map<String, dynamic> f) async {
    final to = (f['from'] as num?)?.toInt();
    final path = await _safePath(f['path'] as String?);
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
    if (!remoteConfigMutationAllowed(action, f)) {
      send({'t': 'cfg.err', 'to': to, 'msg': 'forbidden'});
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
    final path = await _safePath(f['path'] as String?);
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

  @override
  void dispose() {
    unawaited(_shareHostInst?.stop());
    super.dispose();
  }
}
