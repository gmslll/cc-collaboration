import 'dart:io';

import 'package:app/remote/remote_host.dart';
import 'package:app/screens/terminal_pane.dart';
import 'package:flutter_test/flutter_test.dart';

class _TestRemoteHost extends RemoteHost {
  _TestRemoteHost({
    required List<TerminalSession> sessions,
    List<RemoteRoot> roots = const [],
    super.onAssignTodo,
  }) : _sessions = sessions,
       super(
         relayUrl: 'http://relay.test',
         token: 'token',
         sessions: (() => sessions),
         roots: (() => roots),
       );

  final List<TerminalSession> _sessions;
  final sent = <Map<String, dynamic>>[];

  @override
  void send(Map<String, dynamic> frame) {
    sent.add(Map<String, dynamic>.from(frame));
  }

  void disposeSessions() {
    for (final s in _sessions) {
      s.dispose();
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('remote sessions and roots include relay project id', () {
    final session = TerminalSession('/repo/backend', 'claude');
    final host = _TestRemoteHost(
      sessions: [session],
      roots: const [RemoteRoot('backend', '/repo', 'team', 'relay-project')],
    );
    addTearDown(host.dispose);
    addTearDown(host.disposeSessions);

    host.onFrame({'t': 'list', 'from': 3});

    final sessions = host.sent.firstWhere((f) => f['t'] == 'sessions');
    final roots = host.sent.firstWhere((f) => f['t'] == 'roots');
    expect(sessions['items'], [containsPair('project_id', 'relay-project')]);
    expect(roots['items'], [containsPair('project_id', 'relay-project')]);
  });

  test(
    'remote fs.write rejects paths escaping root through symlinks',
    () async {
      final root = await Directory.systemTemp.createTemp('cc-remote-root');
      final outside = await Directory.systemTemp.createTemp(
        'cc-remote-outside',
      );
      addTearDown(() => root.delete(recursive: true));
      addTearDown(() => outside.delete(recursive: true));
      await Link('${root.path}/escape').create(outside.path);

      final host = _TestRemoteHost(
        sessions: const [],
        roots: [RemoteRoot('repo', root.path, 'ws')],
      );
      addTearDown(host.dispose);

      host.onFrame({
        't': 'fs.write',
        'from': 7,
        'path': '${root.path}/escape/owned.txt',
        'content': 'owned',
      });
      for (var i = 0; i < 20 && host.sent.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      expect(host.sent, hasLength(1));
      expect(host.sent.single['t'], 'fs.write.err');
      expect(host.sent.single['to'], 7);
      expect(host.sent.single['msg'], 'forbidden');
      expect(File('${outside.path}/owned.txt').existsSync(), isFalse);
    },
  );

  test('remote term.open wakes a deferred restored session', () {
    final session = TerminalSession('', '')..deferred = true;
    final host = _TestRemoteHost(sessions: [session]);
    addTearDown(host.dispose);
    addTearDown(host.disposeSessions);

    var repainted = false;
    host.addListener(() => repainted = true);

    expect(session.started, isFalse);
    expect(session.deferred, isTrue);

    host.onFrame({
      't': 'term.open',
      'sid': session.id,
      'from': 1,
      'cols': 80,
      'rows': 24,
    });

    expect(session.deferred, isFalse);
    expect(session.started, isTrue);
    expect(session.debugRemoteSize, (rows: 24, cols: 80));
    expect(repainted, isTrue);
  });

  test('remote resize is ignored until that client watches the session', () {
    final session = TerminalSession('', '')..deferred = true;
    final host = _TestRemoteHost(sessions: [session]);
    addTearDown(host.dispose);
    addTearDown(host.disposeSessions);

    host.onFrame({
      't': 'term.resize',
      'sid': session.id,
      'from': 1,
      'cols': 100,
      'rows': 40,
    });

    expect(session.debugRemoteSize, isNull);
    expect(session.started, isFalse);
  });

  test('dropping the last watcher clears the remote size', () {
    final session = TerminalSession('', '')..deferred = true;
    final host = _TestRemoteHost(sessions: [session]);
    addTearDown(host.dispose);
    addTearDown(host.disposeSessions);

    host.onFrame({
      't': 'term.open',
      'sid': session.id,
      'from': 1,
      'cols': 80,
      'rows': 24,
    });
    expect(session.debugRemoteSize, (rows: 24, cols: 80));

    host.onPeer(1, 'client', false);

    expect(session.debugRemoteSize, isNull);
  });

  test('watched client resize updates the remote size', () {
    final session = TerminalSession('', '')..deferred = true;
    final host = _TestRemoteHost(sessions: [session]);
    addTearDown(host.dispose);
    addTearDown(host.disposeSessions);

    host.onFrame({
      't': 'term.open',
      'sid': session.id,
      'from': 1,
      'cols': 80,
      'rows': 24,
    });
    host.onFrame({
      't': 'term.resize',
      'sid': session.id,
      'from': 1,
      'cols': 100,
      'rows': 40,
    });

    expect(session.debugRemoteSize, (rows: 40, cols: 100));
  });

  test('todo assign replies ok to the requesting client', () async {
    final host = _TestRemoteHost(
      sessions: const [],
      onAssignTodo: (req) async {
        expect(req['todoId'], 'todo-1');
        return null;
      },
    );
    addTearDown(host.dispose);

    host.onFrame({'t': 'todo.assign', 'from': 7, 'todoId': 'todo-1'});
    await Future<void>.delayed(Duration.zero);

    expect(host.sent, [
      {'t': 'todo.assign.ok', 'to': 7, 'todoId': 'todo-1'},
    ]);
  });

  test('todo assign trims todo id before handler and reply', () async {
    Map<String, dynamic>? seen;
    final host = _TestRemoteHost(
      sessions: const [],
      onAssignTodo: (req) async {
        seen = Map<String, dynamic>.from(req);
        return null;
      },
    );
    addTearDown(host.dispose);

    host.onFrame({'t': 'todo.assign', 'from': 7, 'todoId': ' todo-1 '});
    await Future<void>.delayed(Duration.zero);

    expect(seen?['todoId'], 'todo-1');
    expect(host.sent, [
      {'t': 'todo.assign.ok', 'to': 7, 'todoId': 'todo-1'},
    ]);
  });

  test(
    'todo assign handler exceptions reply err instead of timing out',
    () async {
      final host = _TestRemoteHost(
        sessions: const [],
        onAssignTodo: (_) async => throw StateError('boom'),
      );
      addTearDown(host.dispose);

      host.onFrame({'t': 'todo.assign', 'from': 9, 'todoId': 'todo-2'});
      await Future<void>.delayed(Duration.zero);

      expect(host.sent, hasLength(1));
      expect(host.sent.single['t'], 'todo.assign.err');
      expect(host.sent.single['to'], 9);
      expect(host.sent.single['todoId'], 'todo-2');
      expect(host.sent.single['msg'], contains('boom'));
    },
  );
}
