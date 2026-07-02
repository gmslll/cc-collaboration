import 'package:app/local/session_overview.dart';
import 'package:app/screens/terminal_pane.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('SessionStatus parses hook-derived overview states', () {
    expect(sessionStatusFromName('runningTool'), SessionStatus.runningTool);
    expect(sessionStatusFromName('toolFailed'), SessionStatus.toolFailed);
    expect(
      sessionStatusFromName('waitingPermission'),
      SessionStatus.waitingPermission,
    );
    expect(statusLabel(SessionStatus.compacting), '压缩中');
    expect(sessionStatusIsActive(SessionStatus.subagent), isTrue);
    expect(sessionStatusIsActive(SessionStatus.toolFailed), isTrue);
    expect(sessionStatusIsActive(SessionStatus.waitingInput), isFalse);
  });

  // The overview popup can't reach `terms`, so it clears 待 review by routing the
  // sid through the store's reviewedHandler (registered by WorkspacePage as
  // markSessionReviewed). This pins that dispatch + the clear-on-view effect.
  test('markReviewed dispatches the sid to reviewedHandler and clears needsReview',
      () {
    final store = SessionOverviewStore();
    final s = TerminalSession('/repo', 'claude', agent: 'claude');
    addTearDown(s.dispose);
    s.needsReview = true;
    // Mirror WorkspacePage's wiring: reviewedHandler resolves the session + clears.
    String? seen;
    store.reviewedHandler = (sid) {
      seen = sid;
      if (sid == s.id) s.needsReview = false;
    };
    store.markReviewed(s.id);
    expect(seen, s.id, reason: 'markReviewed hands the sid to the handler');
    expect(s.needsReview, isFalse,
        reason: 'a session viewed via the overview popup drops 待 review');
  });

  test('markReviewed is a safe no-op before a handler is registered', () {
    final store = SessionOverviewStore();
    expect(() => store.markReviewed('ts0'), returnsNormally);
  });
}
