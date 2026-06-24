import 'dart:async';
import 'dart:convert';
import 'dart:io';

// localBusDir is the per-user directory the local session bus lives in. Sessions
// the desktop app spawns get CC_BUS_DIR pointing here; the bundled `cc-handoff
// msg` CLI reads sessions.json and drops outgoing messages into outbox/ for the
// running app to deliver. Mirrors AppConfig's ~/.config/cc-handoff convention so
// everything cc-handoff lives under one tree.
String localBusDir() {
  final home = Platform.environment['HOME'] ?? '';
  return '$home/.config/cc-handoff/local-bus';
}

// LocalMsg is one point-to-point note from one local session to another. [to]
// may be a session id (ts0) or a label; [submit] appends a newline so the
// receiving agent runs it immediately instead of just filling its input box.
class LocalMsg {
  final String from;
  final String to;
  final String body;
  final bool submit;
  LocalMsg(this.from, this.to, this.body, this.submit);
}

// LocalBus is the desktop side of the local session message bus. It keeps
// sessions.json current (so `cc-handoff msg list` can resolve targets) and
// watches outbox/ for messages the CLI drops, handing each to [deliver]. Pure
// file I/O — all session/PTY logic stays in the host (TerminalHost). Desktop
// host only: exactly one bus may watch the outbox, else a message is delivered
// twice.
class LocalBus {
  // registry returns the live sessions to publish to sessions.json.
  final List<Map<String, dynamic>> Function() registry;
  // deliver routes a message into the target session; returns null on success
  // or a human-readable error (target missing/ambiguous/self) the bus writes
  // back as <id>.err so `msg send` can report it.
  final String? Function(LocalMsg msg) deliver;

  LocalBus({required this.registry, required this.deliver});

  StreamSubscription<FileSystemEvent>? _watch;
  Timer? _sweep;
  final Set<String> _processing = {};
  bool _started = false;

  String get _dir => localBusDir();
  String get _outbox => '$_dir/outbox';
  String get _sessionsFile => '$_dir/sessions.json';

  Future<void> start() async {
    if (_started) return;
    _started = true;
    try {
      await Directory(_outbox).create(recursive: true);
      // 700 so another local user can't drop forged messages into the outbox.
      await _chmod700([_dir, _outbox]);
      await syncRegistry();
      await _drainExisting(); // messages left from before we started watching
      _watch = Directory(_outbox).watch().listen(_onEvent, onError: (_) {});
      // Backstop for the watcher: FSEvents can coalesce or drop events under
      // load, and the watch stream can die silently. A low-frequency sweep
      // re-scans the outbox so a missed message is still delivered within a
      // couple seconds — well inside the sender's send timeout — instead of
      // being silently lost (which would read as a false "no receiver").
      _sweep = Timer.periodic(
        const Duration(seconds: 2),
        (_) => unawaited(_drainExisting()),
      );
    } catch (_) {
      // Best-effort: without a watcher, `msg send` simply times out and reports
      // "no receiver" rather than corrupting anything.
    }
  }

  Future<void> _chmod700(List<String> paths) async {
    if (Platform.isWindows) return;
    try {
      await Process.run('chmod', ['700', ...paths]);
    } catch (_) {}
  }

  // syncRegistry rewrites sessions.json from the live session list. Wire to the
  // host's onTermsChanged so it tracks every add/close/rename. Atomic via a
  // temp-file rename so a concurrent `msg list` never reads a half-written file.
  Future<void> syncRegistry() async {
    if (!_started) return;
    try {
      final tmp = File('$_sessionsFile.tmp');
      await tmp.writeAsString(jsonEncode(registry()));
      await tmp.rename(_sessionsFile);
    } catch (_) {}
  }

  Future<void> _drainExisting() async {
    try {
      await for (final e in Directory(_outbox).list()) {
        if (e is File && e.path.endsWith('.json')) await _process(e.path);
      }
    } catch (_) {}
  }

  void _onEvent(FileSystemEvent e) {
    final p = e is FileSystemMoveEvent ? (e.destination ?? e.path) : e.path;
    if (!p.endsWith('.json')) return; // ignore our own .err writes/deletes
    unawaited(_process(p));
  }

  Future<void> _process(String jsonPath) async {
    if (!_processing.add(jsonPath)) return; // in-process dedupe of FS events
    try {
      final base = jsonPath.substring(0, jsonPath.length - '.json'.length);
      final taken = '$base.taken';
      // Atomic claim: across the watcher + the sweep, and across multiple app
      // instances, exactly one rename succeeds — everyone else gets an error and
      // bows out. The filesystem rename IS the mutex, so there's no lock file or
      // liveness probe to go stale and wedge delivery.
      try {
        await File(jsonPath).rename(taken);
      } catch (_) {
        return; // already claimed by someone else, or already gone
      }
      String? err;
      try {
        final m = jsonDecode(await File(taken).readAsString());
        if (m is Map) {
          err = deliver(LocalMsg(
            (m['from'] ?? '').toString(),
            (m['to'] ?? '').toString(),
            (m['body'] ?? '').toString(),
            m['submit'] != false, // default: submit
          ));
        } else {
          err = '消息格式错误';
        }
      } catch (e) {
        err = '消息解析失败: $e';
      }
      // Explicit terminal receipt the sender polls for: <id>.ok on success,
      // <id>.err on failure. Keying on a marker (not "the .json vanished") keeps
      // success/failure unambiguous even though the claim already removed .json.
      try {
        await File(err == null ? '$base.ok' : '$base.err')
            .writeAsString(err ?? 'ok');
      } catch (_) {}
      try {
        await File(taken).delete();
      } catch (_) {}
    } finally {
      _processing.remove(jsonPath);
    }
  }

  void dispose() {
    _watch?.cancel();
    _watch = null;
    _sweep?.cancel();
    _sweep = null;
    _started = false;
  }
}
