import 'dart:io';

import 'package:app/local/local_bus.dart';
import 'package:app/local/session_overview.dart';
import 'package:app/screens/session_overview_page.dart';
import 'package:app/screens/terminal_pane.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('capsule choice dialog width fits compact screens', () {
    expect(capsuleChoiceDialogWidth(const Size(320, 760)), 288);
    expect(capsuleChoiceDialogWidth(const Size(1024, 760)), 440);
    expect(capsuleChoiceDialogWidth(const Size(20, 760)), 440);
  });

  test('capsule review loading height fits compact screens', () {
    expect(capsuleReviewLoadingHeight(const Size(1024, 900)), 120);
    expect(
      capsuleReviewLoadingHeight(const Size(320, 500)),
      closeTo(90, 0.001),
    );
    expect(capsuleReviewLoadingHeight(const Size(320, 300)), 80);
  });

  test('capsule review dialog size fits compact screens', () {
    expect(
      capsuleReviewDialogSize(const Size(1200, 900)),
      const Size(620, 760),
    );
    expect(capsuleReviewDialogSize(const Size(360, 420)), const Size(328, 372));
    expect(capsuleReviewDialogSize(const Size(220, 220)), const Size(188, 172));
  });

  test('capsule choice dialog uses responsive content', () {
    final source = File(
      'lib/screens/session_overview_page.dart',
    ).readAsStringSync();
    final dialog = source.substring(
      source.indexOf('Future<void> startCapsuleFlow('),
      source.indexOf('if (!context.mounted) return;'),
    );

    expect(dialog, contains('MediaQuery.sizeOf(ctx)'));
    expect(dialog, contains('insetPadding: const EdgeInsets.symmetric'));
    expect(dialog, contains('maxLines: 1'));
    expect(dialog, contains('overflow: TextOverflow.ellipsis'));
    expect(dialog, contains('capsuleChoiceDialogWidth(size)'));
    expect(dialog, contains('SingleChildScrollView'));
    expect(dialog, isNot(contains('content: const Text(')));
  });

  test('capsule review dialog uses viewport based bounds', () {
    final source = File(
      'lib/screens/session_overview_page.dart',
    ).readAsStringSync();
    final dialog = source.substring(
      source.indexOf('class _CapsuleReviewDialogState'),
    );

    expect(dialog, contains('capsuleReviewDialogSize'));
    expect(dialog, contains('MediaQuery.sizeOf(context)'));
    expect(dialog, contains('insetPadding: const EdgeInsets.symmetric'));
    expect(dialog, contains('maxWidth: dialogSize.width'));
    expect(dialog, contains('maxHeight: dialogSize.height'));
    expect(dialog, isNot(contains('maxWidth: 620')));
  });

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
      String? gotWs,
          gotProj,
          gotKind,
          gotProjectId,
          gotBranch,
          gotStart,
          gotResume;
      store.spawnHandler =
          ({
            required workspace,
            required project,
            required kind,
            projectId,
            newWorktreeBranch,
            worktreeStart,
            resumeAgentSessionId,
            workdir,
          }) async {
            gotWs = workspace;
            gotProj = project;
            gotKind = kind;
            gotProjectId = projectId;
            gotBranch = newWorktreeBranch;
            gotStart = worktreeStart;
            gotResume = resumeAgentSessionId;
            return ('ts42', null);
          };
      final (sid, err) = await store.spawn(
        workspace: 'kunlun',
        project: 'cc-collaboration',
        kind: 'claude',
        projectId: 'relay-project',
        newWorktreeBranch: 'feat/x',
        worktreeStart: 'main',
      );
      expect(sid, 'ts42');
      expect(err, isNull);
      expect(gotWs, 'kunlun');
      expect(gotProj, 'cc-collaboration');
      expect(gotKind, 'claude');
      expect(gotProjectId, 'relay-project');
      expect(gotBranch, 'feat/x');
      expect(gotStart, 'main');
      expect(gotResume, isNull);
    },
  );

  // Pins the 待办 "打开/恢复会话" contract at the store boundary: passing
  // resumeAgentSessionId through spawn() must reach spawnHandler verbatim —
  // the piece workspace_page.dart's _spawnForDispatch/_spawnManagedSession/
  // _openAgent/_launch chain ultimately hands to addTerm, which forwards it
  // into a TerminalSession(resume: true, agentSessionId: ...) construction
  // (see the "accepts a caller-supplied resume id" test below for that final
  // hop — addTerm itself isn't exercised here since it also calls
  // session.start(), which spawns a real OS process).
  test('spawn forwards resumeAgentSessionId to spawnHandler', () async {
    final store = SessionOverviewStore();
    String? gotResume;
    store.spawnHandler =
        ({
          required workspace,
          required project,
          required kind,
          projectId,
          newWorktreeBranch,
          worktreeStart,
          resumeAgentSessionId,
          workdir,
        }) async {
          gotResume = resumeAgentSessionId;
          return ('ts43', null);
        };
    final (sid, _) = await store.spawn(
      workspace: 'kunlun',
      project: 'cc-collaboration',
      kind: 'claude',
      resumeAgentSessionId: '11111111-1111-1111-1111-111111111111',
    );
    expect(sid, 'ts43');
    expect(gotResume, '11111111-1111-1111-1111-111111111111');
  });

  // Regression pin for a review-caught bug: the "打开/恢复会话" resume path
  // reverse-matches a todo's saved assigneeWorkdir to a (workspace, project)
  // pair, but if that resolved workdir string itself isn't ALSO forwarded to
  // spawnHandler, workspace_page.dart's _spawnForDispatch has no way to
  // launch in the exact saved dir (a worktree subdir) instead of falling
  // back to the project root — silently breaking resume for any todo bound
  // to a worktree session.
  test('spawn forwards workdir to spawnHandler', () async {
    final store = SessionOverviewStore();
    String? gotWorkdir;
    store.spawnHandler =
        ({
          required workspace,
          required project,
          required kind,
          projectId,
          newWorktreeBranch,
          worktreeStart,
          resumeAgentSessionId,
          workdir,
        }) async {
          gotWorkdir = workdir;
          return ('ts44', null);
        };
    final (sid, _) = await store.spawn(
      workspace: 'kunlun',
      project: 'cc-collaboration',
      kind: 'claude',
      workdir: '/repo/.worktrees/feat-x',
    );
    expect(sid, 'ts44');
    expect(gotWorkdir, '/repo/.worktrees/feat-x');
  });

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

  test('capsule review submit is guarded and recovers from failures', () {
    final source = File(
      'lib/screens/session_overview_page.dart',
    ).readAsStringSync();
    final reviewDialog = source.substring(
      source.indexOf('class _CapsuleReviewDialogState'),
      source.indexOf('  // _labeledCodeField'),
    );
    final fullReviewDialog = source.substring(
      source.indexOf('class _CapsuleReviewDialogState'),
    );

    expect(reviewDialog, contains('if (_submitting) return;'));
    expect(reviewDialog, contains('try {'));
    expect(reviewDialog, contains('catch (e)'));
    expect(reviewDialog, contains("snack(context, '发送失败: \${errorText(e)}');"));
    expect(reviewDialog, contains('setState(() => _submitting = false);'));
    expect(fullReviewDialog, contains('capsuleReviewLoadingHeight'));
    expect(fullReviewDialog, isNot(contains('height: 120')));
  });

  test(
    'capsule review keeps default private and labels public as team shared',
    () {
      final source = File(
        'lib/screens/session_overview_page.dart',
      ).readAsStringSync();
      final reviewDialog = source.substring(
        source.indexOf('class _CapsuleReviewDialogState'),
        source.indexOf('  // _labeledCodeField'),
      );

      expect(reviewDialog, contains('bool _public = false;'));
      expect(
        reviewDialog,
        contains("visibility: _public ? 'public' : 'private'"),
      );
      expect(source, contains('个人 / 团队共享'));
      expect(source, contains("label: Text('团队')"));
      expect(source, contains('同团队成员能在广场看到'));
      expect(source, isNot(contains('团队所有人能在广场看到')));
    },
  );

  // The last hop of the "打开/恢复会话" chain: TerminalHost.addTerm mints a
  // fresh uuid for a brand-new claude session, but when the caller already
  // has one (a todo's saved assigneeAgentSessionId) it passes that straight
  // through as agentSessionId + resume:true instead — same constructor
  // TerminalSession.restoreTerms uses to reopen a tab after an app restart
  // (terminal_deck.dart). Asserted directly on TerminalSession (not via
  // addTerm) so this doesn't spawn a real PTY process.
  test(
    'TerminalSession accepts a caller-supplied resume id and marks resume:true',
    () {
      const uuid = '11111111-1111-1111-1111-111111111111';
      final s = TerminalSession(
        '/repo',
        'claude',
        agent: 'claude',
        agentSessionId: uuid,
        resume: true,
      );
      addTearDown(s.dispose);
      expect(s.agentSessionId, uuid);
      expect(s.resume, isTrue);
    },
  );
}
