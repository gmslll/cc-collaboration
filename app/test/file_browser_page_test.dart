import 'dart:io';

import 'package:app/screens/file_browser_page.dart';
import 'package:app/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('file browser dynamic titles are width constrained', () {
    final source = File(
      'lib/screens/file_browser_page.dart',
    ).readAsStringSync();

    expect(
      source,
      isNot(contains("appBar: AppBar(title: Text('文件 · \${widget.name}'))")),
    );
    expect(source, isNot(contains('title: Text(title),')));
    expect(source, isNot(contains('title: Text(widget.title),')));
    expect(source, contains("'文件 · \${widget.name}',\n          maxLines: 1"));
    expect(
      source,
      contains('title, maxLines: 1, overflow: TextOverflow.ellipsis'),
    );
    expect(
      source,
      contains('widget.title, maxLines: 1, overflow: TextOverflow.ellipsis'),
    );
    expect(source, contains('overflow: TextOverflow.ellipsis'));
  });

  testWidgets('FileNameDialog cancel closes cleanly', (tester) async {
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
                  builder: (_) => const FileNameDialog(
                    title: '重命名',
                    label: '名称',
                    initial: 'old.dart',
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
      'old.dart',
    );

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(result, isNull);
    expect(find.byType(TextField), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('FileNameDialog returns entered name', (tester) async {
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
                  builder: (_) => const FileNameDialog(
                    title: '新建文件',
                    label: '文件名',
                    hint: 'README.md',
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
    await tester.enterText(find.byType(TextField), '  notes.md  ');
    await tester.tap(find.widgetWithText(FilledButton, '确定'));
    await tester.pumpAndSettle();

    expect(result, '  notes.md  ');
    expect(find.byType(TextField), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
