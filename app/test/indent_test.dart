import 'package:app/syntax.dart';
import 'package:flutter_test/flutter_test.dart';

// expandLeadingTabs makes tab-indented code render with visible indentation
// (dart:ui renders a raw \t at zero width); collapseLeadingIndent is its save-side
// inverse so a tab-indented file keeps its indentation style after an edit.
void main() {
  group('expandLeadingTabs', () {
    test('expands leading tabs to width spaces, one level per tab', () {
      expect(expandLeadingTabs('\tx', width: 4), '    x');
      expect(expandLeadingTabs('\t\tx', width: 4), '        x');
      expect(expandLeadingTabs('\tx', width: 2), '  x');
    });

    test('leaves in-line (non-leading) tabs untouched', () {
      expect(expandLeadingTabs('\ta\tb', width: 4), '    a\tb');
      expect(expandLeadingTabs('a\tb', width: 4), 'a\tb');
    });

    test('is a no-op when there are no tabs', () {
      const s = '  already spaced\nplain';
      expect(expandLeadingTabs(s), same(s));
    });

    test('handles every line independently', () {
      expect(
        expandLeadingTabs('func f() {\n\tx := 1\n\t\treturn\n}', width: 4),
        'func f() {\n    x := 1\n        return\n}',
      );
    });
  });

  group('collapseLeadingIndent', () {
    test('folds each width-run of leading spaces back into a tab', () {
      expect(collapseLeadingIndent('    x', width: 4), '\tx');
      expect(collapseLeadingIndent('        x', width: 4), '\t\tx');
    });

    test('keeps the sub-tab remainder as spaces (tab-then-align)', () {
      expect(collapseLeadingIndent('      x', width: 4), '\t  x');
    });

    test('leaves lines indented less than one tab alone', () {
      expect(collapseLeadingIndent('  x', width: 4), '  x');
    });
  });

  test('round-trips tab-indented content losslessly', () {
    const go =
        'package main\n\nfunc f() {\n\tif x {\n\t\treturn\n\t}\n\ty := "\\t"\n}\n';
    expect(collapseLeadingIndent(expandLeadingTabs(go)), go);
  });
}
