import 'dart:io';

import 'package:app/remote/remote_client.dart';
import 'package:app/screens/remote_workspace_page.dart';
import 'package:app/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
      await tester.enterText(find.byType(TextField).at(0), '   ');
      await tester.tap(find.widgetWithText(FilledButton, '创建'));
      await tester.pumpAndSettle();

      expect(result, isNull);
      expect(find.byType(TextField), findsNothing);
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
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
