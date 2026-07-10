import 'dart:io';

import 'package:app/remote/remote_client.dart';
import 'package:app/screens/remote_workspace_page.dart';
import 'package:app/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  void expectRemoteDialogScrollSafe(WidgetTester tester) {
    final dialog = tester.widget<AlertDialog>(find.byType(AlertDialog));
    final contentScroll = tester.widget<SingleChildScrollView>(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(SingleChildScrollView),
      ),
    );

    expect(
      dialog.insetPadding,
      const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
    );
    expect(contentScroll.scrollDirection, Axis.vertical);
  }

  test('remote key bar button labels are width constrained', () {
    final source = File(
      'lib/screens/remote_workspace_page.dart',
    ).readAsStringSync();
    final keyBar = source.substring(
      source.indexOf('Widget _keyBar()'),
      source.indexOf('// _openKeyBarEditor lets the user'),
    );

    expect(keyBar, isNot(contains('child: Text(label),')));
    expect(
      keyBar,
      contains('constraints: const BoxConstraints(maxWidth: 120)'),
    );
    expect(keyBar, contains('maxLines: 1'));
    expect(keyBar, contains('overflow: TextOverflow.ellipsis'));
  });

  test('remote workspace dropdown menu height is capped', () {
    expect(remoteWorkspaceMenuMaxHeight(const Size(1024, 900)), 320);
    expect(
      remoteWorkspaceMenuMaxHeight(const Size(320, 420)),
      closeTo(243.6, 0.001),
    );
    expect(remoteWorkspaceMenuMaxHeight(const Size(320, 220)), 160);
  });

  test('remote workspace dialog width fits compact screens', () {
    expect(remoteWorkspaceDialogWidth(const Size(320, 760)), 288);
    expect(remoteWorkspaceDialogWidth(const Size(1024, 760)), 420);
    expect(
      remoteWorkspaceDialogWidth(const Size(360, 760), preferred: 460),
      328,
    );
  });

  test('remote supervisor knowledge dialog size fits compact screens', () {
    expect(
      remoteSupervisorKnowledgeDialogSize(const Size(1024, 800)),
      const Size(520, 600),
    );
    expect(
      remoteSupervisorKnowledgeDialogSize(const Size(360, 420)),
      const Size(328, 372),
    );
    expect(
      remoteSupervisorKnowledgeDialogSize(const Size(220, 220)),
      const Size(188, 172),
    );
  });

  test('remote activity sheet height fits compact screens', () {
    expect(remoteActivitySheetHeight(const Size(1024, 900)), 360);
    expect(remoteActivitySheetHeight(const Size(360, 420)), 360);
    expect(remoteActivitySheetHeight(const Size(320, 260)), 212);
    expect(remoteActivitySheetHeight(const Size(320, 160)), 112);
  });

  test('remote quick reply dialog size fits compact screens', () {
    expect(
      remoteQuickReplyDialogSize(const Size(1024, 800)),
      const Size(520, 520),
    );
    expect(
      remoteQuickReplyDialogSize(const Size(360, 420)),
      const Size(328, 388),
    );
    expect(
      remoteQuickReplyDialogSize(const Size(220, 220)),
      const Size(188, 188),
    );
  });

  test('remote quick reply snapshot height fits compact screens', () {
    expect(remoteQuickReplySnapshotHeight(const Size(1024, 900)), 220);
    expect(
      remoteQuickReplySnapshotHeight(const Size(360, 420)),
      closeTo(176.4, 0.001),
    );
    expect(
      remoteQuickReplySnapshotHeight(const Size(320, 260)),
      closeTo(109.2, 0.001),
    );
  });

  test('remote new session dialog uses scroll-safe controls', () {
    final source = File(
      'lib/screens/remote_workspace_page.dart',
    ).readAsStringSync();
    final dialog = source.substring(
      source.indexOf('  Future<void> _newSessionDialog() async'),
      source.indexOf('  // Open the supervisor knowledge-base editor'),
    );

    expect(dialog, contains('remoteWorkspaceDialogWidth'));
    expect(dialog, contains('SingleChildScrollView'));
    expect(dialog, contains('scrollableBar(scrolling: [agentPicker])'));
    expect(dialog, contains('scrollableBar(scrolling: [supervisorPicker])'));
  });

  test('remote branch create dialog uses scroll-safe layout', () {
    final source = File(
      'lib/screens/remote_workspace_page.dart',
    ).readAsStringSync();
    final dialog = source.substring(
      source.indexOf('class _RemoteBranchCreateDialogState'),
      source.indexOf('// RemoteWorkspacePage is the phone'),
    );

    expect(dialog, contains('insetPadding: const EdgeInsets.symmetric'));
    expect(dialog, contains('remoteWorkspaceDialogWidth'));
    expect(dialog, contains('SingleChildScrollView'));
    expect(dialog, contains('textInputAction: TextInputAction.next'));
    expect(dialog, contains('onSubmitted: (_) => _submit()'));
  });

  test('remote supervisor knowledge dialog uses viewport based bounds', () {
    final source = File(
      'lib/screens/remote_workspace_page.dart',
    ).readAsStringSync();
    final dialog = source.substring(
      source.indexOf('class _SupervisorKnowledgeDialogState'),
      source.indexOf('// _RemoteDiffViewer shows'),
    );

    expect(dialog, contains('remoteSupervisorKnowledgeDialogSize'));
    expect(dialog, contains('MediaQuery.sizeOf(context)'));
    expect(dialog, contains('insetPadding: const EdgeInsets.symmetric'));
    expect(dialog, isNot(contains('maxWidth: 520')));
    expect(dialog, isNot(contains('maxHeight: 600')));
  });

  test('remote activity sheet uses viewport based height', () {
    final source = File(
      'lib/screens/remote_workspace_page.dart',
    ).readAsStringSync();
    final sheet = source.substring(
      source.indexOf('  void _showActivitySheet()'),
      source.indexOf('  void _onPointerMove('),
    );

    expect(sheet, contains('remoteActivitySheetHeight'));
    expect(sheet, contains('MediaQuery.sizeOf(ctx)'));
    expect(sheet, isNot(contains('height: 360')));
  });

  test('remote quick reply dialog uses viewport based bounds', () {
    final source = File(
      'lib/screens/remote_workspace_page.dart',
    ).readAsStringSync();
    final dialog = source.substring(
      source.indexOf('class _QuickReplyDialogState'),
      source.length,
    );

    expect(dialog, contains('remoteQuickReplyDialogSize'));
    expect(dialog, contains('remoteQuickReplySnapshotHeight'));
    expect(dialog, contains('MediaQuery.sizeOf(context)'));
    expect(dialog, contains('SingleChildScrollView'));
    expect(dialog, isNot(contains('height: 220')));
  });

  test('remote incoming file offer dialog uses scroll-safe content', () {
    final source = File(
      'lib/screens/remote_workspace_page.dart',
    ).readAsStringSync();
    final dialog = source.substring(
      source.indexOf('  void _pumpOffers()'),
      source.indexOf('  // _sendFileToMac picks'),
    );

    expect(dialog, contains('MediaQuery.sizeOf(ctx)'));
    expect(dialog, contains('insetPadding: const EdgeInsets.symmetric'));
    expect(dialog, contains('maxLines: 1'));
    expect(dialog, contains('overflow: TextOverflow.ellipsis'));
    expect(dialog, contains('remoteWorkspaceDialogWidth(size)'));
    expect(dialog, contains('SingleChildScrollView'));
    expect(dialog, contains('SelectableText'));
    expect(dialog, isNot(contains('content: Text(')));
  });

  test('remote terminal screen rebinds client lifecycle on widget update', () {
    final source = File(
      'lib/screens/remote_workspace_page.dart',
    ).readAsStringSync();
    final screen = source.substring(
      source.indexOf('class _RemoteTerminalScreenState'),
      source.indexOf('// After a reconnect-driven resync'),
    );

    expect(screen, contains('void didUpdateWidget'));
    expect(screen, contains('_detachRemoteClient(oldWidget.client'));
    expect(screen, contains('_attachRemoteClient(showRefreshSnack: false)'));
    expect(screen, contains('client.removeListener(_onClientChange)'));
    expect(screen, contains('client.leaveViewedSession(session.sid)'));
    expect(screen, contains('widget.client.addListener(_onClientChange)'));
    expect(
      screen,
      contains('widget.client.setViewedSession(widget.session.sid)'),
    );
  });

  test('remote workspace page rebinds client when auth changes', () {
    final source = File(
      'lib/screens/remote_workspace_page.dart',
    ).readAsStringSync();
    final state = source.substring(
      source.indexOf('class _RemoteWorkspacePageState'),
      source.indexOf('  @override\n  void didChangeAppLifecycleState'),
    );

    expect(state, contains('late RemoteClient _c;'));
    expect(state, contains('void didUpdateWidget'));
    expect(state, contains('oldWidget.relayUrl == widget.relayUrl'));
    expect(state, contains('oldWidget.token == widget.token'));
    expect(state, contains('_disposeRemoteClient(oldClient)'));
    expect(state, contains('_c = _newRemoteClient()'));
    expect(state, contains('phoneRemoteClient = client'));
  });

  test('remote worktree screen reloads when target changes', () {
    final source = File(
      'lib/screens/remote_workspace_page.dart',
    ).readAsStringSync();
    final state = source.substring(
      source.indexOf('class _WorktreeScreenState'),
      source.indexOf('  Future<void> _addDialog()'),
    );

    expect(state, contains('void didUpdateWidget'));
    expect(state, contains('!identical(oldWidget.client, widget.client)'));
    expect(state, contains('oldWidget.project.path != widget.project.path'));
    expect(state, contains('void _loadWorktrees()'));
    expect(state, contains('widget.client.loadWorktrees(widget.project.path)'));
  });

  test('remote worktree remove target falls back to path name', () {
    expect(
      remoteWorktreeRemoveTarget(
        RemoteWorktree('/repo/.worktrees/feat-mobile', ''),
      ),
      'feat-mobile',
    );
    expect(
      remoteWorktreeRemoveTarget(
        RemoteWorktree('/repo/.worktrees/feat-team', '  feat/team  '),
      ),
      'feat/team',
    );
  });

  test('remote git bulk action availability follows change state', () {
    const clean = <RemoteGitChange>[];
    expect(remoteGitHasStageableChanges(clean), isFalse);
    expect(remoteGitHasStagedChanges(clean), isFalse);
    expect(remoteGitHasAnyChanges(clean), isFalse);

    final unstaged = [RemoteGitChange('lib/a.dart', 'M', false, false, false)];
    expect(remoteGitHasStageableChanges(unstaged), isTrue);
    expect(remoteGitHasStagedChanges(unstaged), isFalse);
    expect(remoteGitHasAnyChanges(unstaged), isTrue);

    final staged = [RemoteGitChange('lib/a.dart', 'M', true, false, false)];
    expect(remoteGitHasStageableChanges(staged), isFalse);
    expect(remoteGitHasStagedChanges(staged), isTrue);
    expect(remoteGitHasAnyChanges(staged), isTrue);

    final stagedAndModified = [
      RemoteGitChange('lib/a.dart', 'MM', true, false, false),
    ];
    expect(remoteGitHasStageableChanges(stagedAndModified), isTrue);
    expect(remoteGitHasStagedChanges(stagedAndModified), isTrue);
  });

  testWidgets('RemoteCommitDialog returns trimmed message and push choice', (
    tester,
  ) async {
    RemoteCommitDraft? result;

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () async {
                result = await showDialog<RemoteCommitDraft>(
                  context: context,
                  builder: (_) => const RemoteCommitDialog(),
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expectRemoteDialogScrollSafe(tester);
    await tester.enterText(find.byType(TextField), '  fix remote git  ');
    await tester.tap(find.text('提交后 Push'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '提交'));
    await tester.pumpAndSettle();

    expect(result?.message, 'fix remote git');
    expect(result?.push, isTrue);
    expect(find.byType(TextField), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('RemoteWorkspaceCreateDialog trims fields and closes cleanly', (
    tester,
  ) async {
    RemoteWorkspaceDraft? result;

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () async {
                result = await showDialog<RemoteWorkspaceDraft>(
                  context: context,
                  builder: (_) => const RemoteWorkspaceCreateDialog(),
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expectRemoteDialogScrollSafe(tester);
    await tester.enterText(find.byType(TextField).at(0), '  mobile  ');
    await tester.enterText(find.byType(TextField).at(1), '  /tmp/mobile  ');
    await tester.tap(find.widgetWithText(FilledButton, '创建'));
    await tester.pumpAndSettle();

    expect(result?.name, 'mobile');
    expect(result?.path, '/tmp/mobile');
    expect(find.byType(TextField), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'RemoteWorktreeCreateDialog trims fields and ignores empty branch',
    (tester) async {
      RemoteWorktreeDraft? result = const RemoteWorktreeDraft(
        branch: 'unchanged',
        startPoint: 'unchanged',
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: ccTheme(),
          home: Builder(
            builder: (context) => Scaffold(
              body: FilledButton(
                onPressed: () async {
                  result = await showDialog<RemoteWorktreeDraft>(
                    context: context,
                    builder: (_) => const RemoteWorktreeCreateDialog(),
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expectRemoteDialogScrollSafe(tester);
      await tester.enterText(find.byType(TextField).at(0), '   ');
      await tester.tap(find.widgetWithText(FilledButton, '创建'));
      await tester.pumpAndSettle();

      expect(result, isNull);
      expect(find.byType(TextField), findsNothing);
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expectRemoteDialogScrollSafe(tester);
      await tester.enterText(find.byType(TextField).at(0), '  feat/dialogs  ');
      await tester.enterText(find.byType(TextField).at(1), '  main  ');
      await tester.tap(find.widgetWithText(FilledButton, '创建'));
      await tester.pumpAndSettle();

      expect(result?.branch, 'feat/dialogs');
      expect(result?.startPoint, 'main');
      expect(find.byType(TextField), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
