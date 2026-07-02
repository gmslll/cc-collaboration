import 'package:app/local/local_bus.dart';
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
  test(
    'markReviewed dispatches the sid to reviewedHandler and clears needsReview',
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
      expect(
        s.needsReview,
        isFalse,
        reason: 'a session viewed via the overview popup drops 待 review',
      );
    },
  );

  test('markReviewed is a safe no-op before a handler is registered', () {
    final store = SessionOverviewStore();
    expect(() => store.markReviewed('ts0'), returnsNormally);
  });

  // 待办 "一键指派" (Track G/I): the top-level 待办 page can't reach `terms`
  // either, so it dispatches through the same handler-indirection as
  // markReviewed above. dispatch() mirrors WorkspacePage's real
  // dispatchHandler = deliverLocalMessage wiring one-for-one.
  test(
    'dispatch forwards the LocalMsg to dispatchHandler and returns its result',
    () {
      final store = SessionOverviewStore();
      LocalMsg? seen;
      store.dispatchHandler = (m) {
        seen = m;
        return null; // success, mirrors deliverLocalMessage's contract
      };
      final err = store.dispatch(LocalMsg('', 'ts3', '[待办] 测试', true));
      expect(err, isNull);
      expect(seen?.to, 'ts3');
      expect(seen?.body, '[待办] 测试');
      expect(seen?.submit, isTrue);
    },
  );

  test('dispatch surfaces the handler error verbatim', () {
    final store = SessionOverviewStore();
    store.dispatchHandler = (m) => '找不到目标会话「${m.to}」';
    expect(store.dispatch(LocalMsg('', 'nope', 'x', true)), isNotNull);
  });

  test(
    'dispatch is a safe "not ready" error before a handler is registered',
    () {
      final store = SessionOverviewStore();
      expect(store.dispatch(LocalMsg('', 'ts0', 'x', true)), '会话总览未就绪');
    },
  );

  test(
    'spawn forwards args to spawnHandler and returns its (sid, error) tuple',
    () async {
      final store = SessionOverviewStore();
      String? gotWs, gotProj, gotKind, gotBranch, gotStart;
      store.spawnHandler =
          ({
            required workspace,
            required project,
            required kind,
            newWorktreeBranch,
            worktreeStart,
          }) async {
            gotWs = workspace;
            gotProj = project;
            gotKind = kind;
            gotBranch = newWorktreeBranch;
            gotStart = worktreeStart;
            return ('ts42', null);
          };
      final (sid, err) = await store.spawn(
        workspace: 'kunlun',
        project: 'cc-collaboration',
        kind: 'claude',
        newWorktreeBranch: 'feat/x',
        worktreeStart: 'main',
      );
      expect(sid, 'ts42');
      expect(err, isNull);
      expect(gotWs, 'kunlun');
      expect(gotProj, 'cc-collaboration');
      expect(gotKind, 'claude');
      expect(gotBranch, 'feat/x');
      expect(gotStart, 'main');
    },
  );

  test(
    'spawn is a safe "not ready" error before a handler is registered',
    () async {
      final store = SessionOverviewStore();
      final (sid, err) = await store.spawn(
        workspace: 'kunlun',
        project: 'cc-collaboration',
        kind: 'claude',
      );
      expect(sid, isNull);
      expect(err, '会话总览未就绪');
    },
  );
}
