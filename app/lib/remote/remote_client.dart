import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:xterm/xterm.dart';

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

// RemoteClient is the phone side of the remote workspace: it connects to the
// relay's /v1/ws as a "client", discovers the desktop host's terminal sessions
// and project roots, drives terminals (xterm fed by network bytes, keystrokes
// sent back), and browses/reads files. State is exposed via ChangeNotifier so
// the page can rebuild. Read-only files for now (editing is a later phase).
class RemoteClient extends ChangeNotifier {
  final String relayUrl;
  final String token;
  RemoteClient({required this.relayUrl, required this.token});

  WebSocket? _ws;
  int? _myConnId;
  bool _connected = false;
  bool _hostOnline = false;
  String? _error;

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

  bool get connected => _connected;
  bool get hostOnline => _hostOnline;
  String? get error => _error;

  Future<void> connect() async {
    _error = null;
    unawaited(_loop());
  }

  bool _closed = false;

  @override
  void dispose() {
    _closed = true;
    _ws?.close();
    super.dispose();
  }

  static Uri _wsUri(String relayUrl) {
    var u = relayUrl.trim().replaceAll(RegExp(r'/+$'), '');
    if (u.startsWith('https://')) {
      u = 'wss://${u.substring(8)}';
    } else if (u.startsWith('http://')) {
      u = 'ws://${u.substring(7)}';
    } else if (!u.startsWith('ws://') && !u.startsWith('wss://')) {
      u = 'ws://$u';
    }
    return Uri.parse('$u/v1/ws?role=client');
  }

  Future<void> _loop() async {
    while (!_closed) {
      try {
        final ws = await WebSocket.connect(
          _wsUri(relayUrl).toString(),
          headers: {'Authorization': 'Bearer $token'},
        );
        _ws = ws;
        _connected = true;
        _error = null;
        notifyListeners();
        await for (final msg in ws) {
          if (msg is String) _onFrame(msg);
        }
      } catch (e) {
        _error = '$e';
      }
      _ws = null;
      _connected = false;
      _hostOnline = false;
      notifyListeners();
      if (_closed) break;
      await Future<void>.delayed(const Duration(seconds: 3));
    }
  }

  void _send(Map<String, dynamic> frame) {
    final ws = _ws;
    if (ws == null) return;
    frame['from'] = _myConnId ?? 0;
    try {
      ws.add(jsonEncode(frame));
    } catch (_) {}
  }

  void _onFrame(String raw) {
    Map<String, dynamic> f;
    try {
      f = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    switch (f['t'] as String?) {
      case '_hello':
        _myConnId = (f['connId'] as num?)?.toInt();
        _send({'t': 'list'}); // discover host sessions/roots on connect
        break;
      case '_peer':
        if (f['role'] == 'host') {
          _hostOnline = f['event'] == 'connect';
          if (_hostOnline) _send({'t': 'list'});
          notifyListeners();
        }
        break;
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
        break;
      case 'roots':
        roots = [
          for (final r in (f['items'] as List? ?? []))
            RemoteRootInfo(r['name'] as String, r['path'] as String),
        ];
        notifyListeners();
        break;
      case 'term.output':
        final sid = f['sid'] as String?;
        final d = f['d'] as String?;
        if (sid != null && d != null) _terminals[sid]?.write(d);
        break;
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
        break;
      case 'fs.read.ok':
        filePath = f['path'] as String?;
        fileContent = f['content'] as String?;
        fileLoading = false;
        fileError = null;
        notifyListeners();
        break;
      case 'fs.err':
        // Resolve whichever request is outstanding.
        if (fileLoading) {
          fileLoading = false;
          fileError = (f['msg'] as String?) ?? '失败';
        }
        if (fsLoading) {
          fsLoading = false;
          fsError = (f['msg'] as String?) ?? '失败';
        }
        notifyListeners();
        break;
    }
  }

  void refresh() => _send({'t': 'list'});

  // sendKeys injects raw bytes into a session (for an on-screen key bar — phone
  // soft keyboards lack Esc / Ctrl / arrows that agent TUIs need).
  void sendKeys(String sid, String data) =>
      _send({'t': 'term.input', 'sid': sid, 'd': data});

  // terminalFor returns (creating on first use) the xterm Terminal for a session,
  // wired so host output is written in and local keystrokes/resizes go back.
  Terminal terminalFor(String sid) {
    final existing = _terminals[sid];
    if (existing != null) return existing;
    final term = Terminal(maxLines: 5000);
    _terminals[sid] = term;
    term.onOutput = (d) => _send({'t': 'term.input', 'sid': sid, 'd': d});
    term.onResize = (w, h, pw, ph) =>
        _send({'t': 'term.resize', 'sid': sid, 'rows': h, 'cols': w});
    _send({'t': 'term.open', 'sid': sid});
    return term;
  }

  void openDir(String path) {
    fsLoading = true;
    fsError = null;
    notifyListeners();
    _send({'t': 'fs.list', 'path': path});
  }

  void openFile(String path) {
    fileLoading = true;
    fileError = null;
    filePath = path;
    fileContent = null;
    notifyListeners();
    _send({'t': 'fs.read', 'path': path});
  }
}
