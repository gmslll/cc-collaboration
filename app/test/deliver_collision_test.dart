import 'dart:io';

import 'package:app/local/local_bus.dart';
import 'package:app/screens/terminal_deck.dart';
import 'package:app/screens/terminal_pane.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

// Minimal host that mixes in TerminalHost so we can exercise deliverLocalMessage
// without the full workspace page. The mixin has no abstract members and
// deliverLocalMessage touches only `terms` + file I/O, so an unmounted State works.
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

  // The delivery tests route through localBusDir() → HOME, so they only run under
  // a throwaway HOME and never touch a real/live bus:  HOME=$(mktemp -d) flutter test …
  // `isolated` gates them (each does `if (!isolated) return;`); inboxHasJson reports
  // whether a target has a parked bus message. Shared here so the three tests don't
  // each re-inline them (mirrors transcript_resolve_test.dart's `isolated` bool).
  final home = Platform.environment['HOME'] ?? '';
  final isolated = home.startsWith('/tmp') ||
      home.startsWith('/private/') ||
      home.startsWith('/var/folders/');
  bool inboxHasJson(TerminalSession t) {
    final inbox = Directory('${localBusDir()}/inbox/${t.id}');
    return inbox.existsSync() &&
        inbox.listSync().any((f) => f.path.endsWith('.json'));
  }

  group('inputDirty tracking', () {
    test('user keystrokes set it; a submit (CR) clears it; empty is a no-op', () {
      final s = TerminalSession('/repo', 'claude', agent: 'claude');
      addTearDown(s.dispose);
      expect(s.inputDirty, isFalse); // fresh session, nothing typed
      s.markUserInput('h');
      expect(s.inputDirty, isTrue); // typed → dirty
      s.markUserInput('i');
      expect(s.inputDirty, isTrue);
      s.markUserInput('\r'); // Enter → submitted → clean again
      expect(s.inputDirty, isFalse);
      s.markUserInput(''); // empty → no change
      expect(s.inputDirty, isFalse);
    });

    test('non-agent session never reports dirty (getter ANDs isAgent)', () {
      final s = TerminalSession('/repo', '', agent: ''); // plain shell
      addTearDown(s.dispose);
      s.markUserInput('typing');
      expect(s.inputDirty, isFalse);
    });
  });

  test(
    'deliverLocalMessage routes dirty→enqueue, clean-idle→paste',
    () async {
      if (!isolated) return; // not an isolated HOME — skip

      final host = _HostState();
      final target = TerminalSession('/repo', 'claude', agent: 'claude');
      addTearDown(target.dispose);
      host.terms.add(target);
      // Make it a READY idle session (started + boot-settled). Without this it's
      // not-ready (dormant, or still in its boot window) and delivery routes to the
      // wake/queue path instead — covered by the dormant + eager-start tests below.
      target.start();
      target.debugMarkBootSettled();
      expect(target.ready, isTrue);
      const from = 'ts-sender';

      // Clean + idle → immediate paste, nothing parked.
      final r1 = host.deliverLocalMessage(LocalMsg(from, target.id, 'hello', true));
      expect(r1, isNull);
      expect(inboxHasJson(target), isFalse,
          reason: 'clean idle target should paste, not enqueue');

      // User is mid-typing → park in the bus inbox instead of pasting over it.
      // markUserInput is the one marker every user-input funnel feeds — the
      // desktop hardware-key & IME paths and remote_host's term.input (phone) all
      // call it — so this assertion covers the remote/phone funnel too.
      target.markUserInput('half-typed');
      final r2 = host.deliverLocalMessage(LocalMsg(from, target.id, 'world', true));
      expect(r2, isNull);
      expect(inboxHasJson(target), isTrue,
          reason: 'dirty input should enqueue to the bus inbox');
    },
  );

  // The dispatch fix: a message to a dormant (never-started) session must WAKE it —
  // spawn the agent and hold the message through boot — instead of pasting into a
  // null PTY (silent loss, the 'spawn 出的休眠会话收不到消息' bug). Then it must
  // auto-run once the agent settles, with NO manual Enter. Same isolated-HOME gate.
  test(
    'deliverLocalMessage wakes a dormant (not-started) target and auto-runs on settle',
    () async {
      if (!isolated) return; // not an isolated HOME — skip

      final host = _HostState();
      final target = TerminalSession('/repo', 'claude', agent: 'claude');
      addTearDown(target.dispose);
      host.terms.add(target);
      expect(target.started, isFalse); // dormant: pane never mounted / hidden tab
      expect(target.ready, isFalse);

      final r =
          host.deliverLocalMessage(LocalMsg('ts-sender', target.id, 'task', true));
      expect(r, isNull);
      expect(target.started, isTrue,
          reason: 'delivery must wake (start) a dormant session');
      expect(target.ready, isFalse,
          reason: 'not ready until the agent boots + settles');
      expect(target.pendingWakeCount, 1,
          reason: 'message held in-memory until ready');
      expect(inboxHasJson(target), isFalse,
          reason: 'wake queues the message, does not park it in the bus inbox');

      // Agent finishes booting (settle timer / cap would fire) → the held message
      // is flushed as paste+submit, so it auto-runs. Queue drains, session ready.
      target.debugMarkBootSettled();
      expect(target.ready, isTrue);
      expect(target.pendingWakeCount, 0,
          reason: 'on settle the message is handed to paste+submit — no manual Enter');
    },
  );

  // The user's core symptom under the old code: a message to an EAGER-STARTED but
  // still-booting tab (started == true, not yet ready) took the direct-paste path
  // and raced the boot. It must instead queue like a dormant target and auto-run on
  // settle — closing the 'started ≠ ready' window. Same isolated-HOME gate.
  test(
    'delivery in the boot window (started, not-ready) queues, then auto-runs on settle',
    () async {
      if (!isolated) return; // not an isolated HOME — skip

      final host = _HostState();
      final target = TerminalSession('/repo', 'claude', agent: 'claude');
      addTearDown(target.dispose);
      host.terms.add(target);
      target.start(); // eager-started (e.g. pane mount / restore) but mid-boot
      expect(target.started, isTrue);
      expect(target.ready, isFalse, reason: 'started ≠ ready — still booting');

      final r =
          host.deliverLocalMessage(LocalMsg('ts-sender', target.id, 'task', true));
      expect(r, isNull);
      expect(target.pendingWakeCount, 1,
          reason: 'boot-window delivery queues instead of racing the paste');
      expect(inboxHasJson(target), isFalse);

      target.debugMarkBootSettled(); // boot settles → flush as paste+submit
      expect(target.ready, isTrue);
      expect(target.pendingWakeCount, 0, reason: 'auto-runs on settle, no manual Enter');
    },
  );

  // The trickiest race: a SECOND message arrives while the session is still not
  // ready (agent mid-boot). It must be queued behind the first — not dropped, not
  // enqueued to the inbox, and not pasted into a not-yet-ready PTY (which would
  // race the boot / double up). Same isolated-HOME gate.
  test(
    'a delivery during the boot window queues behind the first (no loss, no double)',
    () async {
      if (!isolated) return; // not an isolated HOME — skip

      final host = _HostState();
      final target = TerminalSession('/repo', 'claude', agent: 'claude');
      addTearDown(target.dispose);
      host.terms.add(target);

      // First delivery wakes the dormant target (starts it; still not ready).
      host.deliverLocalMessage(LocalMsg('ts-a', target.id, 'first', true));
      expect(target.ready, isFalse);
      expect(target.pendingWakeCount, 1);

      // Second delivery arrives while still booting → appended to the same queue.
      final r2 =
          host.deliverLocalMessage(LocalMsg('ts-b', target.id, 'second', true));
      expect(r2, isNull);
      expect(target.ready, isFalse, reason: 'still booting, not restarted');
      expect(target.pendingWakeCount, 2,
          reason: 'both messages held — the second is not dropped');
      expect(inboxHasJson(target), isFalse,
          reason: 'a not-ready target queues in-memory, never the inbox');

      // Both flush in order once the agent settles (each as paste+submit).
      target.debugMarkBootSettled();
      expect(target.pendingWakeCount, 0);
    },
  );
}
