import 'package:app/screens/workspace_page.dart';
import 'package:app/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
}
