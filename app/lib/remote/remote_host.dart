import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../screens/terminal_pane.dart';

// A project root the host exposes to remote clients.
class RemoteRoot {
  final String name;
  final String path;
  const RemoteRoot(this.name, this.path);
}

// RemoteHost shares this desktop's workspace (terminal sessions + project files)
// to the user's phone, brokered by the relay's /v1/ws. Opt-in: nothing is
// exposed until [enable]. The relay only pipes between the SAME identity, so
// only the user's own devices can ever connect. File access is hard-scoped to
// the advertised project roots (path traversal is normalized away and rejected).
class RemoteHost extends ChangeNotifier {
  final String relayUrl;
  final String token;
  final List<TerminalSession> Function() sessions;
  final List<RemoteRoot> Function() roots;

  RemoteHost({
    required this.relayUrl,
    required this.token,
    required this.sessions,
    required this.roots,
  });

  WebSocket? _ws;
  bool _sharing = false;
  bool _connected = false;
  final Set<int> _clients = {}; // connected phone connIds
  final Map<String, Set<int>> _watchers = {}; // session id -> watching clients
  static const int _maxRead = 2 * 1024 * 1024; // 2MB file-read cap
  static const _ignore = {
    '.git',
    'node_modules',
    'build',
    '.dart_tool',
    '.idea',
    '.gradle',
    'Pods',
    '.DS_Store',
    '.next',
    'dist',
    'target',
    '.venv',
    '__pycache__',
  };

  bool get sharing => _sharing;
  bool get connected => _connected;
  int get clientCount => _clients.length;

  Future<void> enable() async {
    if (_sharing) return;
    _sharing = true;
    notifyListeners();
    unawaited(_connectLoop());
  }

  void disable() {
    _sharing = false;
    _clients.clear();
    _detachAllSessions();
    _ws?.close();
    _ws = null;
    _connected = false;
    notifyListeners();
  }

  @override
  void dispose() {
    disable();
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
    return Uri.parse('$u/v1/ws?role=host');
  }

  Future<void> _connectLoop() async {
    while (_sharing) {
      try {
        final ws = await WebSocket.connect(
          _wsUri(relayUrl).toString(),
          headers: {'Authorization': 'Bearer $token'},
        );
        _ws = ws;
        _connected = true;
        notifyListeners();
        await for (final msg in ws) {
          if (msg is String) _onFrame(msg);
        }
      } catch (_) {
        // fall through to reconnect
      }
      _ws = null;
      _connected = false;
      _clients.clear();
      _detachAllSessions();
      notifyListeners();
      if (!_sharing) break;
      await Future<void>.delayed(const Duration(seconds: 3));
    }
  }

  void _send(Map<String, dynamic> frame) {
    final ws = _ws;
    if (ws == null) return;
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
    final t = f['t'] as String?;
    switch (t) {
      case '_peer':
        final connId = (f['connId'] as num?)?.toInt();
        final role = f['role'] as String?;
        if (connId == null || role != 'client') break;
        if (f['event'] == 'connect') {
          _clients.add(connId);
        } else {
          _clients.remove(connId);
          _dropClient(connId);
        }
        notifyListeners();
        break;
      case 'list':
        final from = (f['from'] as num?)?.toInt();
        if (from != null) _replyList(from);
        break;
      case 'term.open':
        _termOpen(f);
        break;
      case 'term.input':
        _sessionById(f['sid'] as String?)?.sendText((f['d'] as String?) ?? '');
        break;
      case 'term.resize':
        _sessionById(f['sid'] as String?)?.resizeFromRemote(
          (f['rows'] as num?)?.toInt() ?? 0,
          (f['cols'] as num?)?.toInt() ?? 0,
        );
        break;
      case 'fs.list':
        _fsList(f);
        break;
      case 'fs.read':
        _fsRead(f);
        break;
    }
  }

  void _replyList(int to) {
    final sess = sessions()
        .map(
          (s) => {
            'sid': s.id,
            'title': s.label,
            'workdir': s.workdir,
            'agent': s.command.contains('codex') ? 'codex' : 'claude',
          },
        )
        .toList();
    final rs = roots().map((r) => {'name': r.name, 'path': r.path}).toList();
    _send({'t': 'sessions', 'to': to, 'items': sess});
    _send({'t': 'roots', 'to': to, 'items': rs});
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
    (_watchers[s.id] ??= {}).add(from);
    s.remoteSink = (chunk) {
      for (final c in _watchers[s.id] ?? const <int>{}) {
        _send({'t': 'term.output', 'to': c, 'sid': s.id, 'd': chunk});
      }
    };
  }

  void _dropClient(int connId) {
    for (final entry in _watchers.entries.toList()) {
      entry.value.remove(connId);
      if (entry.value.isEmpty) {
        _sessionById(entry.key)?.remoteSink = null;
        _watchers.remove(entry.key);
      }
    }
  }

  void _detachAllSessions() {
    for (final s in sessions()) {
      s.remoteSink = null;
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
      _send({'t': 'fs.err', 'to': to, 'path': f['path'], 'msg': 'forbidden'});
      return;
    }
    final entries = <Map<String, dynamic>>[];
    try {
      await for (final e in Directory(path).list(followLinks: false)) {
        final name = e.path.split('/').last;
        if (_ignore.contains(name)) continue;
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
      _send({'t': 'fs.err', 'to': to, 'path': path, 'msg': '$e'});
      return;
    }
    entries.sort((a, b) {
      final ad = a['dir'] as bool, bd = b['dir'] as bool;
      if (ad != bd) return ad ? -1 : 1;
      return (a['name'] as String).toLowerCase().compareTo(
        (b['name'] as String).toLowerCase(),
      );
    });
    _send({'t': 'fs.list.ok', 'to': to, 'path': path, 'entries': entries});
  }

  Future<void> _fsRead(Map<String, dynamic> f) async {
    final to = (f['from'] as num?)?.toInt();
    final path = _safePath(f['path'] as String?);
    if (to == null) return;
    if (path == null) {
      _send({'t': 'fs.err', 'to': to, 'path': f['path'], 'msg': 'forbidden'});
      return;
    }
    try {
      final file = File(path);
      final len = await file.length();
      if (len > _maxRead) {
        _send({'t': 'fs.err', 'to': to, 'path': path, 'msg': '文件过大'});
        return;
      }
      final bytes = await file.readAsBytes();
      final content = const Utf8Decoder(allowMalformed: true).convert(bytes);
      _send({'t': 'fs.read.ok', 'to': to, 'path': path, 'content': content});
    } catch (e) {
      _send({'t': 'fs.err', 'to': to, 'path': path, 'msg': '$e'});
    }
  }
}
