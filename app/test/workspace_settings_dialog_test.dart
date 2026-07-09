import 'package:app/screens/workspace_page.dart';
import 'package:app/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('WorkspaceSettingsDialog cancel closes cleanly', (tester) async {
    WorkspaceSettingsDraft? result = const WorkspaceSettingsDraft(
      preLaunch: 'unchanged',
      editor: 'unchanged',
      agent: 'manual',
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () async {
                result = await showDialog<WorkspaceSettingsDraft>(
                  context: context,
                  builder: (_) => const WorkspaceSettingsDialog(
                    workspaceName: 'kunlun',
                    initialPreLaunch: 'nvm use 20',
                    initialEditor: 'code .',
                    initialAgent: 'codex',
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
    expect(find.text('「kunlun」工作区设置'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField).at(0)).controller?.text,
      'nvm use 20',
    );
    expect(
      tester.widget<TextField>(find.byType(TextField).at(1)).controller?.text,
      'code .',
    );

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(result, isNull);
    expect(find.byType(TextField), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('WorkspaceSettingsDialog returns entered raw settings', (
    tester,
  ) async {
    WorkspaceSettingsDraft? result;

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () async {
                result = await showDialog<WorkspaceSettingsDraft>(
                  context: context,
                  builder: (_) => const WorkspaceSettingsDialog(
                    workspaceName: '',
                    initialAgent: 'unknown',
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
    expect(find.text('「默认」工作区设置'), findsOneWidget);
    expect(find.text('claude'), findsOneWidget);

    await tester.enterText(find.byType(TextField).at(0), '  nvm use 18  ');
    await tester.enterText(find.byType(TextField).at(1), '  code .  ');
    await tester.tap(find.text('claude'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('manual').last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();

    expect(result?.preLaunch, '  nvm use 18  ');
    expect(result?.editor, '  code .  ');
    expect(result?.agent, 'manual');
    expect(find.byType(TextField), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
