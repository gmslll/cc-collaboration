import 'dart:io';

import 'package:app/local/local_bus.dart';
import 'package:app/screens/terminal_deck.dart';
import 'package:app/screens/terminal_pane.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

// Minimal host that mixes in TerminalHost, mirroring deliver_collision_test.dart's
// _Host. These tests route through localBusDir() → HOME, so they only run under
// a throwaway HOME and never touch a real/live bus:
//   HOME=$(mktemp -d) flutter test test/escalate_bus_inbox_test.dart
class _Host extends StatefulWidget {
  const _Host();
  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> with TerminalHost<_Host> {
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final home = Platform.environment['HOME'] ?? '';
  final isolated = home.startsWith('/tmp') ||
      home.startsWith('/private/') ||
      home.startsWith('/var/folders/');

  // parkOneMessage delivers to a dirty (mid-typing) target so deliverLocalMessage
  // parks instead of pastes, then returns the single parked marker's path — same
  // setup deliver_collision_test.dart uses for its "dirty→enqueue" case.
  String parkOneMessage(_HostState host, TerminalSession target, LocalMsg m) {
    target.markUserInput('half-typed');
    final err = host.deliverLocalMessage(m);
    expect(err, isNull);
    final inbox = Directory('${localBusDir()}/inbox/${target.id}');
    final parked = inbox
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.json'))
        .toList();
    expect(parked, hasLength(1), reason: 'expected exactly one parked message');
    return parked.first.path;
  }

  String lockPathFor(TerminalSession target) =>
      '${localBusDir()}/inbox/${target.id}/.lock';

  test(
    'a message drained before escalate fires is not force-delivered again',
    () async {
      if (!isolated) return; // not an isolated HOME — skip (see header)

      final host = _HostState();
      final target = TerminalSession('/repo', 'claude', agent: 'claude');
      addTearDown(target.dispose);
      host.terms.add(target);
      target.start();
      target.debugMarkBootSettled();

      const from = 'ts-sender';
      final m = LocalMsg(from, target.id, 'hello', true);
      final path = parkOneMessage(host, target, m);

      // Simulate the target's own hook (PostToolUse/Stop) draining it before
      // the escalate window elapses — ack = file gone, no separate protocol.
      File(path).deleteSync();

      // Force the escalate check to run now instead of waiting the real
      // multi-second window.
      await host.debugEscalateBusInboxNow(target, path, m);

      // Must not recreate the marker, must not leave a lock behind, must not
      // re-park or double-deliver.
      expect(File(path).existsSync(), isFalse);
      expect(File(lockPathFor(target)).existsSync(), isFalse);
    },
  );

  test(
    'a message nobody drains is force-delivered by escalate and cleared',
    () async {
      if (!isolated) return;

      final host = _HostState();
      final target = TerminalSession('/repo', 'claude', agent: 'claude');
      addTearDown(target.dispose);
      host.terms.add(target);
      target.start();
      target.debugMarkBootSettled();

      const from = 'ts-sender';
      final m = LocalMsg(from, target.id, 'hello', true);
      final path = parkOneMessage(host, target, m);

      // Nobody drains it — force the escalate check now (in production this
      // would fire after _escalateTimeout with no hook having run).
      await host.debugEscalateBusInboxNow(target, path, m);

      // Escalate force-delivered it: marker cleared, lock released.
      expect(File(path).existsSync(), isFalse);
      expect(File(lockPathFor(target)).existsSync(), isFalse);
    },
  );

  test(
    'escalate abandons the message when the inbox lock is held elsewhere',
    () async {
      if (!isolated) return;

      final host = _HostState();
      final target = TerminalSession('/repo', 'claude', agent: 'claude');
      addTearDown(target.dispose);
      host.terms.add(target);
      target.start();
      target.debugMarkBootSettled();

      const from = 'ts-sender';
      final m = LocalMsg(from, target.id, 'hello', true);
      final path = parkOneMessage(host, target, m);

      // Simulate the Go hook actively draining this inbox right now — it
      // holds the SAME lock file escalate contends for.
      final locked = await acquireInboxDrainLock(target.id);
      expect(locked, isTrue);
      try {
        await host.debugEscalateBusInboxNow(target, path, m);
        // Escalate must have backed off rather than double-delivering —
        // the message stays parked for the (simulated) hook holding the lock.
        expect(File(path).existsSync(), isTrue);
      } finally {
        await releaseInboxDrainLock(target.id);
      }
    },
  );
}
