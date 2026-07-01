import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../path_utils.dart';

// Phase-2 go-to-definition backend: a minimal JSON-RPC-over-stdio LSP client.
// This round only speaks to gopls (Go); the design generalises to other servers
// later. Everything is best-effort — any failure (server missing, timeout, bad
// response) surfaces as an empty result so the caller falls back to the regex
// symbol index. Process lifecycle is owned here so we never leak a language
// server (shutdown + exit + kill on dispose).

// LspLocation is a resolved definition site: [path] on disk + [line] (1-based,
// ready for _openCodeFile).
class LspLocation {
  final String path;
  final int line;
  const LspLocation(this.path, this.line);
}

// LspManager is the app-wide singleton: it probes gopls once, keeps one server
// per workspace root, and answers definition queries. Non-Go languages aren't
// wired yet — callers only route .go files here.
class LspManager {
  LspManager._();
  static final LspManager instance = LspManager._();

  // Resolved gopls path: null = not probed yet, '' = probed and absent.
  String? _goplsPath;
  final Map<String, _LspServer> _servers = {};

  // _resolveGopls finds gopls on the user's PATH via the login shell (a
  // double-clicked .app has a minimal PATH — same trick as PluginManager).
  Future<String?> _resolveGopls() async {
    final cached = _goplsPath;
    if (cached != null) return cached.isEmpty ? null : cached;
    var path = '';
    try {
      final res = Platform.isWindows
          ? await Process.run('where', ['gopls'])
          : await Process.run(
              Platform.environment['SHELL'] ?? '/bin/sh',
              ['-lc', 'command -v gopls'],
            );
      if (res.exitCode == 0) {
        path = (res.stdout as String).trim().split('\n').first.trim();
      }
    } catch (_) {}
    _goplsPath = path;
    return path.isEmpty ? null : path;
  }

  // goDefinition returns the definition site(s) for the identifier at
  // (line, character) — both 0-based, LSP coordinates — in [filePath], whose
  // current buffer is [text]. [root] is the workspace/module root. Returns an
  // empty list (never throws) when gopls is unavailable or can't resolve it, so
  // the caller falls back to the regex index.
  Future<List<LspLocation>> goDefinition({
    required String root,
    required String filePath,
    required String text,
    required int line,
    required int character,
  }) async {
    try {
      final gopls = await _resolveGopls();
      if (gopls == null) return const [];
      final server = _servers[root] ??= _LspServer(gopls, root);
      return await server
          .definition(filePath, text, line, character)
          .timeout(const Duration(seconds: 4), onTimeout: () => const []);
    } catch (_) {
      return const [];
    }
  }

  // shutdownAll tears down every running server — call from WorkspacePage.dispose
  // so we don't leave gopls processes behind.
  Future<void> shutdownAll() async {
    final servers = _servers.values.toList();
    _servers.clear();
    for (final s in servers) {
      await s.dispose();
    }
  }
}

// _LspServer drives one language-server process for one root: framing,
// initialize handshake, document sync, request/response correlation, teardown.
class _LspServer {
  final String _exe;
  final String _root;

  Process? _proc;
  Completer<bool>? _ready; // completes true once initialized, false on failure
  bool _dead = false;

  int _nextId = 1;
  final Map<int, Completer<dynamic>> _pending = {};
  final Map<String, int> _opened = {}; // uri -> last version sent
  List<int> _buf = const [];

  _LspServer(this._exe, this._root);

  Future<List<LspLocation>> definition(
    String path,
    String text,
    int line,
    int character,
  ) async {
    final ok = await _ensureStarted();
    if (!ok || _dead) return const [];
    final uri = Uri.file(path).toString();
    final version = (_opened[uri] ?? 0) + 1;
    if (!_opened.containsKey(uri)) {
      _notify('textDocument/didOpen', {
        'textDocument': {
          'uri': uri,
          'languageId': 'go',
          'version': version,
          'text': text,
        },
      });
    } else {
      _notify('textDocument/didChange', {
        'textDocument': {'uri': uri, 'version': version},
        'contentChanges': [
          {'text': text},
        ],
      });
    }
    _opened[uri] = version;
    final result = await _request('textDocument/definition', {
      'textDocument': {'uri': uri},
      'position': {'line': line, 'character': character},
    });
    return _parseLocations(result);
  }

  Future<bool> _ensureStarted() {
    final done = _ready;
    if (done != null) return done.future;
    final c = _ready = Completer<bool>();
    _start(c);
    return c.future;
  }

  Future<void> _start(Completer<bool> ready) async {
    try {
      final proc = await Process.start(
        _exe,
        const [],
        workingDirectory: _root,
      );
      _proc = proc;
      proc.stdout.listen(_onData, onError: (_) {}, cancelOnError: false);
      proc.stderr.listen((_) {}, onError: (_) {}); // drain, ignore
      unawaited(proc.exitCode.then((_) => _onExit()));

      final rootUri = Uri.directory(_root).toString();
      await _request('initialize', {
        'processId': pid,
        'rootUri': rootUri,
        'capabilities': {
          'textDocument': {
            'synchronization': {'dynamicRegistration': false},
            'definition': {'linkSupport': true},
          },
          'workspace': {'configuration': true, 'workspaceFolders': true},
        },
        'workspaceFolders': [
          {'uri': rootUri, 'name': pathBaseName(_root)},
        ],
      }).timeout(const Duration(seconds: 8));
      _notify('initialized', const {});
      if (!ready.isCompleted) ready.complete(true);
    } catch (_) {
      _dead = true;
      if (!ready.isCompleted) ready.complete(false);
    }
  }

  List<LspLocation> _parseLocations(dynamic result) {
    if (result == null) return const [];
    final list = result is List ? result : [result];
    final out = <LspLocation>[];
    for (final item in list) {
      if (item is! Map) continue;
      // Location has {uri, range}; LocationLink has {targetUri, targetRange,
      // targetSelectionRange} — accept both.
      final uri = (item['uri'] ?? item['targetUri'])?.toString();
      final range =
          item['range'] ?? item['targetSelectionRange'] ?? item['targetRange'];
      if (uri == null || range is! Map) continue;
      final start = range['start'];
      if (start is! Map) continue;
      final line0 = (start['line'] as num?)?.toInt();
      if (line0 == null) continue;
      final path = _pathFromUri(uri);
      if (path == null) continue;
      out.add(LspLocation(path, line0 + 1));
    }
    return out;
  }

  String? _pathFromUri(String uri) {
    try {
      return Uri.parse(uri).toFilePath();
    } catch (_) {
      return null;
    }
  }

  // ---- JSON-RPC plumbing ----

  Future<dynamic> _request(String method, Object? params) {
    final id = _nextId++;
    final c = Completer<dynamic>();
    _pending[id] = c;
    _send({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params});
    return c.future;
  }

  void _notify(String method, Object? params) {
    _send({'jsonrpc': '2.0', 'method': method, 'params': params});
  }

  void _send(Map<String, dynamic> msg) {
    final proc = _proc;
    if (proc == null || _dead) return;
    try {
      final body = utf8.encode(jsonEncode(msg));
      proc.stdin.add(utf8.encode('Content-Length: ${body.length}\r\n\r\n'));
      proc.stdin.add(body);
    } catch (_) {}
  }

  void _onData(List<int> data) {
    // Accumulate and drain every complete `Content-Length`-framed message.
    _buf = _buf.isEmpty ? List<int>.from(data) : (_buf..addAll(data));
    while (true) {
      final headerEnd = _headerEnd(_buf);
      if (headerEnd < 0) return;
      final len = _contentLength(utf8.decode(_buf.sublist(0, headerEnd)));
      final bodyStart = headerEnd + 4;
      if (len == null) {
        _buf = _buf.sublist(bodyStart); // malformed header; skip it
        continue;
      }
      if (_buf.length < bodyStart + len) return; // wait for the rest
      final body = _buf.sublist(bodyStart, bodyStart + len);
      _buf = _buf.sublist(bodyStart + len);
      _dispatch(body);
    }
  }

  static int _headerEnd(List<int> b) {
    for (var i = 0; i + 3 < b.length; i++) {
      if (b[i] == 13 && b[i + 1] == 10 && b[i + 2] == 13 && b[i + 3] == 10) {
        return i;
      }
    }
    return -1;
  }

  static int? _contentLength(String header) {
    for (final line in header.split('\r\n')) {
      final idx = line.indexOf(':');
      if (idx < 0) continue;
      if (line.substring(0, idx).trim().toLowerCase() == 'content-length') {
        return int.tryParse(line.substring(idx + 1).trim());
      }
    }
    return null;
  }

  void _dispatch(List<int> body) {
    dynamic msg;
    try {
      msg = jsonDecode(utf8.decode(body));
    } catch (_) {
      return;
    }
    if (msg is! Map) return;
    final id = msg['id'];
    final method = msg['method'];
    if (method is String) {
      // A server→client request (has id) must be answered or gopls may stall;
      // notifications (no id) are ignored.
      if (id != null) _replyToServerRequest(id, method, msg['params']);
      return;
    }
    // Otherwise it's a response to one of our requests.
    if (id is int) {
      final c = _pending.remove(id);
      if (c != null && !c.isCompleted) {
        c.complete(msg.containsKey('error') ? null : msg['result']);
      }
    }
  }

  void _replyToServerRequest(dynamic id, String method, dynamic params) {
    dynamic result;
    if (method == 'workspace/configuration') {
      final items = (params is Map && params['items'] is List)
          ? params['items'] as List
          : const [];
      result = List.filled(items.length, null); // no per-scope config
    } else {
      result = null; // registerCapability / workDoneProgress-create / etc.
    }
    _send({'jsonrpc': '2.0', 'id': id, 'result': result});
  }

  void _onExit() {
    _dead = true;
    for (final c in _pending.values) {
      if (!c.isCompleted) c.complete(null);
    }
    _pending.clear();
    final ready = _ready;
    if (ready != null && !ready.isCompleted) ready.complete(false);
  }

  Future<void> dispose() async {
    final proc = _proc;
    if (proc == null) {
      _dead = true;
      return;
    }
    try {
      // Graceful LSP teardown, then force-kill as a backstop.
      _send({'jsonrpc': '2.0', 'id': _nextId++, 'method': 'shutdown'});
      _notify('exit', null);
      await proc.stdin.flush().catchError((_) {});
      await proc.stdin.close().catchError((_) {});
    } catch (_) {}
    _dead = true;
    proc.kill();
  }
}
