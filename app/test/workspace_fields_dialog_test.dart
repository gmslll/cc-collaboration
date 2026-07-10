import 'package:app/screens/workspace_page.dart';
import 'package:app/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('WorkspaceFieldsDialog cancel closes cleanly', (tester) async {
    List<String>? result = const ['unchanged'];

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () async {
                result = await showDialog<List<String>>(
                  context: context,
                  builder: (_) => const WorkspaceFieldsDialog(
                    title: '新建工作区',
                    okLabel: '创建',
                    fields: [
                      WorkspaceFieldSpec(label: '名称', hint: 'kunlun'),
                      WorkspaceFieldSpec(label: '根目录(可选)'),
                    ],
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

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(result, isNull);
    expect(find.byType(TextField), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('WorkspaceFieldsDialog returns entered raw values', (
    tester,
  ) async {
    List<String>? result;

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () async {
                result = await showDialog<List<String>>(
                  context: context,
                  builder: (_) => const WorkspaceFieldsDialog(
                    title: '在项目中新建 worktree',
                    okLabel: '创建',
                    fields: [
                      WorkspaceFieldSpec(label: '分支名', required: true),
                      WorkspaceFieldSpec(label: '起点 ref(可选)'),
                    ],
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
    await tester.enterText(find.byType(TextField).at(0), '  feat/dialogs  ');
    await tester.enterText(find.byType(TextField).at(1), '  main  ');
    await tester.tap(find.widgetWithText(FilledButton, '创建'));
    await tester.pumpAndSettle();

    expect(result, ['  feat/dialogs  ', '  main  ']);
    expect(find.byType(TextField), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
