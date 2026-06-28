import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

// Regression for the codex "doesn't scroll, just overwrites the last line" bug.
//
// codex renders its transcript in the MAIN buffer and sets a scroll region that
// reserves the bottom rows for its composer (e.g. `ESC[1;5r`), then linefeeds at
// the region's bottom margin. The old index() grew scrollback (lines.insert
// below the margin) whenever marginTop==0 — which, once scrollback exists,
// inserts at a non-end index of the circular buffer (assert/throw in debug,
// silent corruption in release) and pins output to the last line. A region with
// a real bottom margin must scroll IN PLACE.
//
// The fixture is a real codex-cli 0.142.2 byte stream (80x10) that triggers it;
// before the fix, feeding it throws. We assert it feeds cleanly.
void main() {
  test('real codex stream with a bottom-margin scroll region feeds cleanly', () {
    final bytes =
        File('test/fixtures/codex_scroll_region.bin').readAsBytesSync();
    final t = Terminal(maxLines: 1000);
    t.resize(80, 10);
    expect(
      () => t.write(utf8.decode(bytes, allowMalformed: true)),
      returnsNormally,
    );
    // Buffer stays well-formed (never fewer than the viewport's worth of lines).
    expect(t.buffer.height, greaterThanOrEqualTo(t.viewHeight));
  });

  test('scroll region with a reserved bottom row scrolls in place', () {
    String visible(Terminal t, int row) {
      final b = t.buffer;
      return b.lines[b.height - t.viewHeight + row].getText().trimRight();
    }

    final t = Terminal(maxLines: 1000);
    t.resize(40, 6);
    for (var i = 0; i < 12; i++) {
      t.write('pre$i\r\n');
    }
    t.write('\x1b[6;1HKEEP'); // composer marker on the reserved bottom row
    t.write('\x1b[1;4r'); // scroll region = rows 1..4 (reserve rows 5-6)
    t.write('\x1b[1;1H');
    for (var i = 0; i < 20; i++) {
      t.write('L$i\r\n');
    }
    expect(visible(t, 5), 'KEEP'); // composer survived
    expect(visible(t, 0), isNot('L0')); // region actually scrolled
  });
}
