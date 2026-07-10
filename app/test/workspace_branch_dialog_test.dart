import 'dart:io';

import 'package:app/screens/workspace_page.dart';
import 'package:app/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('workspace branch dialog width fits compact screens', () {
    expect(workspaceBranchDialogWidth(const Size(320, 760)), 288);
    expect(workspaceBranchDialogWidth(const Size(1024, 760)), 420);
    expect(
      workspaceBranchDialogWidth(const Size(360, 760), preferred: 460),
      328,
    );
  });

  test('workspace branch full dialog size fits compact screens', () {
    expect(
      workspaceBranchFullDialogSize(const Size(1024, 800)),
      const Size(760, 660),
    );
    expect(
      workspaceBranchFullDialogSize(const Size(360, 420)),
      const Size(328, 372),
    );
    expect(
      workspaceBranchFullDialogSize(const Size(220, 220)),
      const Size(188, 172),
    );
  });

  test('workspace branch full dialog uses viewport based bounds', () {
    final source = File(
      'lib/screens/workspace/branch_dialog.dart',
    ).readAsStringSync();
    final dialog = source.substring(
      source.indexOf('class _BranchDialogState'),
      source.indexOf('class _BranchListPane'),
    );

    expect(dialog, contains('workspaceBranchFullDialogSize'));
    expect(dialog, contains('MediaQuery.sizeOf(context)'));
    expect(dialog, contains('insetPadding: const EdgeInsets.symmetric'));
    expect(dialog, isNot(contains('width: 760')));
    expect(dialog, isNot(contains('height: 660')));
  });

  testWidgets('WorkspaceBranchConfirmDialog fits compact screens', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 320);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    bool? result;
    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () async {
                result = await showDialog<bool>(
                  context: context,
                  builder: (_) => const WorkspaceBranchConfirmDialog(
                    title: '删除分支?',
                    message:
                        'feature/very/long/branch/name/that/keeps/going\n\n'
                        'git branch -d feature/very/long/branch/name/that/keeps/going',
                    confirmLabel: '删除',
                    destructive: true,
                  ),
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

    final dialog = tester.widget<AlertDialog>(find.byType(AlertDialog));
    final title = tester.widget<Text>(find.text('删除分支?'));
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
    expect(title.maxLines, 1);
    expect(title.overflow, TextOverflow.ellipsis);
    expect(contentScroll.scrollDirection, Axis.vertical);

    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();
    expect(result, isTrue);
    expect(tester.takeException(), isNull);
  });

  test('workspace branch action confirms are responsive', () {
    final source = File(
      'lib/screens/workspace/branch_dialog.dart',
    ).readAsStringSync();
    final deleteLocal = source.substring(
      source.indexOf('Future<void> _deleteBranch('),
      source.indexOf('Future<void> _deleteRemoteBranch('),
    );
    final deleteRemote = source.substring(
      source.indexOf('Future<void> _deleteRemoteBranch('),
      source.indexOf('Future<void> _pushBranch('),
    );
    final pushBranch = source.substring(
      source.indexOf('Future<void> _pushBranch('),
      source.indexOf('Future<void> _mergeBranch('),
    );

    for (final dialog in [deleteLocal, deleteRemote, pushBranch]) {
      expect(dialog, contains('WorkspaceBranchConfirmDialog('));
      expect(dialog, isNot(contains('AlertDialog(')));
      expect(dialog, isNot(contains('content: Text(')));
    }
  });

  testWidgets('WorkspaceBranchCreateDialog cancel closes cleanly', (
    tester,
  ) async {
    WorkspaceBranchCreateDraft? result = const WorkspaceBranchCreateDraft(
      branch: 'unchanged',
      startRef: 'unchanged',
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () async {
                result = await showDialog<WorkspaceBranchCreateDraft>(
                  context: context,
                  builder: (_) => const WorkspaceBranchCreateDialog(
                    initialBranch: 'feat/ui',
                    initialStartRef: 'main',
                  ),
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
    expect(find.byType(TextField), findsNWidgets(2));
    expect(
      tester.widget<TextField>(find.byType(TextField).at(0)).controller?.text,
      'feat/ui',
    );
    expect(
      tester.widget<TextField>(find.byType(TextField).at(1)).controller?.text,
      'main',
    );

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(result, isNull);
    expect(find.byType(TextField), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('WorkspaceBranchCreateDialog returns entered raw values', (
    tester,
  ) async {
    WorkspaceBranchCreateDraft? result;

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () async {
                result = await showDialog<WorkspaceBranchCreateDraft>(
                  context: context,
                  builder: (_) => const WorkspaceBranchCreateDialog(),
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
    await tester.enterText(find.byType(TextField).at(0), '  feat/branch  ');
    await tester.enterText(find.byType(TextField).at(1), '  develop  ');
    await tester.tap(find.widgetWithText(FilledButton, '创建并切换'));
    await tester.pumpAndSettle();

    expect(result?.branch, '  feat/branch  ');
    expect(result?.startRef, '  develop  ');
    expect(find.byType(TextField), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('WorkspaceBranchCreateDialog fits compact screens', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 360);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () async {
                await showDialog<WorkspaceBranchCreateDraft>(
                  context: context,
                  builder: (_) => const WorkspaceBranchCreateDialog(
                    initialBranch: 'feature/very-long-branch-name',
                    initialStartRef: 'origin/main',
                  ),
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
    expect(tester.takeException(), isNull);
  });

  testWidgets('WorkspaceBranchRenameDialog returns entered raw name', (
    tester,
  ) async {
    String? result;

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () async {
                result = await showDialog<String>(
                  context: context,
                  builder: (_) => const WorkspaceBranchRenameDialog(
                    initialName: 'feature/old',
                  ),
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
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      'feature/old',
    );
    await tester.enterText(find.byType(TextField), '  feature/new  ');
    await tester.tap(find.widgetWithText(FilledButton, '重命名'));
    await tester.pumpAndSettle();

    expect(result, '  feature/new  ');
    expect(find.byType(TextField), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('WorkspaceBranchRenameDialog fits compact screens', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 320);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () async {
                await showDialog<String>(
                  context: context,
                  builder: (_) => const WorkspaceBranchRenameDialog(
                    initialName: 'feature/very-long-current-name',
                  ),
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
    expect(tester.takeException(), isNull);
  });
}
