import 'package:app/screens/terminal_deck.dart';
import 'package:app/screens/terminal_pane.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

// Minimal host that mixes in TerminalHost, mirroring deliver_collision_test.dart's
// _Host — killLocalSession's guard checks (self/supervisor/unknown-target) touch
// only `terms`, so a bare unmounted State works for those. The success path calls
// closeTerm, which setState()s, so it needs a real mounted Element — those tests
// use a GlobalKey + pumpWidget instead of a bare _HostState().
class _Host extends StatefulWidget {
  const _Host({super.key});
  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> with TerminalHost<_Host> {
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('killLocalSession refuses self-kill (from == to)', () {
    final host = _HostState();
    final target = TerminalSession('/repo', 'claude', agent: 'claude');
    addTearDown(target.dispose);
    host.terms.add(target);

    final err = host.killLocalSession(target.id, target.id);
    expect(err, isNotNull);
    expect(err, contains('自己'));
    expect(host.terms.contains(target), isTrue,
        reason: 'refused kill must not touch terms');
  });

  test('killLocalSession refuses a supervisor target regardless of caller', () {
    final host = _HostState();
    final target = TerminalSession(
      '/repo',
      'claude',
      agent: 'claude',
      supervisor: true,
    );
    addTearDown(target.dispose);
    host.terms.add(target);

    final err = host.killLocalSession('ts-someone-else', target.id);
    expect(err, isNotNull);
    expect(err, contains('总管'));
    expect(host.terms.contains(target), isTrue,
        reason: 'refused kill must not touch terms');
  });

  test('killLocalSession errors on an unknown target', () {
    final host = _HostState();
    final err = host.killLocalSession('ts0', 'ts-nonexistent');
    expect(err, isNotNull);
  });

  testWidgets(
    'killLocalSession on a valid non-supervisor target closes it like closeTerm',
    (tester) async {
      final key = GlobalKey<_HostState>();
      await tester.pumpWidget(_Host(key: key));
      final host = key.currentState!;
      final target = TerminalSession('/repo', 'claude', agent: 'claude');
      String? closedSid;
      host.onTermClosed = (sid) => closedSid = sid;
      host.terms.add(target);
      expect(host.terms.contains(target), isTrue);

      final err = host.killLocalSession('ts-someone-else', target.id);
      await tester.pump();

      expect(err, isNull);
      expect(host.terms.contains(target), isFalse,
          reason: 'kill removes the session from terms, same as closeTerm');
      expect(
        closedSid,
        target.id,
        reason: 'kill must enter the explicit-close artifact lifecycle',
      );
    },
  );

  test('disposeTerms does not report an explicit close', () {
    final host = _HostState();
    final target = TerminalSession('/repo', '', agent: '');
    var closeCount = 0;
    host.onTermClosed = (_) => closeCount++;
    host.terms.add(target);

    host.disposeTerms();

    expect(
      closeCount,
      0,
      reason: 'app shutdown preserves sessions for next-launch restore',
    );
  });

  testWidgets('bulk real close reports every removed session once', (
    tester,
  ) async {
    final key = GlobalKey<_HostState>();
    await tester.pumpWidget(_Host(key: key));
    final host = key.currentState!;
    final keep = TerminalSession('/repo', '', agent: '');
    final close1 = TerminalSession('/repo', '', agent: '');
    final close2 = TerminalSession('/repo', '', agent: '');
    final closed = <String>[];
    host.onTermClosed = closed.add;
    host.terms.addAll([keep, close1, close2]);
    for (final session in host.terms) {
      host.debugAssignSessionToPane(session.id);
    }

    host.closeTermsToRight(0);
    keep.debugMarkBootSettled();
    await tester.pump();

    expect(host.terms, [keep]);
    expect(closed, [close1.id, close2.id]);
    addTearDown(keep.dispose);
  });
}
