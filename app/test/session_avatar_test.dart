import 'package:app/local/session_overview.dart';
import 'package:app/screens/terminal_pane.dart';
import 'package:app/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// The workspace session-tree avatar is dynamic: it rebuilds off the session's
// activityRev (bumped on every busy / needs-review transition) and animates while
// the session is working. These pin the rebuild signal + that the avatar renders
// for each activity state.

// pumpAvatar mounts one SessionActivityAvatar in a minimal app shell.
Future<void> pumpAvatar(
  WidgetTester tester,
  SessionStatus status, {
  bool isAgent = true,
}) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: Center(
        child: SessionActivityAvatar(
          seed: 'ts9',
          isAgent: isAgent,
          status: status,
          size: 20,
        ),
      ),
    ),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TerminalSession.activityRev drives the live avatar', () {
    test('bumps when needsReview flips; dedups an equal write', () {
      final s = TerminalSession('/repo', 'claude', agent: 'claude');
      addTearDown(s.dispose);
      final start = s.activityRev.value;
      s.needsReview = true; // done a turn → 待 review
      expect(s.activityRev.value, start + 1);
      s.needsReview = true; // no change → no bump
      expect(s.activityRev.value, start + 1);
      s.needsReview = false; // reviewed → back to idle
      expect(s.activityRev.value, start + 2);
    });

    test('bumps when a submit \\r starts a turn (working)', () {
      final s = TerminalSession('/repo', 'claude', agent: 'claude');
      addTearDown(s.dispose);
      final start = s.activityRev.value;
      s.sendText('\r'); // agent submit → busy → bump
      expect(s.busy, isTrue);
      expect(s.activityRev.value, greaterThan(start));
    });
  });

  group('SessionActivityAvatar', () {
    testWidgets('renders calm states without error (idle / needs-review / shell)',
        (tester) async {
      for (final (status, isAgent) in [
        (SessionStatus.idle, true),
        (SessionStatus.needsReview, true), // steady attention dot, no pulse
        (SessionStatus.shell, false),
      ]) {
        await pumpAvatar(tester, status, isAgent: isAgent);
        expect(find.byType(SessionActivityAvatar), findsOneWidget);
      }
    });

    testWidgets('working state animates (pulsing halo) and cleans up its ticker',
        (tester) async {
      await pumpAvatar(tester, SessionStatus.working);
      expect(find.byType(SessionActivityAvatar), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 300)); // advance the pulse
      expect(find.byType(SessionActivityAvatar), findsOneWidget);
      // Dispose so the repeating animation ticker doesn't outlive the test.
      await tester.pumpWidget(const SizedBox());
    });
  });
}
