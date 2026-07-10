import 'dart:io';

import 'package:app/local/lsp/lsp_plugin.dart';
import 'package:app/screens/plugins_page.dart';
import 'package:app/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('plugins dialog size fits compact screens', () {
    expect(pluginsDialogSize(const Size(1024, 800)), const Size(580, 620));
    expect(pluginsDialogSize(const Size(360, 420)), const Size(328, 372));
    expect(pluginsDialogSize(const Size(220, 220)), const Size(188, 172));
  });

  test('plugins dialog uses viewport based bounds', () {
    final source = File('lib/screens/plugins_page.dart').readAsStringSync();
    final dialog = source.substring(
      source.indexOf('Future<void> showPluginsDialog('),
      source.indexOf('class _PluginsPane'),
    );

    expect(dialog, contains('pluginsDialogSize'));
    expect(dialog, contains('MediaQuery.sizeOf(ctx)'));
    expect(dialog, contains('insetPadding: const EdgeInsets.symmetric'));
    expect(dialog, isNot(contains('maxWidth: 580')));
    expect(dialog, isNot(contains('maxHeight: 620')));
  });

  test('LSP command dialog width fits compact screens', () {
    expect(lspCommandDialogWidth(const Size(320, 760)), 288);
    expect(lspCommandDialogWidth(const Size(1024, 760)), 440);
    expect(lspCommandDialogWidth(const Size(360, 760), preferred: 460), 328);
  });

  testWidgets('LSP command dialog cancel closes cleanly', (tester) async {
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
                  builder: (_) => LspCommandDialog(
                    plugin: kLspServers.first,
                    initialCommand: 'custom-gopls',
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
    expect(find.text('Go (gopls) · 服务器命令'), findsOneWidget);
    final title = tester.widget<Text>(find.text('Go (gopls) · 服务器命令'));
    expect(title.maxLines, 1);
    expect(title.overflow, TextOverflow.ellipsis);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      'custom-gopls',
    );

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(result, isNull);
    expect(find.byType(TextField), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('LSP command dialog fits compact screens', (tester) async {
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
                await showDialog<String>(
                  context: context,
                  builder: (_) => LspCommandDialog(
                    plugin: kLspServers.first,
                    initialCommand:
                        '/very/long/team/workspace/toolchain/bin/custom-gopls',
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

  testWidgets('LSP command dialog returns edited command', (tester) async {
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
                  builder: (_) => LspCommandDialog(
                    plugin: kLspServers.first,
                    initialCommand: 'gopls',
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
    await tester.enterText(find.byType(TextField), '  /opt/bin/gopls  ');
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();

    expect(result, '  /opt/bin/gopls  ');
    expect(find.byType(TextField), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
