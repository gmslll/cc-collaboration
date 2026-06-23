import 'package:xterm/xterm.dart';

import 'remote_channel.dart';

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
  RemoteRootInfo(this.name, this.path);
}

class RemoteEntry {
  final String name;
  final bool dir;
  final int size;
  RemoteEntry(this.name, this.dir, this.size);
}

// RemoteClient is the phone side of the remote workspace: over the relay (see
// RemoteChannel for transport) it discovers the desktop host's terminal sessions
// and project roots, drives terminals (xterm fed by network bytes, keystrokes
// sent back), and browses/reads files. Read-only files for now (editing later).
class RemoteClient extends RemoteChannel {
  RemoteClient({required super.relayUrl, required super.token})
    : super(role: 'client');

  bool _hostOnline = false;

  List<RemoteSession> sessions = [];
  List<RemoteRootInfo> roots = [];

  // File browser (single current directory, mobile-friendly).
  String? fsPath;
  List<RemoteEntry> fsEntries = [];
  bool fsLoading = false;
  String? fsError;

  // File viewer.
  String? filePath;
  String? fileContent;
  bool fileLoading = false;
  String? fileError;

  final Map<String, Terminal> _terminals = {};

  bool get hostOnline => _hostOnline;
  String? get error => lastError;

  void connect() => start();

  @override
  void onConnected() => send({'t': 'list'}); // discover host on connect

  @override
  void onDisconnected() => _hostOnline = false;

  @override
  void onPeer(int connId, String role, bool connected) {
    if (role != 'host') return;
    _hostOnline = connected;
    if (connected) send({'t': 'list'});
    notifyListeners();
  }

  @override
  void onFrame(Map<String, dynamic> f) {
    switch (f['t']) {
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
        _hostOnline = true;
        notifyListeners();
      case 'roots':
        roots = [
          for (final r in (f['items'] as List? ?? []))
            RemoteRootInfo(r['name'] as String, r['path'] as String),
        ];
        notifyListeners();
      case 'term.output':
        final sid = f['sid'] as String?;
        final d = f['d'] as String?;
        if (sid != null && d != null) _terminals[sid]?.write(d);
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
    term.onOutput = (d) => send({'t': 'term.input', 'sid': sid, 'd': d});
    term.onResize = (w, h, pw, ph) =>
        send({'t': 'term.resize', 'sid': sid, 'rows': h, 'cols': w});
    send({'t': 'term.open', 'sid': sid});
    return term;
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
}
