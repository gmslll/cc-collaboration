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

  // Routing depends on localBusDir() → HOME. Run under a throwaway HOME so it
  // never touches a real/live bus:  HOME=$(mktemp -d) flutter test ...
  // Self-skips otherwise.
  test(
    'deliverLocalMessage routes dirty→enqueue, clean-idle→paste',
    () async {
      final home = Platform.environment['HOME'] ?? '';
      if (!home.startsWith('/tmp') &&
          !home.startsWith('/private/') &&
          !home.startsWith('/var/folders/')) {
        return; // not an isolated HOME — skip
      }

      final host = _HostState();
      final target = TerminalSession('/repo', 'claude', agent: 'claude');
      addTearDown(target.dispose);
      host.terms.add(target);
      // Start it so it's a RUNNING idle session (a live PTY). Without this the
      // target is dormant (_started == false) and delivery routes to the wake
      // path instead — covered by the separate 'wakes a dormant target' test.
      target.start();
      const from = 'ts-sender';
      final inbox = Directory('${localBusDir()}/inbox/${target.id}');

      bool inboxHasJson() =>
          inbox.existsSync() &&
          inbox.listSync().any((f) => f.path.endsWith('.json'));

      // Clean + idle → immediate paste, nothing parked.
      final r1 = host.deliverLocalMessage(LocalMsg(from, target.id, 'hello', true));
      expect(r1, isNull);
      expect(inboxHasJson(), isFalse,
          reason: 'clean idle target should paste, not enqueue');

      // User is mid-typing → park in the bus inbox instead of pasting over it.
      // markUserInput is the one marker every user-input funnel feeds — the
      // desktop hardware-key & IME paths and remote_host's term.input (phone) all
      // call it — so this assertion covers the remote/phone funnel too.
      target.markUserInput('half-typed');
      final r2 = host.deliverLocalMessage(LocalMsg(from, target.id, 'world', true));
      expect(r2, isNull);
      expect(inboxHasJson(), isTrue,
          reason: 'dirty input should enqueue to the bus inbox');
    },
  );

  // The dispatch fix: a message to a dormant (never-started) session must WAKE
  // it — spawn the agent and hold the message for its boot — instead of pasting
  // into a null PTY (silent loss, the 'spawn 出的休眠会话收不到消息' bug). Same
  // isolated-HOME gate as the routing test.
  test(
    'deliverLocalMessage wakes a dormant (not-started) target instead of losing it',
    () async {
      final home = Platform.environment['HOME'] ?? '';
      if (!home.startsWith('/tmp') &&
          !home.startsWith('/private/') &&
          !home.startsWith('/var/folders/')) {
        return; // not an isolated HOME — skip
      }

      final host = _HostState();
      final target = TerminalSession('/repo', 'claude', agent: 'claude');
      addTearDown(target.dispose);
      host.terms.add(target);
      expect(target.started, isFalse); // dormant: pane never mounted / hidden tab

      final inbox = Directory('${localBusDir()}/inbox/${target.id}');
      bool inboxHasJson() =>
          inbox.existsSync() &&
          inbox.listSync().any((f) => f.path.endsWith('.json'));

      final r =
          host.deliverLocalMessage(LocalMsg('ts-sender', target.id, 'task', true));
      expect(r, isNull);
      expect(target.started, isTrue,
          reason: 'delivery must wake (start) a dormant session');
      expect(target.waking, isTrue,
          reason: 'message is held until the agent boots + settles');
      expect(inboxHasJson(), isFalse,
          reason: 'wake queues the message in-memory, not the bus inbox');
    },
  );
}
