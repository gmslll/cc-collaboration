import 'package:app/screens/workspace_page.dart';
import 'package:app/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('WorkspaceCommitBranchDialog cancel closes cleanly', (
    tester,
  ) async {
    String? result = 'unchanged';

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () async {
                result = await showDialog<String>(
                  context: context,
                  builder: (_) => const WorkspaceCommitBranchDialog(
                    initialBranch: 'fix-login-abc1234',
                    shortHash: 'abc1234',
                    subject: 'Fix login flow',
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
    expect(find.text('abc1234 · Fix login flow'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      'fix-login-abc1234',
    );

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(result, isNull);
    expect(find.byType(TextField), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('WorkspaceCommitBranchDialog returns entered raw branch', (
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
                  builder: (_) => const WorkspaceCommitBranchDialog(
                    initialBranch: 'branch-def5678',
                    shortHash: 'def5678',
                    subject: 'Refactor',
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
    await tester.enterText(find.byType(TextField), '  feature/refactor  ');
    await tester.tap(find.widgetWithText(FilledButton, 'Create and Checkout'));
    await tester.pumpAndSettle();

    expect(result, '  feature/refactor  ');
    expect(find.byType(TextField), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
