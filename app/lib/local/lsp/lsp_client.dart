import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../path_utils.dart';
import '../prefs.dart';
import '../shell.dart';
import 'lsp_plugin.dart';

// Phase-2 go-to-definition backend: a minimal JSON-RPC-over-stdio LSP client.
// Speaks to the per-language servers configured in the LSP plugin catalog
// (lsp_plugin.dart); which command each language uses is user-configurable and
// probed on the login PATH. Everything is best-effort — any failure (server
// missing/disabled, timeout, bad response) surfaces as an empty result so the
// caller falls back to the regex symbol index. Process lifecycle is owned here
// so we never leak a language server (shutdown + exit + kill on dispose).

// LspLocation is a resolved definition site: [path] on disk + [line] (1-based,
// ready for _openCodeFile).
class LspLocation {
  final String path;
  final int line;
  const LspLocation(this.path, this.line);
}

String _extOf(String path) {
  final base = pathBaseName(path);
  final dot = base.lastIndexOf('.');
  return dot < 0 ? '' : base.substring(dot + 1).toLowerCase();
}

// LspManager is the app-wide singleton: it probes each language server on demand,
// keeps one server process per (root, language), and answers definition queries.
class LspManager extends ChangeNotifier {
  LspManager._();
  static final LspManager instance = LspManager._();

  // Resolved absolute path per command ('' = probed and absent; missing = not
  // probed yet).
  final Map<String, String> _cmdPaths = {};
  // The login-shell PATH, injected into each server's environment so it can find
  // its toolchain (gopls→go, dart→the SDK). A double-clicked .app has a minimal
  // PATH that lacks them (same class of problem PluginManager works around).
  String _pathEnv = '';
  // One server per (root, command).
  final Map<(String, String), _LspServer> _servers = {};

  // _pluginForExt returns the catalog entry that handles [ext], or null.
  static LspServerPlugin? _pluginForExt(String ext) {
    for (final p in kLspServers) {
      if (p.exts.contains(ext)) return p;
    }
    return null;
  }

  // supportsExtension is true when [ext] has an ENABLED language server, so the
  // caller routes it here instead of straight to the regex index; a disabled
  // language returns false → regex fallback.
  static bool supportsExtension(String ext) {
    final p = _pluginForExt(ext);
    return p != null && Prefs.getBool('lsp.${p.id}.enabled', def: true);
  }

  // ---- config (Prefs-backed) + detection, for the settings panel ----

  final Map<String, bool> _available = {}; // id -> command found on PATH

  bool enabled(String id) => Prefs.getBool('lsp.$id.enabled', def: true);
  void setEnabled(String id, bool value) {
    Prefs.setBool('lsp.$id.enabled', value);
    notifyListeners();
  }

  // commandFor is the user's override (lsp.<id>.cmd) or the catalog default.
  String commandFor(LspServerPlugin p) {
    final override = Prefs.getString('lsp.${p.id}.cmd', def: '').trim();
    return override.isEmpty ? p.command : override;
  }

  // setCommand records a custom command/path for [id], dropping the stale probe
  // + any running server for it so the next jump uses the new command.
  void setCommand(String id, String command) {
    Prefs.setString('lsp.$id.cmd', command.trim());
    _cmdPaths.clear();
    _available.remove(id);
    final gone = <(String, String)>[];
    _servers.forEach((k, s) {
      if (k.$2 == id) {
        s.dispose();
        gone.add(k);
      }
    });
    for (final k in gone) {
      _servers.remove(k);
    }
    notifyListeners();
  }

  // detected(id) is true when the configured command was found on PATH by the
  // last detectAll().
  bool detected(String id) => _available[id] ?? false;

  // detectAll probes each server's configured command on the login PATH — the
  // settings panel calls it on open / refresh.
  Future<void> detectAll({bool force = false}) async {
    if (force) _cmdPaths.clear();
    for (final p in kLspServers) {
      final exe = await _resolveCmd(commandFor(p));
      _available[p.id] = exe != null;
    }
    notifyListeners();
  }

  // _resolveCmd finds [command] on the login-shell PATH AND captures that PATH
  // (so a spawned server can find its toolchain). Cached per command. Sentinels
  // keep parsing robust against any banner a login profile prints.
  Future<String?> _resolveCmd(String command) async {
    final cached = _cmdPaths[command];
    if (cached != null) return cached.isEmpty ? null : cached;
    var exe = '';
    var path = '';
    try {
      if (Platform.isWindows) {
        final res = await Process.run('where', [command]);
        if (res.exitCode == 0) {
          exe = (res.stdout as String).trim().split('\n').first.trim();
        }
        path = Platform.environment['PATH'] ?? '';
      } else {
        final res = await Process.run(
          Platform.environment['SHELL'] ?? '/bin/sh',
          [
            '-lc',
            'printf "__CMD__%s\\n__PATH__%s\\n" "\$(command -v ${shQuote(command)} || true)" "\$PATH"',
          ],
        );
        for (final line in (res.stdout as String).split('\n')) {
          if (line.startsWith('__CMD__')) {
            exe = line.substring('__CMD__'.length).trim();
          } else if (line.startsWith('__PATH__')) {
            path = line.substring('__PATH__'.length).trim();
          }
        }
      }
    } catch (_) {}
    _cmdPaths[command] = exe;
    if (path.isNotEmpty) _pathEnv = path;
    return exe.isEmpty ? null : exe;
  }

  // goDefinition returns the definition site(s) for the identifier at
  // (line, character) — both 0-based, LSP coordinates — in [filePath], whose
  // current buffer is [text]. [root] is the workspace/module root. Returns an
  // empty list (never throws) when the server is unavailable or can't resolve
  // it, so the caller falls back to the regex index.
  Future<List<LspLocation>> goDefinition({
    required String root,
    required String filePath,
    required String text,
    required int line,
    required int character,
  }) async {
    try {
      final p = _pluginForExt(_extOf(filePath));
      if (p == null || !enabled(p.id)) return const [];
      final exe = await _resolveCmd(commandFor(p));
      if (exe == null) return const [];
      final server = _servers[(root, p.id)] ??=
          _LspServer(exe, p.argsFor(root), p.languageId, root, _pathEnv);
      return await server
          .definition(filePath, text, line, character)
          .timeout(const Duration(seconds: 5), onTimeout: () => const []);
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
// Set LSP_DEBUG=1 in the environment to trace JSON-RPC traffic on stderr.
final bool _lspDebug = Platform.environment['LSP_DEBUG'] == '1';
void _log(String s) {
  if (_lspDebug) stderr.writeln('[lsp] $s');
}

class _LspServer {
  final String _exe;
  final List<String> _args;
  final String _languageId;
  final String _root;
  final String _pathEnv; // PATH handed to the server so it can find its toolchain

  Process? _proc;
  Completer<bool>? _ready; // completes true once initialized, false on failure
  bool _dead = false;

  int _nextId = 1;
  final Map<int, Completer<dynamic>> _pending = {};
  final Map<String, int> _opened = {}; // uri -> last version sent
  List<int> _buf = const [];

  _LspServer(this._exe, this._args, this._languageId, this._root, this._pathEnv);

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
          'languageId': _languageId,
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
        _args,
        workingDirectory: _root,
        // Override PATH (parent env is still included) so the server can shell out
        // to its toolchain (gopls→go); a bare app process's PATH usually lacks it.
        environment: _pathEnv.isEmpty ? null : {'PATH': _pathEnv},
      );
      _proc = proc;
      _log('started $_exe (pid ${proc.pid}) root=$_root');
      proc.stdout.listen(_onData, onError: (_) {}, cancelOnError: false);
      proc.stderr.listen(
        (d) => _log('stderr: ${utf8.decode(d, allowMalformed: true).trim()}'),
        onError: (_) {},
      );
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
      final json = jsonEncode(msg);
      _log('>> $json');
      final body = utf8.encode(json);
      proc.stdin.add(utf8.encode('Content-Length: ${body.length}\r\n\r\n'));
      proc.stdin.add(body);
    } catch (e) {
      _log('send failed: $e');
    }
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
      final text = utf8.decode(body);
      _log('<< $text');
      msg = jsonDecode(text);
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
