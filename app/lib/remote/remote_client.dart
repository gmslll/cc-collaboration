import 'dart:async';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:xterm/xterm.dart';

import '../local/hook_activity.dart';
import '../local/path_utils.dart';
import '../local/session_overview.dart';
import '../notifications.dart';
import '../screen_share/models.dart';
import '../screen_share/webrtc.dart';
import '../terminal_mouse.dart';
import '../terminal_theme.dart';
import 'file_fs.dart';
import 'file_transfer.dart';
import 'pty_transport.dart';
import 'pty_transport_webrtc.dart';
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
  final String workspace;
  final String project;
  final String projectId;
  RemoteSession(
    this.sid,
    this.title,
    this.workdir,
    this.agent, {
    this.workspace = '',
    this.project = '',
    this.projectId = '',
  });
}

// phoneRemoteClient is the phone's single live RemoteClient (its WS connection to
// the paired desktop host), published here by RemoteWorkspacePage — which owns
// its lifecycle and is always mounted in the mobile IndexedStack — so a sibling
// page (TodosPage's 一键指派) can reach the desktop's live sessions/roots and
// send a remote assign, without prop-drilling the instance through main.dart.
// Null on desktop (no RemoteWorkspacePage) and before the page first builds.
RemoteClient? phoneRemoteClient;

class RemoteRootInfo {
  final String name;
  final String path;
  final String workspace;
  final String projectId;
  RemoteRootInfo(this.name, this.path, this.workspace, [this.projectId = '']);
}

class RemoteWorktree {
  final String path;
  final String branch;
  RemoteWorktree(this.path, this.branch);
  String get name {
    final name = pathBaseName(path);
    return name.isEmpty ? path : name;
  }
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

enum _ClientPtyRouteState { opening, ready, failed }

class _ClientPtyRoute {
  _ClientPtyRoute({required this.id, required this.p2p});

  final String id;
  final bool p2p;
  _ClientPtyRouteState state = _ClientPtyRouteState.opening;
  int nextSendSequence = 1;
  int nextReceiveSequence = 1;
  ({int rows, int cols})? pendingResize;
}

// RemoteClient is the phone side of the remote workspace: over the relay (see
// RemoteChannel for transport) it discovers the desktop host's terminal sessions
// and project roots, drives terminals (xterm fed by network bytes, keystrokes
// sent back), and browses/reads files. Read-only files for now (editing later).
class RemoteClient extends RemoteChannel {
  RemoteClient({
    required super.relayUrl,
    required super.token,
    super.socketConnector,
    PtyTransportMode ptyTransportMode = PtyTransportMode.auto,
    PtyPeerFactory? ptyPeerFactory,
  }) : _ptyMode = ptyTransportMode,
       super(role: 'client') {
    _ptyTransport = PtyClientTransportController(
      mode: ptyTransportMode,
      peerFactory: ptyPeerFactory ?? WebRtcPtyPeerFactory(),
      sendSignal: send,
      onFrame: _onPtyFrame,
      onStatus: _onPtyStatus,
    );
    _loadDeviceName();
  }

  bool _hostOnline = false;
  late final PtyClientTransportController _ptyTransport;
  PtyTransportMode _ptyMode;
  PtyPeerStatus? _ptyStatus;
  String? _ptyLocalError;
  int? _hostPeerId;
  int _routeCounter = 0;
  Timer? _p2pConnectTimer;
  bool _ptyDisposed = false;
  bool _ptyRecovering = false;
  int _ptyOperationEpoch = 0;
  final Map<String, _ClientPtyRoute> _ptyRoutes = {};

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
  // All workspace names the host advertises (incl. empty ones with no projects),
  // so the manage view can show + add projects to a freshly-created workspace.
  List<String> workspaceNames = [];
  // overview holds the rich per-session snapshot (status + usage + reply
  // preview) the desktop pushes for the 总览 grid, keyed by session id. Distinct
  // from `sessions` (membership): membership updates whenever a session is
  // added/closed; overview updates on turn boundaries. The grid renders one card
  // per `sessions` entry, enriched with overview[sid] when present (degrades to
  // title-only otherwise).
  Map<String, SessionCard> overview = {};
  // screens holds the latest one-shot terminal snapshot per session id, fetched
  // by the quick-reply popup via requestScreen (distinct from the full mirror's
  // streamed output). Updated on each `screen` reply. The record carries the
  // host terminal's geometry so the popup renders at the computer's width
  // instead of reflowing TUI chrome to the phone's narrow width.
  Map<String, ScreenSnapshot> screens = {};
  Map<String, List<HookActivity>> activities = {};

  List<ShareSource> shareSources = [];
  bool shareLoading = false;
  String? shareError;
  String shareStatus = '未连接';
  Timer? _shareSourcesTimer;
  NativeShareViewer? _shareViewer;
  NativeShareViewer get shareViewer =>
      _shareViewer ??= NativeShareViewer(sendFrame: send)
        ..addListener(_onShareViewerChanged);

  void _onShareViewerChanged() {
    final viewer = _shareViewer;
    if (viewer != null) shareStatus = viewer.status;
    notifyListeners();
  }

  // onReplyText fires when the desktop pushes an agent's clean reply text for a
  // watched session (the terminal screen reads it aloud). Not a ChangeNotifier
  // field — it's a transient one-shot, not rebuildable state.
  void Function(String sid, String text)? onReplyText;

  // onAgentStatus fires when the desktop pushes a watched session's working/idle
  // state (+ a short text, + an optional usage label e.g. "opus 4.8 · ctx 45% ·
  // 1.2M tok · ~$3.40"). The terminal screen drives an iOS Live Activity /
  // Dynamic Island from it so the user can leave the app and still see progress.
  void Function(String sid, bool working, String text, String? usage)?
  onAgentStatus;

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
    final name = pathBaseName(path);
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
  final Map<String, Timer> _resizeTimers =
      {}; // debounce client resize per session
  final Map<String, Timer> _resizeRefreshTimers = {};
  final Map<String, ({int rows, int cols})> _resizeRefreshAttempted = {};
  final Map<String, DateTime> _resizeRefreshReplayUntil = {};
  // Sessions whose viewport size has already been reported to the host. The
  // first onResize for a sid is sent immediately (no debounce) so the host
  // redraws at this device's size promptly; later resizes debounce. Dropped on
  // eviction so a re-opened session reports its (possibly new device's) size
  // afresh. adoptSize() additionally re-asserts size when switching devices.
  final Set<String> _sizedSids = {};
  // Last viewport size this device laid out for each sid (updated on every
  // onResize). term.open carries it so the host sizes the PTY to THIS phone
  // BEFORE replaying history — otherwise the replay (and the agent's current
  // screen) comes back at the desktop's width and overflows the phone, which a
  // non-active session never auto-corrects (idle agent doesn't redraw).
  final Map<String, ({int cols, int rows})> _lastViewport = {};
  // The most recent viewport laid out for ANY session on this device — i.e.
  // THIS phone's screen size. Used as the fallback when opening a session this
  // device hasn't sized yet (first-ever open), so term.open/adoptSize send the
  // phone's real width instead of falling back to the Terminal's default 80.
  ({int cols, int rows})? _lastKnownViewport;
  // User/program fallback for the first open before xterm has reported a real
  // onResize. The terminal screen keeps this updated from its current viewport
  // estimate; the menu can also set a user default.
  ({int cols, int rows})? defaultViewport;

  // Local terminal-history cache + idle eviction. Each opened session keeps its
  // xterm buffer (replayed history + accumulated live output); left untouched it
  // drifts stale (mis-wrapped backlog, dropped frames). A session not viewed /
  // operated for [_historyTtl] has its buffer dropped — by a periodic sweep and a
  // check when its screen re-opens — so the next open re-pulls a clean copy from
  // the desktop. _viewedSid is the session whose screen is open now: never evicted
  // out from under the user.
  final Map<String, DateTime> _lastActive = {};
  static const Duration _historyTtl = Duration(minutes: 5);
  String? _viewedSid;
  Timer? _evictTimer;

  bool get hostOnline => _hostOnline;
  String? get error => lastError;
  PtyTransportMode get ptyTransportMode => _ptyMode;
  PtyPeerState get ptyPeerState => _ptyMode == PtyTransportMode.relay
      ? PtyPeerState.relay
      : (_ptyStatus?.state ?? PtyPeerState.closed);
  String? get ptyError => _ptyLocalError ?? _ptyStatus?.error;

  String get ptyTransportStatusLabel {
    if (_ptyMode == PtyTransportMode.relay) return 'Relay';
    if (ptyPeerState == PtyPeerState.p2p) return 'P2P';
    if (_ptyMode == PtyTransportMode.p2p) {
      if (ptyError != null || ptyPeerState == PtyPeerState.failed) {
        return 'P2P 失败';
      }
      return 'P2P 连接中';
    }
    if (ptyPeerState == PtyPeerState.connecting) return 'Relay · P2P 连接中';
    if (ptyPeerState == PtyPeerState.failed) return 'Relay · P2P 不可用';
    return 'Relay';
  }

  bool ptyInputBlocked(String sid) {
    if (_ptyMode != PtyTransportMode.p2p) return false;
    final route = _ptyRoutes[sid];
    return route == null ||
        !route.p2p ||
        route.state != _ClientPtyRouteState.ready;
  }

  Future<void> setPtyTransportMode(PtyTransportMode mode) async {
    if (mode == _ptyMode) {
      if (mode == PtyTransportMode.p2p) await retryP2P();
      return;
    }
    final previousMode = _ptyMode;
    final operation = ++_ptyOperationEpoch;
    _p2pConnectTimer?.cancel();
    _ptyLocalError = null;
    final hadRelayRoute = _ptyRoutes.values.any((route) => !route.p2p);
    // Route teardown is a Relay control message and is sent before changing
    // transport state. In particular, entering strict P2P must stop the host's
    // existing Relay watcher instead of merely discarding its output locally.
    _closeAllTerminalRoutes();
    final reconnectForStrictPrivacy =
        mode == PtyTransportMode.p2p &&
        previousMode != PtyTransportMode.p2p &&
        (previousMode == PtyTransportMode.relay || hadRelayRoute) &&
        connected;
    // A pre-P2P host may ignore term.close, and a saturated broker may drop it.
    // Reconnecting forces every host version to drop the old connId watcher.
    if (reconnectForStrictPrivacy) kick();
    _ptyMode = mode;
    await _ptyTransport.setMode(mode);
    if (_ptyDisposed || operation != _ptyOperationEpoch || _ptyMode != mode) {
      return;
    }
    if (reconnectForStrictPrivacy) {
      notifyListeners();
      return;
    }
    final host = _hostPeerId;
    if (host != null && mode != PtyTransportMode.relay) {
      _ptyTransport.hostConnected(host);
      if (mode == PtyTransportMode.p2p) _armP2PConnectTimeout(host);
    }
    _reopenTerminalRoutes();
    notifyListeners();
  }

  Future<void> retryP2P() async {
    if (_ptyMode == PtyTransportMode.relay) return;
    final host = _hostPeerId;
    if (host == null) {
      _ptyLocalError = '等待电脑端在线';
      notifyListeners();
      return;
    }
    _p2pConnectTimer?.cancel();
    _ptyLocalError = null;
    final operation = ++_ptyOperationEpoch;
    final mode = _ptyMode;
    final epoch = _ptyStatus?.epoch ?? 0;
    if (epoch > 0) {
      send({
        't': ptySignalFrameType,
        'to': host,
        'kind': 'close',
        'epoch': epoch,
        'reason': 'client retry',
      });
    }
    await _ptyTransport.restartPeer(host);
    if (_ptyDisposed ||
        operation != _ptyOperationEpoch ||
        _ptyMode != mode ||
        _hostPeerId != host) {
      return;
    }
    _ptyTransport.hostConnected(host);
    if (_ptyMode == PtyTransportMode.p2p) _armP2PConnectTimeout(host);
    notifyListeners();
  }

  void connect() => start();

  @override
  void onConnected() {
    _sendHello(); // announce device name so the host can label this phone
    send({'t': 'list'}); // discover host on connect
  }

  @override
  void onDisconnected() {
    _ptyOperationEpoch++;
    _p2pConnectTimer?.cancel();
    final host = _hostPeerId;
    _hostPeerId = null;
    if (host != null) unawaited(_ptyTransport.peerDisconnected(host));
    for (final route in _ptyRoutes.values) {
      if (route.p2p) route.state = _ClientPtyRouteState.failed;
    }
    if (_ptyMode == PtyTransportMode.p2p) {
      _ptyLocalError ??= '电脑连接已断开';
    }
    _hostOnline = false;
    _shareSourcesTimer?.cancel();
    _shareSourcesTimer = null;
    if (shareLoading) {
      shareLoading = false;
      shareError = '连接已断开';
    }
    _completeAllAssigns('连接已断开');
    unawaited(_shareViewer?.stop(closeRenderer: false));
  }

  @override
  void onPeer(int connId, String role, bool connected) {
    if (role != 'host') return;
    if (connected) {
      _rememberHost(connId);
      send({'t': 'list', 'to': connId});
    } else if (_hostPeerId == connId) {
      _ptyOperationEpoch++;
      _p2pConnectTimer?.cancel();
      _hostPeerId = null;
      for (final route in _ptyRoutes.values) {
        if (route.p2p) route.state = _ClientPtyRouteState.failed;
      }
      if (_ptyMode == PtyTransportMode.p2p) {
        _ptyLocalError ??= '电脑连接已断开';
      }
      unawaited(_ptyTransport.peerDisconnected(connId));
    }
    _setHostOnline(connected);
    notifyListeners();
  }

  void _rememberHost(int peerId) {
    if (peerId <= 0 || _hostPeerId == peerId) return;
    _ptyOperationEpoch++;
    final previous = _hostPeerId;
    _hostPeerId = peerId;
    if (previous != null) unawaited(_ptyTransport.peerDisconnected(previous));
    if (_ptyMode != PtyTransportMode.relay) {
      _ptyTransport.hostConnected(peerId);
      if (_ptyMode == PtyTransportMode.p2p) _armP2PConnectTimeout(peerId);
    }
  }

  void _armP2PConnectTimeout(int peerId) {
    _p2pConnectTimer?.cancel();
    _p2pConnectTimer = Timer(const Duration(seconds: 3), () {
      if (_hostPeerId != peerId ||
          _ptyMode != PtyTransportMode.p2p ||
          ptyPeerState == PtyPeerState.p2p) {
        return;
      }
      _ptyLocalError = 'P2P 直连超时';
      for (final route in _ptyRoutes.values) {
        if (route.p2p) route.state = _ClientPtyRouteState.failed;
      }
      notifyListeners();
    });
  }

  void _onPtyStatus(PtyPeerStatus status) {
    if (_ptyDisposed) return;
    if (status.peerId != _hostPeerId) return;
    final previous = _ptyStatus?.state;
    _ptyStatus = status;
    if (status.state == PtyPeerState.p2p) {
      _p2pConnectTimer?.cancel();
      _ptyLocalError = null;
      if (previous != PtyPeerState.p2p && _ptyMode != PtyTransportMode.relay) {
        scheduleMicrotask(_reopenTerminalRoutes);
      }
    } else if ((status.state == PtyPeerState.failed ||
            status.state == PtyPeerState.closed) &&
        previous == PtyPeerState.p2p) {
      if (_ptyMode == PtyTransportMode.auto) {
        final host = _hostPeerId;
        if (host != null) unawaited(_recoverAutomaticPty(host));
      } else if (_ptyMode == PtyTransportMode.p2p) {
        _ptyLocalError = status.error ?? _ptyLocalError ?? 'P2P 连接已断开';
        for (final route in _ptyRoutes.values) {
          if (route.p2p) route.state = _ClientPtyRouteState.failed;
        }
      }
    }
    notifyListeners();
  }

  void _onPtyFrame(int peerId, Map<String, dynamic> frame) {
    if (_ptyDisposed) return;
    if (peerId != _hostPeerId) return;
    _handlePtyDataFrame(frame, viaP2P: true);
  }

  void _handlePtyDataFrame(Map<String, dynamic> frame, {required bool viaP2P}) {
    final type = frame['t'];
    final sidValue = frame['sid'];
    if (sidValue is! String || sidValue.isEmpty) return;
    final sid = sidValue;
    final route = _ptyRoutes[sid];

    // An older host does not echo routeId/seq. Keep upgraded clients compatible
    // on Relay, but never admit an unbound frame from a DataChannel.
    if (route == null) {
      final data = frame['d'];
      if (!viaP2P && type == 'term.output' && data is String) {
        _applyTerminalOutput(sid, data);
      }
      return;
    }
    final routeIdValue = frame['routeId'];
    if (routeIdValue != null && routeIdValue is! String) {
      _failPtyRoute(sid, 'PTY routeId 类型无效');
      return;
    }
    final routeId = routeIdValue is String ? routeIdValue : null;
    final legacyRelay = !viaP2P && !route.p2p && routeId == null;
    if (!legacyRelay && routeId != route.id) return;
    if (route.p2p != viaP2P && !legacyRelay && type != 'term.routeFailed') {
      return;
    }

    if (type == 'term.routeFailed') {
      final reason = frame['reason'];
      _failPtyRoute(sid, reason is String ? reason : 'PTY 路由失败');
      return;
    }
    if (type == 'term.ready') {
      route.state = _ClientPtyRouteState.ready;
      final pending = route.pendingResize;
      route.pendingResize = null;
      if (pending != null) {
        _sendTermFrame(sid, {
          't': 'term.resize',
          'sid': sid,
          'rows': pending.rows,
          'cols': pending.cols,
        });
      }
      notifyListeners();
      return;
    }
    if (type != 'term.output') return;

    final data = frame['d'];
    if (data is! String) {
      if (!legacyRelay) _failPtyRoute(sid, 'PTY 输出内容类型无效');
      return;
    }
    final seqValue = frame['seq'];
    final seq = seqValue is int ? seqValue : null;
    if (seq == null) {
      if (!legacyRelay) {
        _failPtyRoute(sid, 'PTY 输出缺少序号');
        return;
      }
    } else if (seq < route.nextReceiveSequence) {
      return;
    } else if (seq > route.nextReceiveSequence) {
      _failPtyRoute(sid, 'PTY 输出序号不连续');
      return;
    } else {
      route.nextReceiveSequence++;
    }
    _applyTerminalOutput(sid, data);
  }

  void _applyTerminalOutput(String sid, String data) {
    _resizeRefreshTimers.remove(sid)?.cancel();
    final replayUntil = _resizeRefreshReplayUntil[sid];
    if (replayUntil == null || DateTime.now().isAfter(replayUntil)) {
      _resizeRefreshReplayUntil.remove(sid);
      _resizeRefreshAttempted.remove(sid);
    }
    _terminals[sid]?.write(data);
  }

  void _failPtyRoute(String sid, String reason) {
    final route = _ptyRoutes[sid];
    if (route == null || route.state == _ClientPtyRouteState.failed) return;
    route.state = _ClientPtyRouteState.failed;
    _ptyLocalError = reason;
    final host = _hostPeerId;
    final epoch = _ptyStatus?.epoch ?? 0;
    if (host != null && epoch > 0) {
      send({
        't': ptySignalFrameType,
        'to': host,
        'kind': 'close',
        'epoch': epoch,
        'reason': reason,
      });
    }
    if (_ptyMode == PtyTransportMode.auto && host != null) {
      unawaited(_recoverAutomaticPty(host));
    } else if (host != null) {
      unawaited(_ptyTransport.restartPeer(host));
    }
    notifyListeners();
  }

  Future<void> _recoverAutomaticPty(int host) async {
    if (_ptyRecovering ||
        _ptyDisposed ||
        _ptyMode != PtyTransportMode.auto ||
        _hostPeerId != host) {
      return;
    }
    final operation = _ptyOperationEpoch;
    _ptyRecovering = true;
    try {
      await _ptyTransport.restartPeer(host);
      if (_ptyDisposed ||
          _ptyMode != PtyTransportMode.auto ||
          _hostPeerId != host ||
          operation != _ptyOperationEpoch) {
        return;
      }
      _reopenTerminalRoutes();
      _ptyTransport.hostConnected(host);
    } finally {
      _ptyRecovering = false;
    }
  }

  void _reopenTerminalRoutes() {
    if (_ptyDisposed || _terminals.isEmpty) return;
    for (final sid in _terminals.keys.toList()) {
      reloadTerminal(sid);
    }
    onTerminalReset?.call();
  }

  void _closeTerminalRoute(String sid, {int? peerId}) {
    final route = _ptyRoutes.remove(sid);
    final host = peerId ?? _hostPeerId;
    if (route == null || host == null) return;
    send({'t': 'term.close', 'to': host, 'sid': sid, 'routeId': route.id});
  }

  void _closeAllTerminalRoutes({int? peerId}) {
    for (final sid in _ptyRoutes.keys.toList()) {
      _closeTerminalRoute(sid, peerId: peerId);
    }
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
    if (t == ptySignalFrameType) {
      final from = f['from'];
      if (from is int && from == _hostPeerId) {
        unawaited(_ptyTransport.handleSignal(f));
      }
      return;
    }
    if (t == 'term.ready' || t == 'term.routeFailed') {
      _handlePtyDataFrame(f, viaP2P: false);
      return;
    }
    // File transfer frames split by role: accept/reject/ack/cancel for a file we
    // are SENDING route to its handle; offer/chunk/end (and cancels of an inbound
    // file) go to the receiver.
    if (t is String && t.startsWith('file.')) {
      _dispatchFile(t, f);
      return;
    }
    if (t is String && t.startsWith('share.')) {
      unawaited(_dispatchShare(t, f));
      return;
    }
    switch (t) {
      case 'sessions':
        final from = (f['from'] as num?)?.toInt();
        if (from != null && from > 0) _rememberHost(from);
        sessions = [
          for (final s in (f['items'] as List? ?? []))
            RemoteSession(
              s['sid'] as String,
              (s['title'] as String?) ?? '',
              (s['workdir'] as String?) ?? '',
              (s['agent'] as String?) ?? 'claude',
              workspace: (s['workspace'] as String?) ?? '',
              project: (s['project'] as String?) ?? '',
              projectId: (s['project_id'] as String?)?.trim() ?? '',
            ),
        ];
        for (final entry in _terminals.entries) {
          _configureTerminalForSession(entry.key, entry.value);
        }
        _setHostOnline(true);
        notifyListeners();
      case 'todo.assign.ok':
        _completeAssign(f['todoId'] as String?, null);
      case 'todo.assign.err':
        _completeAssign(
          f['todoId'] as String?,
          (f['msg'] as String?) ?? '远程指派失败',
        );
      case 'overview':
        final ov = <String, SessionCard>{};
        for (final m in (f['items'] as List? ?? [])) {
          if (m is Map) {
            final c = SessionCard.fromJson(m);
            ov[c.sid] = c;
          }
        }
        overview = ov;
        notifyListeners();
      case 'screen':
        final sid = f['sid'] as String?;
        if (sid != null) {
          // cols/rows absent from an older host → 0; the popup then falls back
          // to a default geometry (roughly the pre-fix reflow behaviour).
          screens[sid] = (
            ansi: (f['text'] as String?) ?? '',
            cols: (f['cols'] as num?)?.toInt() ?? 0,
            rows: (f['rows'] as num?)?.toInt() ?? 0,
          );
          notifyListeners();
        }
      case 'roots':
        roots = [
          for (final r in (f['items'] as List? ?? []))
            RemoteRootInfo(
              r['name'] as String,
              r['path'] as String,
              (r['workspace'] as String?) ?? '',
              (r['project_id'] as String?)?.trim() ?? '',
            ),
        ];
        workspaceNames = [
          for (final w in (f['workspaces'] as List? ?? [])) w.toString(),
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
        _handlePtyDataFrame(f, viaP2P: false);
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
            f['usage'] as String?,
          );
        }
      case 'activity':
        final sid = f['sid'] as String?;
        if (sid != null) {
          activities[sid] = [
            for (final m in (f['items'] as List? ?? []))
              if (m is Map) HookActivity.fromWire(m),
          ];
          notifyListeners();
        }
      case 'fs.list.ok':
        fsPath = f['path'] as String?;
        fsEntries = [
          for (final e in (f['entries'] as List? ?? []))
            RemoteEntry(
              pathBaseName(e['name'] as String? ?? ''),
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

  Future<void> _dispatchShare(String t, Map<String, dynamic> f) async {
    try {
      switch (t) {
        case 'share.sources.ok':
          _shareSourcesTimer?.cancel();
          _shareSourcesTimer = null;
          final next = <ShareSource>[];
          for (final item in (f['items'] as List? ?? [])) {
            final source = ShareSource.fromJson(item);
            if (source != null) next.add(source);
          }
          shareSources = next;
          shareLoading = false;
          shareError = null;
          notifyListeners();
        case 'share.offer':
          final from = (f['from'] as num?)?.toInt();
          if (from == null) return;
          shareStatus = '正在建立连接';
          notifyListeners();
          await shareViewer.applyOffer(from, f['sdp']);
        case 'share.ice':
          await shareViewer.addIce(f['candidate']);
        case 'share.state':
          shareStatus = (f['state'] as String?) ?? shareStatus;
          notifyListeners();
        case 'share.stopped':
          await shareViewer.stop(closeRenderer: false);
          shareStatus = '电脑已停止共享';
          notifyListeners();
        case 'share.err':
          _shareSourcesTimer?.cancel();
          _shareSourcesTimer = null;
          shareLoading = false;
          shareError = (f['msg'] as String?) ?? '屏幕共享失败';
          shareStatus = shareError!;
          notifyListeners();
      }
    } catch (e) {
      shareLoading = false;
      shareError = '$e';
      shareStatus = '$e';
      notifyListeners();
    }
  }

  void requestShareSources() {
    _shareSourcesTimer?.cancel();
    if (!_hostOnline) {
      shareSources = [];
      shareLoading = false;
      shareError = '电脑端未在线，请先在电脑端开启「共享工作区」';
      notifyListeners();
      return;
    }
    shareSources = [];
    shareLoading = true;
    shareError = null;
    notifyListeners();
    send({'t': 'share.sources'});
    _shareSourcesTimer = Timer(const Duration(seconds: 8), () {
      shareLoading = false;
      shareError = '电脑端没有响应';
      notifyListeners();
    });
  }

  void startShare(ShareSource source) {
    shareStatus = '正在请求电脑共享 ${source.name}';
    shareError = null;
    notifyListeners();
    send({'t': 'share.start', 'sourceId': source.id});
  }

  Future<void> stopShare() async {
    send({'t': 'share.stop'});
    await _shareViewer?.stop(closeRenderer: false);
    shareStatus = '已停止';
    notifyListeners();
  }

  // sendKeys injects raw bytes into a session (for an on-screen key bar — phone
  // soft keyboards lack Esc / Ctrl / arrows that agent TUIs need).
  void sendKeys(String sid, String data) {
    touchSession(sid); // input is an operation → keep this session's cache warm
    _sendTermFrame(sid, {'t': 'term.input', 'sid': sid, 'd': data});
  }

  // requestScreen asks the host for a one-shot snapshot of [sid]'s current
  // screen (→ a `screen` reply into `screens`). Drives the quick-reply popup
  // without opening the full mirror.
  void requestScreen(String sid) => send({'t': 'screen', 'sid': sid});

  // terminalFor returns (creating on first use) the xterm Terminal for a session,
  // wired so host output is written in and local keystrokes/resizes go back.
  Terminal terminalFor(String sid) {
    final existing = _terminals[sid];
    if (existing != null) return existing;
    final term = ccTerminal(maxLines: 5000);
    _terminals[sid] = term;
    _configureTerminalForSession(sid, term);
    // Same wheel fix as the desktop so touch-scroll reaches full-screen TUIs;
    // without it xterm's default handler drops the wheel while the app tracks.
    term.mouseHandler = const WheelMouseHandler();
    term.onOutput = (d) =>
        _sendTermFrame(sid, {'t': 'term.input', 'sid': sid, 'd': d});
    term.onResize = (w, h, pw, ph) {
      _lastViewport[sid] = (
        cols: w,
        rows: h,
      ); // remembered for the next term.open
      _lastKnownViewport = (cols: w, rows: h); // this phone's screen size
      // Whoever's watching redraws: the watching client's viewport drives the
      // host PTY. Report this device's real size the moment we first learn it
      // (no debounce) so the host redraws promptly; later resizes debounce.
      if (_sizedSids.add(sid)) {
        _sendResize(sid, rows: h, cols: w);
        return;
      }
      // Debounce later resizes: rotation / keyboard show-hide fire a burst of
      // onResize calls; sending only the last one ~120ms later spares the PTY a
      // string of redraws.
      _resizeTimers[sid]?.cancel();
      _resizeTimers[sid] = Timer(const Duration(milliseconds: 120), () {
        _sendResize(sid, rows: h, cols: w);
      });
    };
    touchSession(sid); // brand-new buffer is fresh
    // Carry this device's viewport so the host sizes the PTY to the phone
    // BEFORE replaying — non-active sessions (and reload) otherwise replay at
    // the desktop/another-device's width and overflow. Fall back to this phone's
    // last-known screen size for a first-ever open of this sid, so we send the
    // real width instead of nothing (which leaves the PTY at the other device's).
    final vp = _lastViewport[sid] ?? _lastKnownViewport ?? defaultViewport;
    _openTerminalRoute(sid, vp);
    return term;
  }

  void _openTerminalRoute(String sid, ({int cols, int rows})? viewport) {
    final host = _hostPeerId;
    final p2pReady = host != null && ptyPeerState == PtyPeerState.p2p;
    final useP2P = _ptyMode != PtyTransportMode.relay && p2pReady;
    final route = _ClientPtyRoute(
      id: '${DateTime.now().microsecondsSinceEpoch}-${++_routeCounter}',
      p2p: useP2P || _ptyMode == PtyTransportMode.p2p,
    );
    _ptyRoutes[sid] = route;

    // Strict P2P never leaks PTY bytes through Relay. Keep the local mirror
    // empty until negotiation succeeds; status UI offers retry / Relay mode.
    if (_ptyMode == PtyTransportMode.p2p && !p2pReady) {
      if (host != null) _armP2PConnectTimeout(host);
      return;
    }
    if (!route.p2p) {
      // Relay is already ordered with term.open. Mark ready immediately for
      // backward compatibility with hosts predating term.ready.
      route.state = _ClientPtyRouteState.ready;
    }
    send({
      't': 'term.open',
      'to': ?host,
      'sid': sid,
      'routeId': route.id,
      'transport': route.p2p ? 'p2p' : 'relay',
      'historyMode': historyMode,
      if (viewport != null) 'cols': viewport.cols,
      if (viewport != null) 'rows': viewport.rows,
    });
  }

  bool _sendTermFrame(String sid, Map<String, dynamic> frame) {
    final route = _ptyRoutes[sid];
    if (route == null || route.state != _ClientPtyRouteState.ready) {
      if (frame['t'] == 'term.resize') {
        route?.pendingResize = (
          rows: (frame['rows'] as num?)?.toInt() ?? 0,
          cols: (frame['cols'] as num?)?.toInt() ?? 0,
        );
      }
      return false;
    }
    final host = _hostPeerId;
    if (host == null) return false;
    final outbound = <String, dynamic>{
      ...frame,
      'routeId': route.id,
      'seq': route.nextSendSequence++,
    };
    if (!route.p2p) {
      send({...outbound, 'to': host});
      return true;
    }
    unawaited(
      _ptyTransport.sendPtyFrame(host, outbound).then((result) {
        if (result != PtySendResult.sentP2p &&
            identical(_ptyRoutes[sid], route)) {
          _failPtyRoute(sid, 'P2P 数据通道不可用');
        }
      }),
    );
    return true;
  }

  void _configureTerminalForSession(String sid, Terminal term) {
    var agent = '';
    for (final s in sessions) {
      if (s.sid == sid) {
        agent = s.agent.trim().toLowerCase();
        break;
      }
    }
    term.inlineScrollRegionScrollback = agent == 'codex';
  }

  // reloadTerminal drops the cached Terminal and recreates it, so the phone's
  // buffer starts empty and the host's term.open reply (backlog replay) shows
  // the computer's current screen/history instead of appending to stale
  // content. The caller rebuilds so the TerminalView rebinds to the new term.
  void reloadTerminal(String sid) {
    _resizeRefreshTimers.remove(sid)?.cancel();
    _terminals.remove(sid);
    _closeTerminalRoute(sid);
    _resizeTimers.remove(sid)?.cancel();
    terminalFor(sid); // recreate + send term.open now → host replays backlog
  }

  // --- Local history cache eviction -----------------------------------------

  // touchSession stamps a session as just-operated so its cached buffer stays
  // warm (called on open, key/text input, and on leaving its screen).
  void touchSession(String sid) => _lastActive[sid] = DateTime.now();

  // setViewedSession marks [sid]'s screen as the one on top (guarded from
  // eviction). If its cached buffer has gone idle past the TTL it's dropped and
  // re-pulled fresh from the host first. Returns true when it re-pulled, so the
  // screen can hint the user. Call leaveViewedSession when the screen closes.
  bool setViewedSession(String sid) {
    _ensureEvictTimer();
    final t = _lastActive[sid];
    final stale = t == null || DateTime.now().difference(t) > _historyTtl;
    final refreshed = stale && _terminals.containsKey(sid);
    if (refreshed) {
      reloadTerminal(
        sid,
      ); // drop stale local history → fresh replay from desktop
    }
    _viewedSid = sid;
    touchSession(sid);
    return refreshed;
  }

  // leaveViewedSession is called when a session's screen closes: stamp the leave
  // time (the idle TTL counts from here) and stop guarding it from eviction.
  void leaveViewedSession(String sid) {
    touchSession(sid);
    if (_viewedSid == sid) _viewedSid = null;
  }

  void _ensureEvictTimer() {
    _evictTimer ??= Timer.periodic(
      const Duration(minutes: 1),
      (_) => _sweepIdleHistory(),
    );
  }

  // _sweepIdleHistory drops the local buffer of any session idle past the TTL
  // (never the one being viewed). Frees memory and guarantees the next open
  // re-pulls fresh instead of showing stale accumulated history.
  void _sweepIdleHistory() {
    final now = DateTime.now();
    for (final sid in _terminals.keys.toList()) {
      if (sid == _viewedSid) continue;
      final t = _lastActive[sid];
      if (t == null || now.difference(t) > _historyTtl) _evictTerminal(sid);
    }
  }

  void _evictTerminal(String sid) {
    _terminals.remove(sid);
    _closeTerminalRoute(sid);
    _resizeTimers.remove(sid)?.cancel();
    _resizeRefreshTimers.remove(sid)?.cancel();
    _resizeRefreshAttempted.remove(sid);
    _resizeRefreshReplayUntil.remove(sid);
    _sizedSids.remove(sid); // re-opened session reports its size afresh
    _lastActive.remove(sid);
  }

  bool _sendResize(String sid, {required int rows, required int cols}) {
    final sent = _sendTermFrame(sid, {
      't': 'term.resize',
      'sid': sid,
      'rows': rows,
      'cols': cols,
    });
    if (!sent) return false;
    // Some TUIs accept SIGWINCH but don't repaint until their next real output.
    // If the host sends output after the resize, term.output cancels this. If it
    // stays quiet, re-open the watched terminal so the host replays the current
    // buffer at the viewport we just reported instead of leaving the old layout
    // visible until the agent's next answer.
    _resizeRefreshTimers.remove(sid)?.cancel();
    final attempted = _resizeRefreshAttempted[sid];
    if (attempted?.rows == rows && attempted?.cols == cols) return true;
    _resizeRefreshTimers[sid] = Timer(const Duration(milliseconds: 1200), () {
      _resizeRefreshTimers.remove(sid);
      if (_viewedSid != sid || !_terminals.containsKey(sid)) return;
      _resizeRefreshAttempted[sid] = (rows: rows, cols: cols);
      _resizeRefreshReplayUntil[sid] = DateTime.now().add(
        const Duration(seconds: 3),
      );
      reloadTerminal(sid);
      onTerminalReset?.call();
    });
    return true;
  }

  // adoptSize makes the device that's currently viewing [sid] re-assert its own
  // viewport size onto the host PTY — "whoever's watching redraws". onResize
  // only fires when the local Terminal's size CHANGES, so re-opening a cached
  // session (size unchanged) never re-reports it, and the PTY can stay stuck at
  // another device's width (e.g. web left it at 125 cols, then you open it on
  // the phone). Called when a session screen opens / rebinds, and from the
  // 适配 button. Sends the local Terminal's current cells, which the host
  // resizes the PTY to → the agent redraws at this device's width.
  // Returns a short status (what was sent / why not) for a diagnostic snack.
  String adoptSize(String sid) {
    // Use the real laid-out viewport (recorded on every onResize) for this sid,
    // else this phone's last-known screen size. Deliberately NOT the Terminal's
    // viewWidth — that's the default 80 until the view lays out, and sending it
    // would pin the PTY to a wrong width (the bug being fixed). A large font
    // makes a legit narrow viewport, so only the degenerate <2 is skipped.
    final vp = _lastViewport[sid] ?? _lastKnownViewport ?? defaultViewport;
    if (vp == null) return 'no-viewport-yet';
    final w = vp.cols, h = vp.rows;
    if (w >= 2 && h >= 2) {
      return _sendResize(sid, rows: h, cols: w)
          ? '${w}x$h'
          : 'transport-blocked';
    }
    return 'skip ${w}x$h';
  }

  @override
  void dispose() {
    _closeAllTerminalRoutes();
    _ptyDisposed = true;
    _ptyOperationEpoch++;
    _p2pConnectTimer?.cancel();
    unawaited(_ptyTransport.dispose());
    _evictTimer?.cancel();
    for (final t in _resizeRefreshTimers.values) {
      t.cancel();
    }
    _resizeRefreshAttempted.clear();
    _resizeRefreshReplayUntil.clear();
    _shareSourcesTimer?.cancel();
    _shareViewer?.removeListener(_onShareViewerChanged);
    unawaited(_shareViewer?.stop());
    _completeAllAssigns('连接已关闭');
    super.dispose();
  }

  // Session write actions (the host re-broadcasts `sessions` after each).
  // workdir targets a worktree under the project (the host validates it lives in
  // the project root or its .worktrees/); omitted/equal to project = main checkout.
  void newSession(String projectPath, String agent, {String? workdir}) => send({
    't': 'session.new',
    'project': projectPath,
    'agent': agent.trim().isEmpty ? 'shell' : agent,
    if (workdir != null && workdir != projectPath) 'workdir': workdir,
  });
  void closeSession(String sid) => send({'t': 'session.close', 'sid': sid});
  void renameSession(String sid, String name) =>
      send({'t': 'session.rename', 'sid': sid, 'name': name});

  // requestAssign asks the paired desktop host to assign [todoId] to one of its
  // local sessions — mode 'existing' (dispatch to [sid]) or 'new' (spawn in
  // [workspace]/[project] with agent [kind], optional new-worktree [branch]).
  // The host does the materialize/dispatch/spawn/bind locally (the phone has no
  // local session or filesystem) and replies todo.assign.ok/err, completing the
  // returned future: null on success, an error string otherwise. Times out if
  // the host never answers (old desktop version / dropped link).
  final Map<String, Completer<String?>> _assignWaiters = {};
  final Map<String, Timer> _assignTimeouts = {};

  void _completeAssign(String? todoId, String? result) {
    if (todoId == null) return;
    _assignTimeouts.remove(todoId)?.cancel();
    final waiter = _assignWaiters.remove(todoId);
    if (waiter != null && !waiter.isCompleted) waiter.complete(result);
  }

  void _completeAllAssigns(String result) {
    for (final timer in _assignTimeouts.values) {
      timer.cancel();
    }
    _assignTimeouts.clear();
    final waiters = _assignWaiters.values.toList();
    _assignWaiters.clear();
    for (final waiter in waiters) {
      if (!waiter.isCompleted) waiter.complete(result);
    }
  }

  Future<String?> requestAssign({
    required String todoId,
    required String mode, // 'existing' | 'new'
    String? sid,
    String? workspace,
    String? project,
    String? projectId,
    String? kind,
    String? branch,
  }) {
    final cleanTodoId = todoId.trim();
    final cleanMode = mode.trim();
    final cleanSid = _trimOrNull(sid);
    final cleanWorkspace = _trimOrNull(workspace);
    final cleanProject = _trimOrNull(project);
    final cleanProjectId = _trimOrNull(projectId);
    final cleanKind = _trimOrNull(kind);
    final cleanBranch = _trimOrNull(branch);
    if (!_hostOnline) {
      return Future.value('电脑端未在线，请先在电脑端开启「共享工作区」');
    }
    // Supersede any in-flight request for the same todo.
    _assignTimeouts.remove(cleanTodoId)?.cancel();
    _assignWaiters.remove(cleanTodoId)?.complete('已被新的指派请求取代');
    final c = Completer<String?>();
    _assignWaiters[cleanTodoId] = c;
    send({
      't': 'todo.assign',
      'todoId': cleanTodoId,
      'mode': cleanMode,
      'sid': ?cleanSid,
      'workspace': ?cleanWorkspace,
      'project': ?cleanProject,
      'projectId': ?cleanProjectId,
      'kind': ?cleanKind,
      'branch': ?cleanBranch,
    });
    _assignTimeouts[cleanTodoId] = Timer(const Duration(seconds: 30), () {
      _completeAssign(cleanTodoId, '桌面无响应(请确认桌面 App 在线)');
    });
    return c.future;
  }

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

  void requestCommitDiff(
    String repo,
    String hash,
    String title, {
    bool full = false,
  }) {
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
  void gitCreateBranch(String repo, String branch, {String? start}) => send({
    't': 'git.createBranch',
    'path': repo,
    'branch': branch,
    if (_trimOrNull(start) != null) 'start': _trimOrNull(start),
  });
  void gitStash(String repo, String message) =>
      send({'t': 'git.stash', 'path': repo, 'message': message});
  void gitStashPop(String repo, String ref) =>
      send({'t': 'git.stashPop', 'path': repo, 'ref': ref});

  // Project management — host replies cfg.ok (→ rebroadcast roots) or cfg.err.
  void loadWorktrees(String projectPath) =>
      send({'t': 'wt.list', 'path': projectPath});
  void newWorkspace(String name, String path) {
    final trimmedPath = _trimOrNull(path);
    send({'t': 'ws.new', 'name': name.trim(), 'path': ?trimmedPath});
  }

  void removeWorkspace(String name) =>
      send({'t': 'ws.remove', 'name': name.trim()});
  void addProject(String workspace, String source) => send({
    't': 'proj.add',
    'workspace': workspace.trim(),
    'source': source.trim(),
  });
  void removeProject(String workspace, String project) => send({
    't': 'proj.remove',
    'workspace': workspace.trim(),
    'project': project.trim(),
  });

  void addWorktree(
    String workspace,
    String project,
    String branch,
    String start,
  ) => send({
    't': 'wt.add',
    'workspace': workspace.trim(),
    'project': project.trim(),
    'branch': branch.trim(),
    if (_trimOrNull(start) != null) 'start': _trimOrNull(start),
  });
  void removeWorktree(String workspace, String project, String branch) => send({
    't': 'wt.remove',
    'workspace': workspace.trim(),
    'project': project.trim(),
    'branch': branch.trim(),
    'force': true,
  });
}

String? _trimOrNull(String? value) {
  final trimmed = value?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;
  return trimmed;
}
