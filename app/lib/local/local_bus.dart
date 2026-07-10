import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'hook_activity.dart';
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

List<HookActivity> localBusHookActivities(String sessionId, {int limit = 20}) {
  try {
    final dir = Directory('${localBusDir()}/events/$sessionId');
    if (!dir.existsSync()) return const [];
    final files =
        dir
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.json'))
            .toList()
          ..sort((a, b) => b.path.compareTo(a.path));
    final out = <HookActivity>[];
    for (final f in files.take(limit)) {
      try {
        final m = jsonDecode(f.readAsStringSync());
        if (m is Map) out.add(HookActivity.fromJson(m));
      } catch (_) {}
    }
    return out;
  } catch (_) {
    return const [];
  }
}

// ---------------------------------------------------------------- inbox lock --
//
// One session's inbox (<bus>/inbox/<id>/) has two independent drainers that
// must never act on the same parked message at once: the receiving agent's
// own `cc-handoff bus-hook` (Stop delivery, Go side — ListMsgs+ClearMsgs in
// runBusHookDrain) and this app's escalate-timeout fallback in
// terminal_deck.dart (a message the target's hook hasn't drained within a few
// seconds gets force-pasted instead of waiting forever — the "parked
// forever" bug this exists to fix). Without coordination the failure mode is
// a double delivery: the Stop hook wakes the agent with the parked message at
// the same moment the app is independently pasting the same text into the PTY.
//
// Both sides coordinate through the SAME claim file, <inbox>/.lock, using the
// one mutual-exclusion primitive guaranteed to behave identically in Go and
// Dart: atomic exclusive create to acquire, delete to release. (flock/fcntl
// were considered and rejected: Dart's RandomAccessFile.lock and Go's
// syscall.Flock are not guaranteed to observe the same lock table across the
// two runtimes, so an exclusive-create claim file — mirroring the
// claim-by-rename pattern LocalBus._process already uses for outbox delivery
// — is the only primitive both sides can trust. See
// internal/localbus/lock.go (AcquireDrainLock) for the Go side of this exact
// protocol.)

const Duration _inboxLockStaleAfter = Duration(seconds: 10);
const Duration _inboxLockRetryInterval = Duration(milliseconds: 20);

String _inboxLockPath(String sessionId) =>
    '${localBusDir()}/inbox/$sessionId/.lock';

// acquireInboxDrainLock claims [sessionId]'s inbox lock, retrying with
// backoff until [timeout]. A lock file older than _inboxLockStaleAfter is
// treated as abandoned (the holder crashed mid critical section — both
// sides' critical sections, list+write+clear / check+paste+delete, run in
// low-single-digit milliseconds, never seconds) and is stolen. Returns false
// on timeout, which the caller treats as "someone else is actively draining
// this inbox right now" and simply gives up escalating for this round rather
// than blocking indefinitely.
Future<bool> acquireInboxDrainLock(
  String sessionId, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final lockFile = File(_inboxLockPath(sessionId));
  final deadline = DateTime.now().add(timeout);
  while (true) {
    try {
      await lockFile.create(recursive: true, exclusive: true);
      return true;
    } catch (_) {
      try {
        final stat = await lockFile.stat();
        if (stat.type != FileSystemEntityType.notFound &&
            DateTime.now().difference(stat.modified) > _inboxLockStaleAfter) {
          await lockFile.delete();
          continue; // retry immediately; don't count the steal against the deadline
        }
      } catch (_) {}
      if (DateTime.now().isAfter(deadline)) return false;
      await Future<void>.delayed(_inboxLockRetryInterval);
    }
  }
}

// releaseInboxDrainLock releases a lock acquireInboxDrainLock returned true
// for. Best-effort: a failed delete just means the NEXT acquire finds a
// stale-after-10s lock and steals it, per acquireInboxDrainLock.
Future<void> releaseInboxDrainLock(String sessionId) async {
  try {
    await File(_inboxLockPath(sessionId)).delete();
  } catch (_) {}
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
  static const Duration orphanTtl = Duration(days: 7);
  static const Duration _maintenanceInterval = Duration(hours: 6);

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
  // spawn serves a kind:"spawn" request (`cc-handoff supervisor spawn`): the HOST
  // resolves [project] (optionally narrowed by [workspace]) to a managed project,
  // launches a new app-managed session there — [agent] is claude|codex|shell,
  // [supervisor] flags a 总管 session, [workdir] optionally targets a worktree —
  // and writes the new session id into [out] (the <id>.ok body). Returns null on
  // success or an error → <id>.err. This is how a supervisor agent opens a session
  // in the tree/on the bus instead of a detached terminal.
  final Future<String?> Function(
    String project,
    String workspace,
    String agent,
    bool supervisor,
    String workdir,
    StringSink out,
  ) spawn;
  // kill serves a kind:"kill" request (`cc-handoff msg kill`): the HOST
  // resolves [to] and terminates that session's tab — kills its PTY and drops
  // it from the session list, the same effect as the tab's × button. [from] is
  // the caller's own session id, so the HOST can refuse a self-kill; it also
  // refuses a supervisor target regardless of caller (see killLocalSession).
  // Returns null on success or an error (unknown/ambiguous target, self-kill,
  // supervisor target) → <id>.err.
  final String? Function(String from, String to) kill;
  // Tests pass a throwaway directory so lifecycle cleanup can be exercised
  // without ever touching the user's live ~/.config/cc-handoff/local-bus.
  final String? busDirectory;

  LocalBus({
    required this.registry,
    required this.deliver,
    required this.readOutput,
    required this.readUsage,
    required this.spawn,
    required this.kill,
    this.busDirectory,
  });

  // Secondary TerminalHost surfaces (currently the handoff inbox) do not own
  // the outbox watcher or sessions.json publisher, but their real-close paths
  // still need the exact same artifact cleanup. This factory supplies inert bus
  // callbacks so those hosts can call cleanupSessionArtifacts without starting
  // a second LocalBus watcher.
  factory LocalBus.artifactCleanup({
    required List<Map<String, dynamic>> Function() registry,
    String? busDirectory,
  }) => LocalBus(
    registry: registry,
    deliver: (_) => 'artifact-cleanup-only bus',
    readOutput: (_, _, _, _) async => 'artifact-cleanup-only bus',
    readUsage: (_, _) async => 'artifact-cleanup-only bus',
    spawn: (_, _, _, _, _, _) async => 'artifact-cleanup-only bus',
    kill: (_, _) => 'artifact-cleanup-only bus',
    busDirectory: busDirectory,
  );

  StreamSubscription<FileSystemEvent>? _watch;
  Timer? _sweep;
  Timer? _maintenanceSweep;
  final Set<String> _processing = {};
  bool _started = false;
  bool _maintenanceRunning = false;
  Future<void> _registryWrites = Future<void>.value();

  String get _dir => busDirectory ?? localBusDir();
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
      if (!_started) return;
      await runMaintenance();
      if (!_started) return;
      await _drainExisting(); // messages left from before we started watching
      if (!_started) return;
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
      // Session artifact pruning is deliberately independent of the 2-second
      // delivery backstop above: walking every events/sessions/inbox directory
      // on each outbox sweep would turn a cheap reliability check into constant
      // disk churn. Startup + every six hours is sufficient for a seven-day TTL.
      _maintenanceSweep = Timer.periodic(
        _maintenanceInterval,
        (_) => unawaited(runMaintenance()),
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
  Future<void> syncRegistry() {
    if (!_started) return Future<void>.value();
    late final String payload;
    try {
      payload = jsonEncode(registry());
    } catch (_) {
      return Future<void>.value();
    }
    // onTermsChanged/onActiveTermChanged can request overlapping writes. Keep
    // the atomic tmp+rename sequence serial so one caller cannot rename another
    // caller's temp file out from under it. cleanupSessionArtifacts awaits this
    // queue before consulting sessions.json, so a just-closed sid is no longer
    // mistaken for an active one due to a stale registry snapshot.
    final write = _registryWrites.then((_) async {
      try {
        final tmp = File('$_sessionsFile.tmp');
        await tmp.writeAsString(payload);
        await tmp.rename(_sessionsFile);
      } catch (_) {}
    });
    _registryWrites = write;
    return write;
  }

  // cleanupSessionArtifacts is the one explicit-close cleanup entry point. It
  // removes only local-bus cache for [sid]: hook activity events and the
  // CC_SESSION_ID -> agent-session mapping. A non-empty inbox is durable
  // delivery state, so it is always retained; an empty inbox directory is safe
  // to remove. Agent transcripts/rollouts live elsewhere and are never in scope.
  //
  // The strict sid grammar makes every path below a single safe child name. A
  // malformed/traversal sid is rejected before any filesystem operation.
  Future<bool> cleanupSessionArtifacts(String sid) async {
    if (!_isSafeSessionId(sid)) return false;
    await syncRegistry();
    final active = await _activeSessionIds();
    if (active.contains(sid)) return false;
    await _deleteSessionArtifacts(sid);
    return true;
  }

  // runMaintenance performs the low-frequency storage pass: prune session
  // cache whose latest activity is older than seven days, then discard only
  // stale terminal outbox artifacts (.ok/.err/.taken/tmp). Pending .json
  // requests are never TTL-deleted.
  Future<void> runMaintenance({DateTime? now}) async {
    if (_maintenanceRunning) return;
    _maintenanceRunning = true;
    try {
      await pruneOrphanArtifacts(now: now);
      await _pruneOutboxArtifacts(now ?? DateTime.now());
    } finally {
      _maintenanceRunning = false;
    }
  }

  Future<void> pruneOrphanArtifacts({DateTime? now}) async {
    final cutoffNow = now ?? DateTime.now();
    await syncRegistry();
    final active = await _activeSessionIds();
    final candidates = await _artifactSessionIds();
    for (final sid in candidates) {
      if (active.contains(sid)) continue;
      final lastActivity = await _lastSessionArtifactActivity(sid);
      if (lastActivity == null) continue; // unknown age: preserve, don't guess
      if (cutoffNow.difference(lastActivity) <= orphanTtl) continue;
      // The pass can span many orphan directories. Re-check after the awaits
      // above so a sid restored/spawned while maintenance was scanning cannot
      // be deleted from under the newly active session.
      if ((await _activeSessionIds()).contains(sid)) continue;
      await _deleteSessionArtifacts(sid);
    }
  }

  static final RegExp _safeSessionId = RegExp(
    r'^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$',
  );

  static bool _isSafeSessionId(String sid) => _safeSessionId.hasMatch(sid);

  Future<Set<String>> _activeSessionIds() async {
    final out = <String>{};
    try {
      for (final session in registry()) {
        final sid = session['id']?.toString() ?? '';
        if (_isSafeSessionId(sid)) out.add(sid);
      }
    } catch (_) {}
    // Protect the on-disk live registry too. Ordinarily syncRegistry just made
    // it identical to registry(), but the union is intentionally conservative
    // if a write failed or another app instance owns a still-active session.
    try {
      final decoded = jsonDecode(await File(_sessionsFile).readAsString());
      if (decoded is List) {
        for (final session in decoded) {
          if (session is! Map) continue;
          final sid = session['id']?.toString() ?? '';
          if (_isSafeSessionId(sid)) out.add(sid);
        }
      }
    } catch (_) {}
    return out;
  }

  Future<Set<String>> _artifactSessionIds() async {
    final out = <String>{};
    await _addDirectorySessionIds('$_dir/events', out);
    await _addDirectorySessionIds('$_dir/inbox', out);
    final mappings = Directory('$_dir/sessions');
    try {
      await for (final entity in mappings.list(followLinks: false)) {
        if (entity is! File) continue;
        final name = _leafName(entity.path);
        if (!name.endsWith('.json')) continue;
        final sid = name.substring(0, name.length - '.json'.length);
        if (_isSafeSessionId(sid)) out.add(sid);
      }
    } catch (_) {}
    return out;
  }

  Future<void> _addDirectorySessionIds(String root, Set<String> out) async {
    try {
      await for (final entity in Directory(root).list(followLinks: false)) {
        if (entity is! Directory) continue;
        final sid = _leafName(entity.path);
        if (_isSafeSessionId(sid)) out.add(sid);
      }
    } catch (_) {}
  }

  String _leafName(String path) {
    final slash = path.lastIndexOf('/');
    final backslash = path.lastIndexOf(r'\');
    return path.substring((slash > backslash ? slash : backslash) + 1);
  }

  Future<DateTime?> _lastSessionArtifactActivity(String sid) async {
    if (!_isSafeSessionId(sid)) return null;
    final times = <DateTime>[];
    final eventActivity = await _directoryActivity('$_dir/events/$sid');
    if (eventActivity != null) times.add(eventActivity);
    final mappingActivity = await _fileActivity('$_dir/sessions/$sid.json');
    if (mappingActivity != null) times.add(mappingActivity);

    // An inbox marker is real session activity and participates in the TTL.
    // An already-drained, empty inbox is only a disposable container; its
    // directory mtime must not keep otherwise-old events alive indefinitely.
    final inboxActivity = await _directoryActivity(
      '$_dir/inbox/$sid',
      includeEmptyDirectory: times.isEmpty,
    );
    if (inboxActivity != null) times.add(inboxActivity);
    if (times.isEmpty) return null;
    return times.reduce((a, b) => a.isAfter(b) ? a : b);
  }

  Future<DateTime?> _fileActivity(String path) async {
    try {
      final type = await FileSystemEntity.type(path, followLinks: false);
      if (type != FileSystemEntityType.file) return null;
      return (await File(path).stat()).modified;
    } catch (_) {
      return null;
    }
  }

  Future<DateTime?> _directoryActivity(
    String path, {
    bool includeEmptyDirectory = true,
  }) async {
    try {
      final type = await FileSystemEntity.type(path, followLinks: false);
      if (type != FileSystemEntityType.directory) return null;
      DateTime? latest;
      await for (final entity in Directory(path).list(followLinks: false)) {
        final entityType = await FileSystemEntity.type(
          entity.path,
          followLinks: false,
        );
        if (entityType != FileSystemEntityType.file &&
            entityType != FileSystemEntityType.directory) {
          continue;
        }
        try {
          final modified = (await entity.stat()).modified;
          if (latest == null || modified.isAfter(latest)) latest = modified;
        } catch (_) {}
      }
      if (latest != null || !includeEmptyDirectory) return latest;
      return (await Directory(path).stat()).modified;
    } catch (_) {
      return null;
    }
  }

  Future<void> _deleteSessionArtifacts(String sid) async {
    if (!_isSafeSessionId(sid)) return;
    await _deleteDirectoryOrLink('$_dir/events/$sid', recursive: true);
    await _deleteFileOrLink('$_dir/sessions/$sid.json');
    await _deleteInboxIfEmpty(sid);
  }

  Future<void> _deleteDirectoryOrLink(
    String path, {
    required bool recursive,
  }) async {
    try {
      final type = await FileSystemEntity.type(path, followLinks: false);
      if (type == FileSystemEntityType.directory) {
        await Directory(path).delete(recursive: recursive);
      } else if (type == FileSystemEntityType.link) {
        await Link(path).delete();
      }
    } catch (_) {}
  }

  Future<void> _deleteFileOrLink(String path) async {
    try {
      final type = await FileSystemEntity.type(path, followLinks: false);
      if (type == FileSystemEntityType.file) {
        await File(path).delete();
      } else if (type == FileSystemEntityType.link) {
        await Link(path).delete();
      }
    } catch (_) {}
  }

  Future<void> _deleteInboxIfEmpty(String sid) async {
    if (!_isSafeSessionId(sid)) return;
    final path = '$_dir/inbox/$sid';
    try {
      final type = await FileSystemEntity.type(path, followLinks: false);
      if (type == FileSystemEntityType.link) {
        return; // cannot prove the linked inbox has no pending messages
      }
      if (type != FileSystemEntityType.directory) return;
      final staleLocks = <File>[];
      await for (final entity in Directory(path).list(followLinks: false)) {
        if (entity is File && _leafName(entity.path) == '.lock') {
          final age = DateTime.now().difference((await entity.stat()).modified);
          if (age <= _inboxLockStaleAfter) {
            return; // a drainer may still own this inbox
          }
          staleLocks.add(entity);
          continue;
        }
        return; // any message/tmp/unknown marker is conservatively pending
      }
      for (final lock in staleLocks) {
        try {
          await lock.delete();
        } catch (_) {
          return;
        }
      }
      // Non-recursive delete closes the check/delete race safely: if a writer
      // parked a message after the empty scan, deletion fails and the inbox is
      // retained instead of losing that message.
      await Directory(path).delete();
    } catch (_) {}
  }

  Future<void> _pruneOutboxArtifacts(DateTime now) async {
    try {
      await for (final entity in Directory(_outbox).list(followLinks: false)) {
        if (entity is! File) continue;
        final name = _leafName(entity.path);
        final requestId = _staleOutboxRequestId(name);
        if (requestId == null) continue;
        final modified = (await entity.stat()).modified;
        if (now.difference(modified) <= orphanTtl) continue;
        final jsonPath = '$_outbox/$requestId.json';
        final takenPath = '$_outbox/$requestId.taken';
        if (_processing.contains(jsonPath) ||
            await File(jsonPath).exists() ||
            (name != '$requestId.taken' && await File(takenPath).exists())) {
          continue; // request is still published or currently claimed
        }
        try {
          await entity.delete();
        } catch (_) {}
      }
    } catch (_) {}
  }

  String? _staleOutboxRequestId(String name) {
    String? id;
    if (name.startsWith('.') && name.endsWith('.tmp')) {
      id = name.substring(1, name.length - '.tmp'.length);
    } else if (name.endsWith('.ok.tmp')) {
      id = name.substring(0, name.length - '.ok.tmp'.length);
    } else {
      for (final suffix in const ['.ok', '.err', '.taken', '.tmp']) {
        if (name.endsWith(suffix)) {
          id = name.substring(0, name.length - suffix.length);
          break;
        }
      }
    }
    return id != null && _isSafeSessionId(id) ? id : null;
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
          } else if (kind == 'spawn') {
            // Open a new app-managed session; the .ok body is the new session id.
            final out = StringBuffer();
            err = await spawn(
              (m['project'] ?? '').toString(),
              (m['workspace'] ?? '').toString(),
              (m['agent'] ?? '').toString(),
              m['supervisor'] == true,
              (m['workdir'] ?? '').toString(),
              out,
            );
            if (err == null) okBody = out.toString();
          } else if (kind == 'kill') {
            // No .ok body beyond the default "ok" — `msg kill` just needs the
            // receipt, not a payload.
            err = kill((m['from'] ?? '').toString(), (m['to'] ?? '').toString());
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
    _maintenanceSweep?.cancel();
    _maintenanceSweep = null;
    _started = false;
  }
}
