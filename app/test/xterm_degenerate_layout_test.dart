import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

// Regression for the codex "竖排" (one glyph per line) bug.
//
// During a route push/pop animation the TerminalView's render box is briefly a
// thin sliver — full height, ~1 cell wide. render.dart's _updateViewportSize
// floored `size.width ~/ cellSize.width` to 1 and reshaped the buffer to a
// single column. Every glyph then wraps onto its own line, and codex (whose
// transcript lives in the MAIN buffer, so the phone scrolls a local copy) has
// no way to redraw out of it — the collapsed history just stays, and scrolling
// only reveals more single-column rows. The render now ignores such degenerate
// transient layouts. Since the host PTY and the phone→host resize all flow from
// this resize, guarding here protects every path at once.
void main() {
  testWidgets('a sliver-width layout never collapses the terminal to 1 column',
      (tester) async {
    final term = Terminal(maxLines: 1000);

    Future<void> pumpWidth(double width) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: width,
                height: 400,
                child: TerminalView(term),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    // A normal full-width layout sizes the terminal to many columns.
    await pumpWidth(400);
    final cols = term.viewWidth;
    expect(cols, greaterThan(10));

    // A transient sliver (≈1 cell wide, full height) must NOT reshape the
    // buffer to a single column — the terminal keeps its last sane width.
    await pumpWidth(6);
    expect(
      term.viewWidth,
      cols,
      reason: 'sliver layout collapsed the terminal to ${term.viewWidth} cols',
    );

    // Returning to a real width still resizes normally.
    await pumpWidth(200);
    expect(term.viewWidth, greaterThan(10));
  });
}
