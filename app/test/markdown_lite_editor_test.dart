import 'dart:async';
import 'dart:typed_data';

import 'package:app/api/relay_client.dart';
import 'package:app/widgets/markdown_lite_editor.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// Collects every literal text run in a TextSpan tree, in order.
List<String> _leafTexts(InlineSpan span) {
  final out = <String>[];
  span.visitChildren((s) {
    if (s is TextSpan) {
      if (s.text != null) out.add(s.text!);
      if (s.children != null) {
        for (final c in s.children!) {
          out.addAll(_leafTexts(c));
        }
      }
    }
    return true;
  });
  return out;
}

void main() {
  testWidgets(
    'stale dropped image upload cannot insert into a different todo',
    (tester) async {
      final firstClient = _DelayedUploadClient();
      final secondClient = _DelayedUploadClient();
      final controller = MarkdownLiteController(text: 'old body');

      Widget editor(RelayClient client, String todoId) => MaterialApp(
        home: Scaffold(
          body: MarkdownLiteEditor(
            controller: controller,
            client: client,
            todoId: todoId,
          ),
        ),
      );

      await tester.pumpWidget(editor(firstClient, 'td1'));
      _dropImage(tester, 'old.png', [1, 2, 3]);
      await tester.pump();
      await tester.pump();
      expect(firstClient.requested, ['td1/old.png']);

      controller.value = const TextEditingValue(
        text: 'new body',
        selection: TextSelection.collapsed(offset: 8),
      );
      await tester.pumpWidget(editor(secondClient, 'td2'));
      _dropImage(tester, 'new.png', [4, 5, 6]);
      await tester.pump();
      await tester.pump();
      expect(secondClient.requested, ['td2/new.png']);

      secondClient.complete('td2', 'new.png');
      await tester.pump();
      expect(controller.text, 'new body![](new.png)');

      firstClient.complete('td1', 'old.png');
      await tester.pump();
      expect(controller.text, 'new body![](new.png)');
      await tester.pump(const Duration(seconds: 3));
    },
  );

  testWidgets(
    'buildTextSpan still decorates markdown outside the IME composing range',
    (tester) async {
      late BuildContext ctx;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              ctx = context;
              return const SizedBox();
            },
          ),
        ),
      );

      // "**bold** " is fully outside the composing range (which sits over
      // "wor" in "world"); before the fix the whole textBefore/textAfter
      // strings were emitted as flat, undecorated TextSpans, so the bold
      // markers would show up literally instead of being dimmed out.
      const text = '**bold** world';
      final composingStart = text.indexOf('wor');
      final controller = MarkdownLiteController(text: text)
        ..value = TextEditingValue(
          text: text,
          composing: TextRange(start: composingStart, end: composingStart + 3),
        );

      final span = controller.buildTextSpan(
        context: ctx,
        style: const TextStyle(fontSize: 14),
        withComposing: true,
      );

      final texts = _leafTexts(span);
      // The decorator splits "**bold**" into three spans: '**', 'bold', '**'.
      // If textBefore had gone through undecorated (the bug), it would appear
      // as one single '**bold** ' run instead.
      expect(texts, contains('**'));
      expect(texts, contains('bold'));
      expect(texts, isNot(contains('**bold** ')));
    },
  );

  group('hideMarkers: true (TodoBodyView read-only rendering)', () {
    const style = TextStyle(fontSize: 14);

    test('heading markers are dropped, not just dimmed', () {
      final texts = _leafTexts(
        TextSpan(
          children: decorateMarkdownLine('## Title', style, hideMarkers: true),
        ),
      );
      expect(texts.join(), 'Title');
      expect(texts.any((t) => t.contains('#')), isFalse);
    });

    test('blockquote marker is dropped', () {
      final texts = _leafTexts(
        TextSpan(
          children: decorateMarkdownLine('> quoted', style, hideMarkers: true),
        ),
      );
      expect(texts.join(), 'quoted');
      expect(texts.any((t) => t.contains('>')), isFalse);
    });

    test(
      'list item marker is kept (it has visual meaning, not just syntax)',
      () {
        final texts = _leafTexts(
          TextSpan(
            children: decorateMarkdownLine('- item', style, hideMarkers: true),
          ),
        );
        expect(texts.join(), '- item');
      },
    );

    test('bold ** markers are dropped', () {
      final texts = _leafTexts(
        TextSpan(
          children: inlineMarkdownSpans('**bold**', style, hideMarkers: true),
        ),
      );
      expect(texts.join(), 'bold');
      expect(texts.any((t) => t.contains('*')), isFalse);
    });

    test('italic * marker is dropped', () {
      final texts = _leafTexts(
        TextSpan(
          children: inlineMarkdownSpans('*italic*', style, hideMarkers: true),
        ),
      );
      expect(texts.join(), 'italic');
      expect(texts.any((t) => t.contains('*')), isFalse);
    });

    test('inline code ` markers are dropped', () {
      final texts = _leafTexts(
        TextSpan(
          children: inlineMarkdownSpans('`code`', style, hideMarkers: true),
        ),
      );
      expect(texts.join(), 'code');
      expect(texts.any((t) => t.contains('`')), isFalse);
    });

    test(
      'default (hideMarkers omitted) still shows the markers, just dimmed',
      () {
        final texts = _leafTexts(
          TextSpan(children: decorateMarkdownLine('# Title', style)),
        );
        expect(texts.join(), '# Title');
      },
    );
  });
}

void _dropImage(WidgetTester tester, String name, List<int> bytes) {
  final target = tester.widget<DropTarget>(find.byType(DropTarget));
  target.onDragDone!(
    DropDoneDetails(
      files: [
        DropItemFile.fromData(
          Uint8List.fromList(bytes),
          name: name,
          path: name,
        ),
      ],
      localPosition: Offset.zero,
      globalPosition: Offset.zero,
    ),
  );
}

class _DelayedUploadClient extends RelayClient {
  _DelayedUploadClient() : super('http://127.0.0.1', 'tok');

  final requested = <String>[];
  final _uploads = <String, Completer<void>>{};

  @override
  Future<void> uploadTodoAttachment(String id, String name, List<int> bytes) {
    requested.add(_key(id, name));
    final completer = Completer<void>();
    _uploads[_key(id, name)] = completer;
    return completer.future;
  }

  String _key(String id, String name) => '$id/$name';

  void complete(String id, String name) {
    _uploads[_key(id, name)]!.complete();
  }
}
