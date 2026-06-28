import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'platform.dart';

// localBusDir is the per-user directory the local session bus lives in. Sessions
// the desktop app spawns get CC_BUS_DIR pointing here; the bundled `cc-handoff
// msg` CLI reads sessions.json and drops outgoing messages into outbox/ for the
// running app to deliver. Mirrors AppConfig's cc-handoff config dir (ccConfigDir)
// so everything cc-handoff lives under one tree on every platform.
String localBusDir() => '${ccConfigDir()}/local-bus';

// localBusAgentSessionId reads the agent's own session id that `cc-handoff
// bus-hook` recorded for the tab whose CC_SESSION_ID is [sessionId] — written
// from each Claude/Codex hook payload to <bus>/sessions/<id>.json. Lets a tab
// bind to (and resume) the agent's exact session. null until the session's
// first hook fires.
String? localBusAgentSessionId(String sessionId) {
  try {
    final f = File('${localBusDir()}/sessions/$sessionId.json');
    if (!f.existsSync()) return null;
    final m = jsonDecode(f.readAsStringSync());
    if (m is! Map) return null;
    final id = m['id']?.toString();
    return (id != null && id.isNotEmpty) ? id : null;
  } catch (_) {
    return null;
  }
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
  // readOutput renders a target session's recent output into [out] for a
  // kind:"read" request: [transcript] carries the per-call --transcript flag, and
  // the HOST decides screen-scrape vs structured transcript (also consulting its
  // own toggle) — the bus stays dumb plumbing, no UI policy here. Returns null on
  // success (the rendered text becomes the <id>.ok payload) or an error → <id>.err.
  final Future<String?> Function(
    String to,
    int lines,
    bool transcript,
    StringSink out,
  ) readOutput;
  // readUsage serves a kind:"usage" request: it resolves the target session and
  // writes its token/cost usage as a JSON object into [out] (the <id>.ok body).
  // Returns null on success or an error → <id>.err. Same shape as readOutput, no
  // lines/transcript flags — usage is always the structured snapshot.
  final Future<String?> Function(String to, StringSink out) readUsage;

  LocalBus({
    required this.registry,
    required this.deliver,
    required this.readOutput,
    required this.readUsage,
  });

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
      // On success <id>.ok carries this body: a plain "ok" for a delivered
      // message, or the rendered snapshot text for a kind:"read" request — the
      // .ok receipt doubles as the read reply, so no extra file type is needed.
      String okBody = 'ok';
      try {
        final m = jsonDecode(await File(taken).readAsString());
        if (m is Map) {
          // kind defaults to "msg" so old `send` payloads (no kind) deliver as
          // before; "read" renders the target's screen instead of injecting it.
          final kind = (m['kind'] ?? 'msg').toString();
          if (kind == 'read') {
            final lines = (m['lines'] is num) ? (m['lines'] as num).toInt() : 200;
            final out = StringBuffer();
            err = await readOutput(
              (m['to'] ?? '').toString(),
              lines,
              m['transcript'] == true,
              out,
            );
            if (err == null) okBody = out.toString();
          } else if (kind == 'usage') {
            final out = StringBuffer();
            err = await readUsage((m['to'] ?? '').toString(), out);
            if (err == null) okBody = out.toString();
          } else {
            err = deliver(LocalMsg(
              (m['from'] ?? '').toString(),
              (m['to'] ?? '').toString(),
              (m['body'] ?? '').toString(),
              m['submit'] != false, // default: submit
            ));
          }
        } else {
          err = '消息格式错误';
        }
      } catch (e) {
        err = '消息解析失败: $e';
      }
      // Explicit terminal receipt the sender polls for: <id>.ok on success,
      // <id>.err on failure. Keying on a marker (not "the .json vanished") keeps
      // success/failure unambiguous even though the claim already removed .json.
      // The .ok is written atomically (temp + rename) because a `msg read`
      // sender reads its content — a half-written snapshot must never be seen.
      try {
        if (err == null) {
          final okPath = '$base.ok';
          final tmp = File('$okPath.tmp');
          await tmp.writeAsString(okBody);
          await tmp.rename(okPath);
        } else {
          await File('$base.err').writeAsString(err);
        }
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
