import 'package:app/remote/remote_host.dart';
import 'package:app/screens/terminal_pane.dart';
import 'package:flutter_test/flutter_test.dart';

class _TestRemoteHost extends RemoteHost {
  _TestRemoteHost({required List<TerminalSession> sessions})
    : _sessions = sessions,
      super(
        relayUrl: 'http://relay.test',
        token: 'token',
        sessions: (() => sessions),
        roots: (() => const <RemoteRoot>[]),
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
}
