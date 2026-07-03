import 'package:app/widgets/markdown_lite_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

// Collects every literal text run in a TextSpan tree, in order.
List<String> _leafTexts(InlineSpan span) {
  final out = <String>[];
  span.visitChildren((s) {
    if (s is TextSpan) {
      if (s.text != null) out.add(s.text!);
      if (s.children != null) {
        for (final c in s.children!) out.addAll(_leafTexts(c));
      }
    }
    return true;
  });
  return out;
}

void main() {
  testWidgets(
      'buildTextSpan still decorates markdown outside the IME composing range',
      (tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (context) {
        ctx = context;
        return const SizedBox();
      }),
    ));

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
  });

  group('hideMarkers: true (TodoBodyView read-only rendering)', () {
    const style = TextStyle(fontSize: 14);

    test('heading markers are dropped, not just dimmed', () {
      final texts = _leafTexts(
          TextSpan(children: decorateMarkdownLine('## Title', style, hideMarkers: true)));
      expect(texts.join(), 'Title');
      expect(texts.any((t) => t.contains('#')), isFalse);
    });

    test('blockquote marker is dropped', () {
      final texts = _leafTexts(
          TextSpan(children: decorateMarkdownLine('> quoted', style, hideMarkers: true)));
      expect(texts.join(), 'quoted');
      expect(texts.any((t) => t.contains('>')), isFalse);
    });

    test('list item marker is kept (it has visual meaning, not just syntax)', () {
      final texts = _leafTexts(
          TextSpan(children: decorateMarkdownLine('- item', style, hideMarkers: true)));
      expect(texts.join(), '- item');
    });

    test('bold ** markers are dropped', () {
      final texts = _leafTexts(
          TextSpan(children: inlineMarkdownSpans('**bold**', style, hideMarkers: true)));
      expect(texts.join(), 'bold');
      expect(texts.any((t) => t.contains('*')), isFalse);
    });

    test('italic * marker is dropped', () {
      final texts = _leafTexts(
          TextSpan(children: inlineMarkdownSpans('*italic*', style, hideMarkers: true)));
      expect(texts.join(), 'italic');
      expect(texts.any((t) => t.contains('*')), isFalse);
    });

    test('inline code ` markers are dropped', () {
      final texts = _leafTexts(
          TextSpan(children: inlineMarkdownSpans('`code`', style, hideMarkers: true)));
      expect(texts.join(), 'code');
      expect(texts.any((t) => t.contains('`')), isFalse);
    });

    test('default (hideMarkers omitted) still shows the markers, just dimmed', () {
      final texts =
          _leafTexts(TextSpan(children: decorateMarkdownLine('# Title', style)));
      expect(texts.join(), '# Title');
    });
  });
}
