import 'package:app/local/word_diff.dart';
import 'package:app/syntax.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

// applyDiffBackground returns a plain TextSpan tree, so these tests need no
// widget pump — they flatten the result and assert on the leaf runs directly.

const _base = TextStyle(color: Color(0xFF000000), fontSize: 12);
const _red = TextStyle(color: Color(0xFFFF0000));
const _blue = TextStyle(color: Color(0xFF0000FF));
const _bg = Color(0x55123456);

// A flattened leaf run: its text and the style that actually applies to it.
typedef _Run = ({String text, TextStyle style});

// _flatten mirrors (independently of) the implementation's private flattener:
// depth-first, each node's style merges over the inherited style.
List<_Run> _flatten(InlineSpan span, [TextStyle inherited = const TextStyle()]) {
  final out = <_Run>[];
  if (span is! TextSpan) return out;
  final effective =
      span.style == null ? inherited : inherited.merge(span.style);
  final text = span.text;
  if (text != null && text.isNotEmpty) out.add((text: text, style: effective));
  for (final child in span.children ?? const <InlineSpan>[]) {
    out.addAll(_flatten(child, effective));
  }
  return out;
}

void main() {
  group('passthrough fast path', () {
    final syntax = TextSpan(children: const [
      TextSpan(text: 'foo', style: _red),
      TextSpan(text: 'bar', style: _blue),
    ], style: _base);

    test('null wordSpans returns the exact same span (zero-cost passthrough)',
        () {
      final out = applyDiffBackground('foobar', syntax, base: _base);
      expect(out, same(syntax));
    });

    test('empty wordSpans returns the exact same span', () {
      final out =
          applyDiffBackground('foobar', syntax, base: _base, wordSpans: const []);
      expect(out, same(syntax));
    });

    test('empty line returns the same span even with word spans', () {
      final out = applyDiffBackground('', syntax,
          base: _base,
          wordSpans: const [WordDiffSpan(0, 0, WordDiffKind.diff)]);
      expect(out, same(syntax));
    });
  });

  test('splits at boundaries not aligned to the syntax runs', () {
    // line 'foobarbaz': syntax runs are 'foobar'(red) 0-6, 'baz'(blue) 6-9.
    // The diff span [3,7) straddles that run boundary.
    final syntax = TextSpan(children: const [
      TextSpan(text: 'foobar', style: _red),
      TextSpan(text: 'baz', style: _blue),
    ], style: _base);
    final out = applyDiffBackground(
      'foobarbaz',
      syntax,
      base: _base,
      wordSpans: const [
        WordDiffSpan(0, 3, WordDiffKind.equal),
        WordDiffSpan(3, 7, WordDiffKind.diff),
        WordDiffSpan(7, 9, WordDiffKind.equal),
      ],
      diffBg: _bg,
    );
    final runs = _flatten(out!);

    // Text is preserved intact and split at both the run and diff boundaries.
    expect(runs.map((r) => r.text).join(), 'foobarbaz');
    expect(runs.map((r) => r.text).toList(), ['foo', 'bar', 'b', 'az']);
    // Foreground colors survive; only the diff sub-range gets the background.
    // 'foo' — red, no bg.
    expect(runs[0].style.color, const Color(0xFFFF0000));
    expect(runs[0].style.backgroundColor, isNull);
    // 'bar' — still red (syntax fg kept), now with the diff background.
    expect(runs[1].style.color, const Color(0xFFFF0000));
    expect(runs[1].style.backgroundColor, _bg);
    // 'b' — blue (crossed into the second run), diff background.
    expect(runs[2].style.color, const Color(0xFF0000FF));
    expect(runs[2].style.backgroundColor, _bg);
    // 'az' — blue, no bg.
    expect(runs[3].style.color, const Color(0xFF0000FF));
    expect(runs[3].style.backgroundColor, isNull);
  });

  test('applies diff background even when there is no syntax span', () {
    final out = applyDiffBackground(
      'abc',
      null,
      base: _base,
      wordSpans: const [
        WordDiffSpan(0, 1, WordDiffKind.equal),
        WordDiffSpan(1, 2, WordDiffKind.diff),
        WordDiffSpan(2, 3, WordDiffKind.equal),
      ],
      diffBg: _bg,
    );
    final runs = _flatten(out!);
    expect(runs.map((r) => r.text).join(), 'abc');
    expect(runs[0].style.backgroundColor, isNull);
    expect(runs[1].style.backgroundColor, _bg);
    expect(runs[2].style.backgroundColor, isNull);
    // Base foreground is preserved throughout.
    for (final r in runs) {
      expect(r.style.color, const Color(0xFF000000));
      expect(r.style.fontSize, 12);
    }
  });
}
