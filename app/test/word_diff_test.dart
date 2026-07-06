import 'package:app/local/word_diff.dart';
import 'package:flutter_test/flutter_test.dart';

// assertSeamless verifies a side's spans strictly, seamlessly cover
// [0, lineLen): start at 0, each span begins where the previous ended, and the
// last reaches lineLen. This is the core invariant the renderer relies on.
void assertSeamless(List<WordDiffSpan> spans, int lineLen) {
  var cursor = 0;
  for (final s in spans) {
    expect(s.start, cursor, reason: 'span must abut the previous one');
    expect(s.end, greaterThanOrEqualTo(s.start));
    cursor = s.end;
  }
  expect(cursor, lineLen, reason: 'spans must cover the whole line');
}

void main() {
  test('identical lines return null (nothing to diff)', () {
    expect(diffWords('  return foo;', '  return foo;'), isNull);
  });

  test('a near-total rewrite returns null (low similarity fallback)', () {
    // No token — word or separator — is shared, so Dice ratio is 0 (< 0.25).
    expect(diffWords('alpha+beta', 'gamma-delta'), isNull);
  });

  test('appended-only change: real GoLand screenshot case', () {
    const oldLine = 'case model.FBOParcelStatusOutbound:';
    const newLine =
        'case model.FBOParcelStatusOutbound, model.FBOParcelStatusInTransit:';
    final r = diffWords(oldLine, newLine);
    expect(r, isNotNull);

    // The old line deleted nothing → one whole-line equal span.
    expect(r!.oldSpans.length, 1);
    expect(r.oldSpans.first.kind, WordDiffKind.equal);
    expect(r.oldSpans.first.start, 0);
    expect(r.oldSpans.first.end, oldLine.length);

    // The new line: equal head, one diff run (the appended clause), equal tail.
    expect(r.newSpans.length, 3);
    expect(r.newSpans[0].kind, WordDiffKind.equal);
    expect(r.newSpans[1].kind, WordDiffKind.diff);
    expect(r.newSpans[2].kind, WordDiffKind.equal);
    expect(newLine.substring(r.newSpans[0].start, r.newSpans[0].end),
        'case model.FBOParcelStatusOutbound');
    expect(newLine.substring(r.newSpans[1].start, r.newSpans[1].end),
        ', model.FBOParcelStatusInTransit');
    expect(newLine.substring(r.newSpans[2].start, r.newSpans[2].end), ':');

    assertSeamless(r.oldSpans, oldLine.length);
    assertSeamless(r.newSpans, newLine.length);
  });

  test('pure whitespace change only boxes the whitespace', () {
    const oldLine = 'foo  bar'; // two spaces
    const newLine = 'foo bar'; // one space
    final r = diffWords(oldLine, newLine);
    expect(r, isNotNull);

    // Every changed range on both sides is whitespace only; the words stay equal.
    for (final s in r!.oldSpans.where((s) => s.kind == WordDiffKind.diff)) {
      expect(oldLine.substring(s.start, s.end).trim(), isEmpty);
    }
    for (final s in r.newSpans.where((s) => s.kind == WordDiffKind.diff)) {
      expect(newLine.substring(s.start, s.end).trim(), isEmpty);
    }
    // 'foo' and 'bar' are unchanged.
    expect(r.oldSpans.any((s) => s.kind == WordDiffKind.diff), isTrue);
    assertSeamless(r.oldSpans, oldLine.length);
    assertSeamless(r.newSpans, newLine.length);
  });

  test('a single changed identifier highlights as one whole token', () {
    const oldLine = 'final count = getOldValue();';
    const newLine = 'final count = getNewValue();';
    final r = diffWords(oldLine, newLine);
    expect(r, isNotNull);

    // Exactly one diff run per side: the whole identifier swaps, not letters.
    final oldDiffs =
        r!.oldSpans.where((s) => s.kind == WordDiffKind.diff).toList();
    final newDiffs =
        r.newSpans.where((s) => s.kind == WordDiffKind.diff).toList();
    expect(oldDiffs.length, 1);
    expect(newDiffs.length, 1);
    expect(oldLine.substring(oldDiffs.first.start, oldDiffs.first.end),
        'getOldValue');
    expect(newLine.substring(newDiffs.first.start, newDiffs.first.end),
        'getNewValue');
    assertSeamless(r.oldSpans, oldLine.length);
    assertSeamless(r.newSpans, newLine.length);
  });
}
