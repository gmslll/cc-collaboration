import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/src/ui/render.dart';
import 'package:xterm/xterm.dart';

// Regression for the codex/claude "竖排 / 稀疏散落" bug.
//
// A route push/pop animation briefly lays the TerminalView out as a thin sliver
// (full height, ~1 cell wide). render.dart's _updateViewportSize floored
// `size.width ~/ cellSize.width` to 1 and reshaped the buffer to a single
// column; via onResize/adoptSize that pinned the host PTY to 1 col, so the
// agent redrew its whole UI into one column (every glyph on its own line, or a
// few elements scattered down a single column). The render now ignores such
// degenerate transient viewports — orthogonal to the "whoever's watching
// redraws" size negotiation, which only ever deals in real viewport sizes.
//
// This guard was removed in 0.6.14 (regressing the bug) and restored after a
// host PTY was observed pinned at 1x79; keep this test so it can't silently
// disappear again.
void main() {
  testWidgets(
    'a sliver-width layout never collapses the terminal to 1 column',
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
        reason:
            'sliver layout collapsed the terminal to ${term.viewWidth} cols',
      );

      // Returning to a real width still resizes normally.
      await pumpWidth(200);
      expect(term.viewWidth, greaterThan(10));
    },
  );

  testWidgets('terminal geometry glyph fast path paints without crashing', (
    tester,
  ) async {
    final term = Terminal(maxLines: 1000);
    term.write('┌─┬─┐ █▀▄▌▐ ░▒▓ ▖▗▘▙▚▛▜▝▞▟ ⣿⠿⣀\r\n');
    term.write('\x1b[4m└─┴─┘  \x1b[0m underline fallback\r\n');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(width: 500, height: 160, child: TerminalView(term)),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
  });

  testWidgets('terminal render profile is gated by debug flag', (tester) async {
    final term = Terminal(maxLines: 1000);
    term.write('profile test\r\n');

    try {
      RenderTerminal.debugProfilePaint = true;
      RenderTerminal.lastPaintProfile = null;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(width: 500, height: 160, child: TerminalView(term)),
          ),
        ),
      );
      await tester.pump();

      expect(RenderTerminal.lastPaintProfile, isNotNull);

      RenderTerminal.debugProfilePaint = false;
      term.write('next line\r\n');
      await tester.pump();

      expect(RenderTerminal.lastPaintProfile, isNull);
    } finally {
      RenderTerminal.debugProfilePaint = false;
      RenderTerminal.lastPaintProfile = null;
    }
  });
}
