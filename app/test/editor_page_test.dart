import 'dart:async';
import 'dart:io';

import 'package:app/screens/editor_page.dart';
import 'package:app/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('editor dialog width fits compact screens', () {
    expect(editorDialogWidth(const Size(320, 760)), 288);
    expect(editorDialogWidth(const Size(1024, 760)), 420);
    expect(editorDialogWidth(const Size(20, 760)), 420);
  });

  test('editor discard confirmation uses responsive content', () {
    final source = File('lib/screens/editor_page.dart').readAsStringSync();
    final start = source.indexOf('Future<bool> _confirmDiscard()');
    final dialog = source.substring(
      start,
      source.indexOf('@override\n  Widget build', start),
    );

    expect(dialog, contains('MediaQuery.sizeOf(ctx)'));
    expect(dialog, contains('insetPadding: const EdgeInsets.symmetric'));
    expect(dialog, contains('maxLines: 1'));
    expect(dialog, contains('overflow: TextOverflow.ellipsis'));
    expect(dialog, contains('editorDialogWidth(size)'));
    expect(dialog, contains('SingleChildScrollView'));
    expect(dialog, isNot(contains('content: const Text(')));
  });

  testWidgets('stale editor load cannot overwrite a newer file path', (
    tester,
  ) async {
    final key = GlobalKey<CodeEditorPaneState>();
    final reader = _DelayedFileReader();

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(
          body: CodeEditorPane(
            key: key,
            path: '/tmp/first.dart',
            readFile: reader.read,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(reader.requested, ['/tmp/first.dart']);

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(
          body: CodeEditorPane(
            key: key,
            path: '/tmp/second.dart',
            readFile: reader.read,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(reader.requested, ['/tmp/first.dart', '/tmp/second.dart']);

    reader.complete('/tmp/second.dart', 'void second() {}\n');
    await tester.pumpAndSettle();
    expect(key.currentState!.text, 'void second() {}\n');

    reader.complete('/tmp/first.dart', 'void first() {}\n');
    await tester.pumpAndSettle();
    expect(key.currentState!.text, 'void second() {}\n');
  });
}

class _DelayedFileReader {
  final requested = <String>[];
  final _requests = <String, Completer<String>>{};

  Future<String> read(String path) {
    requested.add(path);
    final completer = Completer<String>();
    _requests[path] = completer;
    return completer.future;
  }

  void complete(String path, String content) {
    _requests[path]!.complete(content);
  }
}
