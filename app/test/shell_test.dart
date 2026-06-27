import 'package:app/local/shell.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // splitPosixCommand is the Windows-path reverse of shQuote: it turns the
  // quoted command strings git.dart builds back into an argv list so git can be
  // run directly (no shell) on Windows. These checks pin the logic on any OS.
  group('splitPosixCommand round-trips shQuote', () {
    const values = <String>[
      'simple',
      'with space',
      "it's tricky", // embedded single quote → shQuote emits `'\''`
      'has "double" quotes',
      'line1\nline2', // commit-message newline
      r'C:\Users\John Doe\repo', // Windows path with a space
      'feat/android-live-activity',
      '', // empty value → exactly one empty arg
      'percent%x1fmarker',
    ];
    for (var i = 0; i < values.length; i++) {
      final v = values[i];
      test('case $i', () => expect(splitPosixCommand(shQuote(v)), [v]));
    }
  });

  group('splitPosixCommand on real git fragments', () {
    test('bare flags split on spaces', () {
      expect(splitPosixCommand('status --porcelain'), ['status', '--porcelain']);
    });

    test('quoted + bare segments concatenate into one word', () {
      // `diff --unified=3 'a'...'b'` → the ref-range stays a single argument.
      expect(
        splitPosixCommand('diff --unified=3 ${shQuote('a')}...${shQuote('b')}'),
        ['diff', '--unified=3', 'a...b'],
      );
    });

    test('double-quoted format spec drops the quotes', () {
      expect(
        splitPosixCommand('branch --format="%(refname:short)"'),
        ['branch', '--format=%(refname:short)'],
      );
    });

    test('multiple shQuoted paths each become one arg', () {
      final files = ['a b.txt', 'c.txt'];
      expect(
        splitPosixCommand('add -- ${files.map(shQuote).join(' ')}'),
        ['add', '--', 'a b.txt', 'c.txt'],
      );
    });
  });
}
