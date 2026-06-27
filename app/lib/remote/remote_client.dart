import 'dart:async';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:xterm/xterm.dart';

import '../notifications.dart';
import '../terminal_mouse.dart';
import 'file_fs.dart';
import 'file_transfer.dart';
import 'remote_channel.dart';

// deviceDisplayName resolves a human-friendly name for this phone (shown in the
// desktop's send list and progress rows) — the iOS device name or the Android
// brand+model. Web-safe (uses defaultTargetPlatform, not dart:io Platform); any
// failure falls back to a generic label.
Future<String> deviceDisplayName() async {
  try {
    final info = DeviceInfoPlugin();
    switch (defaultTargetPlatform) {
      case TargetPlatform.iOS:
        return (await info.iosInfo).name;
      case TargetPlatform.android:
        final a = await info.androidInfo;
        return '${a.brand} ${a.model}'.trim();
      default:
        break;
    }
  } catch (_) {}
  return '手机';
}

// Client-side models of what the desktop host advertises.
class RemoteSession {
  final String sid;
  final String title;
  final String workdir;
  final String agent;
  RemoteSession(this.sid, this.title, this.workdir, this.agent);
}

class RemoteRootInfo {
  final String name;
  final String path;
  final String workspace;
  RemoteRootInfo(this.name, this.path, this.workspace);
}

class RemoteWorktree {
  final String path;
  final String branch;
  RemoteWorktree(this.path, this.branch);
  String get name =>
      path.split('/').lastWhere((s) => s.isNotEmpty, orElse: () => path);
}

class RemoteEntry {
  final String name;
  final bool dir;
  final int size;
  RemoteEntry(this.name, this.dir, this.size);
}

class RemoteGitChange {
  final String path;
  final String status;
  final bool staged;
  final bool untracked;
  final bool conflicted;
  RemoteGitChange(
    this.path,
    this.status,
    this.staged,
    this.untracked,
    this.conflicted,
  );
}

class RemoteGitCommit {
  final String hash;
  final String short;
  final String author;
  final String date;
  final String subject;
  RemoteGitCommit(this.hash, this.short, this.author, this.date, this.subject);
}

class RemoteBranch {
  final String name;
  final bool current;
  final bool remote;
  final int ahead;
  final int behind;
  RemoteBranch(this.name, this.current, this.remote, this.ahead, this.behind);
}

// A notification pushed from the desktop host (e.g. an agent finished a turn),
// kept in a small in-app history so the phone can show it beyond the transient
// OS banner.
class RemoteNotice {
  final String title;
  final String body;
  final DateTime at;
  RemoteNotice(this.title, this.body) : at = DateTime.now();
}

// A file received from the desktop, landed in the app's Documents/cc-recv. Kept
// so the phone can list and re-open / share files beyond the arrival toast.
class ReceivedFile {
  final String name;
  final String path;
  final DateTime at;
  ReceivedFile(this.name, this.path) : at = DateTime.now();
}

// A file sent up to the desktop (path is the original local file the user
// picked). Recorded on a successful send so the phone can list / re-open /
// share it beyond the send toast — symmetric with ReceivedFile.
class SentFile {
  final String name;
  final String path;
  final DateTime at;
  SentFile(this.name, this.path) : at = DateTime.now();
}

// RemoteClient is the phone side of the remote workspace: over the relay (see
// RemoteChannel for transport) it discovers the desktop host's terminal sessions
// and project roots, drives terminals (xterm fed by network bytes, keystrokes
// sent back), and browses/reads files. Read-only files for now (editing later).
class RemoteClient extends RemoteChannel {
  RemoteClient({required super.relayUrl, required super.token})
    : super(role: 'client') {
    _loadDeviceName();
  }

  bool _hostOnline = false;

  // This phone's display name, sent to the host on connect (hello) so the
  // desktop's send list / progress rows can show "Gabriel 的 iPhone" instead of
  // an anonymous connection. Resolved async; '手机' until then.
  String deviceName = '手机';
  Future<void> _loadDeviceName() async {
    deviceName = await deviceDisplayName();
    if (connected) _sendHello();
  }

  void _sendHello() =>
      send({'t': 'hello', 'role': 'client', 'name': deviceName});

  // historyMode tells the host how to replay a session's pre-connect history on
  // term.open: 'text' (default) = plain re-wrappable text; 'ansi' = coloured
  // re-wrap. Set by the UI from a saved pref; switching + reloadTerminal re-pulls
  // history in the new mode. The live stream is always raw (coloured).
  String historyMode = 'text';

  List<RemoteSession> sessions = [];
  List<RemoteRootInfo> roots = [];

  // onReplyText fires when the desktop pushes an agent's clean reply text for a
  // watched session (the terminal screen reads it aloud). Not a ChangeNotifier
  // field — it's a transient one-shot, not rebuildable state.
  void Function(String sid, String text)? onReplyText;

  // onAgentStatus fires when the desktop pushes a watched session's working/idle
  // state (+ a short text). The terminal screen drives an iOS Live Activity /
  // Dynamic Island from it so the user can leave the app and still see progress.
  void Function(String sid, bool working, String text)? onAgentStatus;

  // Files received from the desktop (newest first) + a one-shot arrival callback
  // for a toast. _fileRx assembles inbound file.* frames into Documents/cc-recv.
  final List<ReceivedFile> receivedFiles = [];
  void Function(String name, String path)? onFileReceived;

  // Live transfers (send & receive, newest first) driving the in-app progress
  // rows. onIncomingOffer fires when the desktop offers a file so the UI can
  // prompt 接受/拒绝; acceptOffer/rejectOffer answer it.
  final List<FileXfer> transfers = [];
  void Function(FileXfer offer)? onIncomingOffer;
  // Outgoing send handles by xid, so the host's file.accept / file.reject can be
  // routed to the matching transfer's consent gate.
  final Map<String, FileSendHandle> _outById = {};

  FileXfer? _xfer(String xid) {
    for (final x in transfers) {
      if (x.xid == xid) return x;
    }
    return null;
  }

  void _addXfer(FileXfer x) {
    transfers.insert(0, x);
    while (transfers.length > 100) {
      transfers.removeLast();
    }
  }

  FileReceiver? _fileRxInst;
  FileReceiver get _fileRx => _fileRxInst ??= FileReceiver(
    openSink: (info) => openReceiveSink(info, host: false),
    sendFrame: send,
    // Defer consent to the UI: park the offer, surface it, decide later.
    onOffer: (info) {
      final x = FileXfer(
        xid: info.xid,
        name: info.name,
        size: info.size,
        dir: XferDir.recv,
        peer: info.from,
        peerName: '电脑',
      );
      _addXfer(x);
      notifyListeners();
      onIncomingOffer?.call(x);
    },
    onProgress: (info, received) {
      final x = _xfer(info.xid);
      if (x == null) return;
      x.sent = received;
      x.status = XferStatus.active;
      notifyListeners();
    },
    onComplete: (info, path) {
      final x = _xfer(info.xid);
      if (x != null) {
        x.sent = x.size;
        x.status = XferStatus.done;
        x.path = path;
      }
      receivedFiles.insert(0, ReceivedFile(info.name, path));
      if (receivedFiles.length > 100) receivedFiles.removeLast();
      notifyListeners();
      onFileReceived?.call(info.name, path);
    },
    onError: (info, reason) {
      final x = _xfer(info.xid);
      if (x != null && x.status != XferStatus.rejected) {
        x.status = XferStatus.failed;
        notifyListeners();
      }
    },
  );

  // acceptOffer / rejectOffer answer a parked incoming offer (driven by the
  // accept/reject dialog). accept lets the desktop start streaming; reject tells
  // it to send nothing.
  void acceptOffer(String xid) {
    final x = _xfer(xid);
    if (x != null) x.status = XferStatus.active;
    _fileRx.accept(xid);
    notifyListeners();
  }

  void rejectOffer(String xid) {
    final x = _xfer(xid);
    if (x != null) x.status = XferStatus.rejected;
    _fileRx.reject(xid);
    notifyListeners();
  }

  // Files sent up to the desktop (newest first), recorded on a successful send
  // so the phone can list / re-open / share them beyond the send toast.
  final List<SentFile> sentFiles = [];

  // sendFile streams a phone file up to the desktop host over the relay (no `to`
  // → routed to the host). Returns a handle the UI can cancel / await. The host
  // auto-accepts (its own user's push), so this completes without a prompt; a
  // live FileXfer tracks progress and a successful send is recorded in sentFiles.
  FileSendHandle sendFile(
    String path, {
    String? sid,
    void Function(int sent, int total)? onProgress,
    void Function(bool ok, String msg)? onDone,
  }) {
    final name = path.split('/').last;
    late final FileSendHandle h;
    h = sendFileOverChannel(
      path: path,
      send: send,
      sid: sid,
      requireAccept: true,
      onProgress: (sent, total) {
        final x = _xfer(h.xid);
        if (x != null) {
          x.sent = sent;
          x.size = total;
          x.status = XferStatus.active;
          notifyListeners();
        }
        onProgress?.call(sent, total);
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
        if (ok) {
          sentFiles.insert(0, SentFile(name, path));
          if (sentFiles.length > 100) sentFiles.removeLast();
          notifyListeners();
        }
        _outById.remove(h.xid);
        onDone?.call(ok, msg);
      },
    );
    _outById[h.xid] = h;
    _addXfer(
      FileXfer(
        xid: h.xid,
        name: name,
        size: 0,
        dir: XferDir.send,
        peer: 0,
        peerName: '电脑',
        status: XferStatus.waiting,
        path: path,
      ),
    );
    notifyListeners();
    return h;
  }

  // _dispatchFile routes a file.* frame. accept/reject/ack and a cancel of one
  // of OUR outgoing xids resolve the matching send handle's gate; anything else
  // (offer/chunk/end, or a cancel of an inbound transfer) goes to the receiver.
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
            ..cancel(); // receiver aborted our send (gate or mid-stream)
          return;
        }
    }
    _fileRx.dispatch(f);
  }

  // File browser (single current directory, mobile-friendly).
  String? fsPath;
  List<RemoteEntry> fsEntries = [];
  bool fsLoading = false;
  String? fsError;

  // File viewer + editor.
  String? filePath;
  String? fileContent;
  bool fileLoading = false;
  String? fileError;
  bool fileSaving = false;
  String? fileSaveError;

  // Git view: working-tree changes + recent commits for the selected repo.
  String? gitRepo;
  List<RemoteGitChange> gitChanges = [];
  List<RemoteGitCommit> gitCommits = [];
  bool gitLoading = false;
  String? gitError;
  List<RemoteBranch> branches = [];
  String? gitOpError; // last failed git operation (for a transient toast)

  // Project management: worktrees of the project being managed (wtProject=path).
  String? wtProject;
  List<RemoteWorktree> worktrees = [];
  String? cfgError; // last failed config op (for a transient toast)

  // Diff viewer (a file's working diff, or a commit's full diff).
  String? diffTitle;
  String? diffContent;
  bool diffLoading = false;
  String? diffError;
  bool diffFull = false; // 全部/相关: true = whole-file context
  // Last diff request, kept so the 全部/相关 toggle can re-issue the same source.
  String? _diffRepo;
  String? _diffFile; // working-diff file (null for a commit)
  String? _diffHash; // commit hash (null for a working diff)

  // Pushed notifications (newest first) + unread count for the AppBar bell.
  final List<RemoteNotice> notices = [];
  int unreadNotices = 0;
  void markNoticesRead() {
    if (unreadNotices == 0) return;
    unreadNotices = 0;
    notifyListeners();
  }

  final Map<String, Terminal> _terminals = {};
  final Map<String, Timer> _resizeTimers = {}; // debounce phone resize per session

  bool get hostOnline => _hostOnline;
  String? get error => lastError;

  void connect() => start();

  @override
  void onConnected() {
    _sendHello(); // announce device name so the host can label this phone
    send({'t': 'list'}); // discover host on connect
  }

  @override
  void onDisconnected() => _hostOnline = false;

  @override
  void onPeer(int connId, String role, bool connected) {
    if (role != 'host') return;
    if (connected) send({'t': 'list'});
    _setHostOnline(connected);
    notifyListeners();
  }

  // _setHostOnline centralizes the host-online flag so a false→true transition
  // (we (re)connected to an online host, or the host reappeared) auto re-subscribes
  // our open terminals — the mirror self-heals without a manual 刷新.
  void _setHostOnline(bool v) {
    if (v && !_hostOnline) {
      _hostOnline = true;
      _resyncOpenTerminals();
    } else {
      _hostOnline = v;
    }
  }

  // _resyncOpenTerminals re-opens every currently-open terminal: a reconnect gives
  // us a new connId, so the host no longer mirrors our previously-open sessions
  // (its watchers were keyed to the old connId). reloadTerminal re-sends term.open
  // → the host re-subscribes us and replays the latest screen. The active session
  // page rebinds its TerminalView via onTerminalReset (it isn't a client Listenable).
  void _resyncOpenTerminals() {
    if (_terminals.isEmpty) return;
    for (final sid in _terminals.keys.toList()) {
      reloadTerminal(sid);
    }
    onTerminalReset?.call();
  }

  // Fired after a reconnect-driven terminal reload so the foreground session page
  // can setState and rebind to the freshly-recreated Terminal.
  void Function()? onTerminalReset;

  @override
  void onFrame(Map<String, dynamic> f) {
    final t = f['t'];
    // File transfer frames split by role: accept/reject/ack/cancel for a file we
    // are SENDING route to its handle; offer/chunk/end (and cancels of an inbound
    // file) go to the receiver.
    if (t is String && t.startsWith('file.')) {
      _dispatchFile(t, f);
      return;
    }
    switch (t) {
      case 'sessions':
        sessions = [
          for (final s in (f['items'] as List? ?? []))
            RemoteSession(
              s['sid'] as String,
              (s['title'] as String?) ?? '',
              (s['workdir'] as String?) ?? '',
              (s['agent'] as String?) ?? 'claude',
            ),
        ];
        _setHostOnline(true);
        notifyListeners();
      case 'roots':
        roots = [
          for (final r in (f['items'] as List? ?? []))
            RemoteRootInfo(
              r['name'] as String,
              r['path'] as String,
              (r['workspace'] as String?) ?? '',
            ),
        ];
        notifyListeners();
      case 'notify':
        final title = (f['title'] as String?) ?? '通知';
        final body = (f['body'] as String?) ?? '';
        notices.insert(0, RemoteNotice(title, body));
        if (notices.length > 50) notices.removeLast();
        unreadNotices++;
        Notifications.show(title, body); // OS banner (works in background too)
        notifyListeners();
      case 'term.output':
        final sid = f['sid'] as String?;
        final d = f['d'] as String?;
        if (sid != null && d != null) _terminals[sid]?.write(d);
      case 'reply':
        // The desktop pushed an agent's clean reply text for a watched session;
        // the terminal screen reads it aloud if its TTS toggle is on.
        final sid = f['sid'] as String?;
        final text = f['text'] as String?;
        if (sid != null && text != null) onReplyText?.call(sid, text);
      case 'status':
        // Agent working/idle state for a watched session → Live Activity.
        final sid = f['sid'] as String?;
        if (sid != null) {
          onAgentStatus?.call(
            sid,
            (f['working'] as bool?) ?? false,
            (f['text'] as String?) ?? '',
          );
        }
      case 'fs.list.ok':
        fsPath = f['path'] as String?;
        fsEntries = [
          for (final e in (f['entries'] as List? ?? []))
            RemoteEntry(
              e['name'] as String,
              (e['dir'] as bool?) ?? false,
              (e['size'] as num?)?.toInt() ?? 0,
            ),
        ];
        fsLoading = false;
        fsError = null;
        notifyListeners();
      case 'fs.read.ok':
        filePath = f['path'] as String?;
        fileContent = f['content'] as String?;
        fileLoading = false;
        fileError = null;
        notifyListeners();
      case 'fs.write.ok':
        fileSaving = false;
        fileSaveError = null;
        notifyListeners();
      case 'fs.write.err':
        fileSaving = false;
        fileSaveError = (f['msg'] as String?) ?? '失败';
        notifyListeners();
      case 'fs.err':
        if (fileLoading) {
          fileLoading = false;
          fileError = (f['msg'] as String?) ?? '失败';
        }
        if (fsLoading) {
          fsLoading = false;
          fsError = (f['msg'] as String?) ?? '失败';
        }
        notifyListeners();
      case 'git.status.ok':
        gitRepo = f['path'] as String?;
        gitChanges = [
          for (final c in (f['changes'] as List? ?? []))
            RemoteGitChange(
              c['path'] as String,
              (c['status'] as String?) ?? 'M',
              (c['staged'] as bool?) ?? false,
              (c['untracked'] as bool?) ?? false,
              (c['conflicted'] as bool?) ?? false,
            ),
        ];
        gitCommits = [
          for (final c in (f['commits'] as List? ?? []))
            RemoteGitCommit(
              c['hash'] as String,
              (c['short'] as String?) ?? '',
              (c['author'] as String?) ?? '',
              (c['date'] as String?) ?? '',
              (c['subject'] as String?) ?? '',
            ),
        ];
        gitLoading = false;
        gitError = null;
        notifyListeners();
      case 'git.diff.ok':
      case 'git.show.ok':
        diffContent = (f['diff'] as String?) ?? '';
        diffLoading = false;
        diffError = null;
        notifyListeners();
      case 'git.err':
        if (diffLoading) {
          diffLoading = false;
          diffError = (f['msg'] as String?) ?? '失败';
        } else {
          gitLoading = false;
          gitError = (f['msg'] as String?) ?? '失败';
        }
        notifyListeners();
      case 'git.op.ok':
        gitOpError = null;
        if (gitRepo != null) refreshGit();
      case 'git.op.err':
        gitOpError = (f['msg'] as String?) ?? '失败';
        notifyListeners();
      case 'git.branches.ok':
        branches = [
          for (final b in (f['branches'] as List? ?? []))
            RemoteBranch(
              b['name'] as String,
              (b['current'] as bool?) ?? false,
              (b['remote'] as bool?) ?? false,
              (b['ahead'] as num?)?.toInt() ?? 0,
              (b['behind'] as num?)?.toInt() ?? 0,
            ),
        ];
        notifyListeners();
      case 'wt.list.ok':
        wtProject = f['path'] as String?;
        worktrees = [
          for (final w in (f['worktrees'] as List? ?? []))
            RemoteWorktree(w['path'] as String, (w['branch'] as String?) ?? ''),
        ];
        notifyListeners();
      case 'cfg.ok':
        cfgError = null;
        if (wtProject != null) loadWorktrees(wtProject!);
      case 'cfg.err':
        cfgError = (f['msg'] as String?) ?? '失败';
        notifyListeners();
    }
  }

  void refresh() => send({'t': 'list'});

  // sendKeys injects raw bytes into a session (for an on-screen key bar — phone
  // soft keyboards lack Esc / Ctrl / arrows that agent TUIs need).
  void sendKeys(String sid, String data) =>
      send({'t': 'term.input', 'sid': sid, 'd': data});

  // terminalFor returns (creating on first use) the xterm Terminal for a session,
  // wired so host output is written in and local keystrokes/resizes go back.
  Terminal terminalFor(String sid) {
    final existing = _terminals[sid];
    if (existing != null) return existing;
    final term = Terminal(maxLines: 5000);
    _terminals[sid] = term;
    // Same wheel fix as the desktop so touch-scroll reaches full-screen TUIs;
    // without it xterm's default handler drops the wheel while the app tracks.
    term.mouseHandler = const WheelMouseHandler();
    term.onOutput = (d) => send({'t': 'term.input', 'sid': sid, 'd': d});
    // Debounce resize: rotation / window drags fire a burst of onResize calls;
    // sending only the last one ~120ms later spares the PTY a string of redraws.
    term.onResize = (w, h, pw, ph) {
      _resizeTimers[sid]?.cancel();
      _resizeTimers[sid] = Timer(const Duration(milliseconds: 120), () {
        send({'t': 'term.resize', 'sid': sid, 'rows': h, 'cols': w});
      });
    };
    send({'t': 'term.open', 'sid': sid, 'historyMode': historyMode});
    return term;
  }

  // reloadTerminal drops the cached Terminal and recreates it, so the phone's
  // buffer starts empty and the host's term.open reply (backlog replay) shows
  // the computer's current screen/history instead of appending to stale
  // content. The caller rebuilds so the TerminalView rebinds to the new term.
  void reloadTerminal(String sid) {
    _terminals.remove(sid);
    _resizeTimers.remove(sid)?.cancel();
    terminalFor(sid); // recreate + send term.open now → host replays backlog
  }

  // Session write actions (the host re-broadcasts `sessions` after each).
  // workdir targets a worktree under the project (the host validates it lives in
  // the project root or its .worktrees/); omitted/equal to project = main checkout.
  void newSession(String projectPath, String agent, {String? workdir}) => send({
    't': 'session.new',
    'project': projectPath,
    'agent': agent,
    if (workdir != null && workdir != projectPath) 'workdir': workdir,
  });
  void closeSession(String sid) => send({'t': 'session.close', 'sid': sid});
  void renameSession(String sid, String name) =>
      send({'t': 'session.rename', 'sid': sid, 'name': name});

  void openDir(String path) {
    fsLoading = true;
    fsError = null;
    notifyListeners();
    send({'t': 'fs.list', 'path': path});
  }

  void openFile(String path) {
    fileLoading = true;
    fileError = null;
    filePath = path;
    fileContent = null;
    notifyListeners();
    send({'t': 'fs.read', 'path': path});
  }

  void saveFile(String path, String content) {
    fileSaving = true;
    fileSaveError = null;
    notifyListeners();
    send({'t': 'fs.write', 'path': path, 'content': content});
  }

  void openGit(String repo) {
    gitRepo = repo;
    gitChanges = [];
    gitCommits = [];
    gitLoading = true;
    gitError = null;
    notifyListeners();
    send({'t': 'git.status', 'path': repo});
  }

  void refreshGit() {
    final r = gitRepo;
    if (r != null) openGit(r);
  }

  void requestWorkingDiff(String repo, String file, {bool full = false}) {
    diffTitle = file;
    diffContent = null;
    diffLoading = true;
    diffError = null;
    diffFull = full;
    _diffRepo = repo;
    _diffFile = file;
    _diffHash = null;
    notifyListeners();
    send({'t': 'git.diff', 'path': repo, 'file': file, 'full': full});
  }

  void requestCommitDiff(String repo, String hash, String title,
      {bool full = false}) {
    diffTitle = title;
    diffContent = null;
    diffLoading = true;
    diffError = null;
    diffFull = full;
    _diffRepo = repo;
    _diffFile = null;
    _diffHash = hash;
    notifyListeners();
    send({'t': 'git.show', 'path': repo, 'hash': hash, 'full': full});
  }

  // reloadDiff re-issues the current diff request at the given context (the
  // 全部/相关 toggle) using the remembered source.
  void reloadDiff(bool full) {
    final repo = _diffRepo;
    if (repo == null) return;
    if (_diffHash != null) {
      requestCommitDiff(repo, _diffHash!, diffTitle ?? '', full: full);
    } else if (_diffFile != null) {
      requestWorkingDiff(repo, _diffFile!, full: full);
    }
  }

  // Git write ops — host replies git.op.ok (→ auto refresh) or git.op.err.
  void gitStage(String repo, String file) =>
      send({'t': 'git.stage', 'path': repo, 'file': file});
  void gitUnstage(String repo, String file) =>
      send({'t': 'git.unstage', 'path': repo, 'file': file});
  void gitStageAll(String repo) => send({'t': 'git.stageAll', 'path': repo});
  void gitUnstageAll(String repo) =>
      send({'t': 'git.unstageAll', 'path': repo});
  void gitDiscard(String repo, String file) =>
      send({'t': 'git.discard', 'path': repo, 'file': file});
  void gitDiscardAll(String repo) =>
      send({'t': 'git.discardAll', 'path': repo});
  void gitCommit(String repo, String message, {bool push = false}) =>
      send({'t': 'git.commit', 'path': repo, 'message': message, 'push': push});
  void gitPush(String repo) => send({'t': 'git.push', 'path': repo});
  void gitPull(String repo) => send({'t': 'git.pull', 'path': repo});
  void gitFetch(String repo) => send({'t': 'git.fetch', 'path': repo});
  void loadBranches(String repo) => send({'t': 'git.branches', 'path': repo});
  void gitCheckout(String repo, String branch) =>
      send({'t': 'git.checkout', 'path': repo, 'branch': branch});
  void gitCreateBranch(String repo, String branch) =>
      send({'t': 'git.createBranch', 'path': repo, 'branch': branch});
  void gitStash(String repo, String message) =>
      send({'t': 'git.stash', 'path': repo, 'message': message});
  void gitStashPop(String repo, String ref) =>
      send({'t': 'git.stashPop', 'path': repo, 'ref': ref});

  // Project management — host replies cfg.ok (→ rebroadcast roots) or cfg.err.
  void loadWorktrees(String projectPath) =>
      send({'t': 'wt.list', 'path': projectPath});
  void newWorkspace(String name, String path) =>
      send({'t': 'ws.new', 'name': name, if (path.isNotEmpty) 'path': path});
  void removeWorkspace(String name) => send({'t': 'ws.remove', 'name': name});
  void addProject(String workspace, String source) =>
      send({'t': 'proj.add', 'workspace': workspace, 'source': source});
  void removeProject(String workspace, String project) =>
      send({'t': 'proj.remove', 'workspace': workspace, 'project': project});
  void addWorktree(
    String workspace,
    String project,
    String branch,
    String start,
  ) => send({
    't': 'wt.add',
    'workspace': workspace,
    'project': project,
    'branch': branch,
    if (start.isNotEmpty) 'start': start,
  });
  void removeWorktree(String workspace, String project, String branch) => send({
    't': 'wt.remove',
    'workspace': workspace,
    'project': project,
    'branch': branch,
    'force': true,
  });
}
