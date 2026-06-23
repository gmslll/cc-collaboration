import 'dart:convert';
import 'dart:io';

import '../screens/terminal_pane.dart';
import '../widgets.dart' show kIgnoredEntries;
import 'remote_channel.dart';

// A project root the host exposes to remote clients.
class RemoteRoot {
  final String name;
  final String path;
  const RemoteRoot(this.name, this.path);
}

// RemoteHost shares this desktop's workspace (terminal sessions + project files)
// to the user's phone, brokered by the relay (see RemoteChannel for transport).
// Opt-in: nothing is exposed until [enable]. The relay only pipes between the
// SAME identity, so only the user's own devices can connect. File access is
// hard-scoped to the advertised project roots (traversal is normalized away).
class RemoteHost extends RemoteChannel {
  final List<TerminalSession> Function() sessions;
  final List<RemoteRoot> Function() roots;

  RemoteHost({
    required super.relayUrl,
    required super.token,
    required this.sessions,
    required this.roots,
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
      case 'fs.list':
        _fsList(f);
      case 'fs.read':
        _fsRead(f);
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
    send({'t': 'sessions', 'to': to, 'items': sess});
    send({'t': 'roots', 'to': to, 'items': rs});
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
        send({'t': 'term.output', 'to': c, 'sid': s.id, 'd': chunk});
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
}
