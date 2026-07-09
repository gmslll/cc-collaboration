import 'package:app/screens/workspace_page.dart';
import 'package:app/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('WorkspaceSessionRenameDialog cancel closes cleanly', (
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
                  builder: (_) => const WorkspaceSessionRenameDialog(
                    initialName: 'worker',
                    hint: 'claude',
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
      'worker',
    );

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(result, isNull);
    expect(find.byType(TextField), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('WorkspaceSessionRenameDialog returns entered raw name', (
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
                  builder: (_) =>
                      const WorkspaceSessionRenameDialog(hint: 'codex'),
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
    await tester.enterText(find.byType(TextField), '  reviewer  ');
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();

    expect(result, '  reviewer  ');
    expect(find.byType(TextField), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
