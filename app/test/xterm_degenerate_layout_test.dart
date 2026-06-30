import 'dart:ui' show PictureRecorder;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/src/ui/painter.dart';
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
    term.write('┌─┬─┐ ╔═╦═╗ ╭─╮ ┄┆ █▀▄▌▐ ░▒▓ ▖▗▘▙▚▛▜▝▞▟ ⣿⠿⣀ \r\n');
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

  test('buffer line revision tracks paint-affecting mutations', () {
    final line = BufferLine(8);
    final style = CursorStyle();
    final initial = line.revision;

    line.setCell(0, 'A'.codeUnitAt(0), 1, style);
    expect(line.revision, greaterThan(initial));
    final afterCell = line.revision;

    line.isWrapped = true;
    expect(line.revision, greaterThan(afterCell));
    final afterWrap = line.revision;

    line.eraseRange(0, 1, style);
    expect(line.revision, greaterThan(afterWrap));
    final afterErase = line.revision;

    line.resize(12);
    expect(line.revision, greaterThan(afterErase));
  });

  test('terminal painter render plan cache follows line revision', () {
    final painter = TerminalPainter(
      theme: TerminalThemes.defaultTheme,
      textStyle: const TerminalStyle(),
      textScaler: TextScaler.noScaling,
    );
    final line = BufferLine(16);
    final style = CursorStyle();
    for (var i = 0; i < 12; i++) {
      line.setCell(i, 'a'.codeUnitAt(0) + i, 1, style);
    }

    TerminalPainterProfile paint() {
      final recorder = PictureRecorder();
      final canvas = Canvas(recorder);
      painter.paintLine(canvas, Offset.zero, line, collectProfile: true);
      recorder.endRecording().dispose();
      return painter.takeProfile()!;
    }

    expect(paint().renderPlanCacheMisses, 1);
    expect(paint().renderPlanCacheHits, 1);

    line.setCell(0, 'Z'.codeUnitAt(0), 1, style);
    final afterMutation = paint();
    expect(afterMutation.renderPlanCacheMisses, 1);
    expect(afterMutation.renderPlanCacheHits, 0);
  });

  test('terminal painter render plan cache is bounded', () {
    final painter = TerminalPainter(
      theme: TerminalThemes.defaultTheme,
      textStyle: const TerminalStyle(),
      textScaler: TextScaler.noScaling,
    );
    final style = CursorStyle();

    TerminalPainterProfile paint(BufferLine line) {
      final recorder = PictureRecorder();
      final canvas = Canvas(recorder);
      painter.paintLine(canvas, Offset.zero, line, collectProfile: true);
      recorder.endRecording().dispose();
      return painter.takeProfile()!;
    }

    final firstLine = BufferLine(8)..setCell(0, 'A'.codeUnitAt(0), 1, style);
    paint(firstLine);

    for (var i = 0; i < 520; i++) {
      final line = BufferLine(8)..setCell(0, 'B'.codeUnitAt(0), 1, style);
      paint(line);
    }

    final firstLineAgain = paint(firstLine);
    expect(firstLineAgain.renderPlanCacheMisses, 1);
    expect(firstLineAgain.renderPlanCacheHits, 0);
  });

  test('terminal painter chunks long ascii runs', () {
    final painter = TerminalPainter(
      theme: TerminalThemes.defaultTheme,
      textStyle: const TerminalStyle(),
      textScaler: TextScaler.noScaling,
    );
    final line = BufferLine(600);
    final style = CursorStyle();
    for (var i = 0; i < line.length; i++) {
      line.setCell(i, 'a'.codeUnitAt(0), 1, style);
    }

    final recorder = PictureRecorder();
    final canvas = Canvas(recorder);
    painter.paintLine(canvas, Offset.zero, line, collectProfile: true);
    recorder.endRecording().dispose();
    final profile = painter.takeProfile()!;

    expect(profile.asciiRuns, 3);
    expect(profile.runParagraphCacheMisses, 2);
    expect(profile.runParagraphCacheHits, 1);
  });

  test('terminal painter merges tiny text run chunk tails', () {
    final painter = TerminalPainter(
      theme: TerminalThemes.defaultTheme,
      textStyle: const TerminalStyle(),
      textScaler: TextScaler.noScaling,
    );
    final line = BufferLine(258);
    final style = CursorStyle();
    for (var i = 0; i < line.length; i++) {
      line.setCell(i, 'a'.codeUnitAt(0), 1, style);
    }

    final recorder = PictureRecorder();
    final canvas = Canvas(recorder);
    painter.paintLine(canvas, Offset.zero, line, collectProfile: true);
    recorder.endRecording().dispose();
    final profile = painter.takeProfile()!;

    expect(profile.asciiRuns, 1);
    expect(profile.singleCells, 0);
  });

  test('terminal painter batches safe non-ascii text runs', () {
    final painter = TerminalPainter(
      theme: TerminalThemes.defaultTheme,
      textStyle: const TerminalStyle(),
      textScaler: TextScaler.noScaling,
    );
    final line = BufferLine(12);
    final style = CursorStyle();
    for (var i = 0; i < 10; i++) {
      line.setCell(i, 'é'.codeUnitAt(0), 1, style);
    }

    final recorder = PictureRecorder();
    final canvas = Canvas(recorder);
    painter.paintLine(canvas, Offset.zero, line, collectProfile: true);
    recorder.endRecording().dispose();
    final profile = painter.takeProfile()!;

    expect(profile.runParagraphCacheMisses, 1);
    expect(profile.asciiRuns + profile.asciiRunFallbacks, 1);
  });

  test('terminal painter geometry glyph runs use the sprite atlas', () {
    final painter = TerminalPainter(
      theme: TerminalThemes.defaultTheme,
      textStyle: const TerminalStyle(),
      textScaler: TextScaler.noScaling,
    );

    TerminalPainterProfile paint(BufferLine line) {
      final recorder = PictureRecorder();
      final canvas = Canvas(recorder);
      painter.paintLine(canvas, Offset.zero, line, collectProfile: true);
      recorder.endRecording().dispose();
      return painter.takeProfile()!;
    }

    BufferLine glyphLine(int colorSeed) {
      final style = CursorStyle()
        ..setForegroundColorRgb(
          colorSeed & 0xFF,
          (colorSeed >> 8) & 0xFF,
          (colorSeed >> 16) & 0xFF,
        );
      return BufferLine(4)
        ..setCell(0, '┌'.codeUnitAt(0), 1, style)
        ..setCell(1, '─'.codeUnitAt(0), 1, style)
        ..setCell(2, '─'.codeUnitAt(0), 1, style)
        ..setCell(3, '┐'.codeUnitAt(0), 1, style);
    }

    final firstLine = glyphLine(1);
    final firstPaint = paint(firstLine);
    expect(firstPaint.glyphAtlasRunDraws, 1);
    expect(firstPaint.glyphAtlasMisses, 3);
    expect(firstPaint.glyphAtlasHits, 1);
    expect(firstPaint.glyphRunPictureCacheMisses, 0);

    final secondPaint = paint(firstLine);
    expect(secondPaint.glyphAtlasRunDraws, 1);
    expect(secondPaint.glyphAtlasHits, 4);
    expect(secondPaint.glyphRunPictureCacheHits, 0);
  });

  test('unsupported box glyphs stay on text fallback instead of atlas', () {
    final painter = TerminalPainter(
      theme: TerminalThemes.defaultTheme,
      textStyle: const TerminalStyle(),
      textScaler: TextScaler.noScaling,
    );
    final line = BufferLine(4);
    final style = CursorStyle();
    for (var i = 0; i < line.length; i++) {
      line.setCell(i, 0x2571, 1, style); // diagonal box drawing, not sprited
    }

    final recorder = PictureRecorder();
    final canvas = Canvas(recorder);
    painter.paintLine(canvas, Offset.zero, line, collectProfile: true);
    recorder.endRecording().dispose();
    final profile = painter.takeProfile()!;

    expect(profile.glyphAtlasMisses, 0);
    expect(profile.glyphAtlasDraws, 0);
    expect(profile.glyphAtlasRunDraws, 0);
    expect(profile.glyphRunPictureCacheMisses, 0);
  });

  test('emoji and wide glyphs stay on paragraph fallback instead of atlas', () {
    final painter = TerminalPainter(
      theme: TerminalThemes.defaultTheme,
      textStyle: const TerminalStyle(),
      textScaler: TextScaler.noScaling,
    );
    final line = BufferLine(2);
    final style = CursorStyle();
    line
      ..setCell(0, 0x1F600, 2, style)
      ..eraseCell(1, style);

    final recorder = PictureRecorder();
    final canvas = Canvas(recorder);
    painter.paintLine(canvas, Offset.zero, line, collectProfile: true);
    recorder.endRecording().dispose();
    final profile = painter.takeProfile()!;

    expect(profile.emojiFallbackCells, 1);
    expect(profile.wideGlyphFallbackCells, 1);
    expect(profile.glyphAtlasMisses, 0);
    expect(profile.glyphAtlasDraws, 0);
  });

  testWidgets('terminal render profile is gated by debug flag', (tester) async {
    final term = Terminal(maxLines: 1000);
    final controller = TerminalController();
    final focusNode = FocusNode();
    term.write('profile test\r\n');

    try {
      RenderTerminal.debugProfilePaint = true;
      RenderTerminal.lastPaintProfile = null;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 500,
              height: 160,
              child: TerminalView(
                term,
                controller: controller,
                focusNode: focusNode,
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(RenderTerminal.lastPaintProfile, isNotNull);
      expect(
        RenderTerminal.lastPaintProfile!.paintReason,
        TerminalPaintReason.initial,
      );
      expect(
        RenderTerminal.lastPaintProfile!.renderCommandParagraphDraws,
        isPositive,
      );
      expect(
        RenderTerminal.lastPaintProfile!.viewportContentCacheMisses,
        isPositive,
      );
      expect(
        RenderTerminal.lastPaintProfile!.runParagraphCacheMisses,
        isPositive,
      );
      expect(RenderTerminal.lastPaintProfile!.cursorPaints, isPositive);

      controller.setSelection(
        term.buffer.createAnchorFromOffset(const CellOffset(0, 0)),
        term.buffer.createAnchorFromOffset(const CellOffset(4, 0)),
      );
      await tester.pump();

      expect(
        RenderTerminal.lastPaintProfile!.paintReason,
        TerminalPaintReason.controller,
      );
      expect(
        RenderTerminal.lastPaintProfile!.viewportContentCacheHits,
        isPositive,
      );
      expect(RenderTerminal.lastPaintProfile!.lineSignatureChecks, isZero);
      expect(RenderTerminal.lastPaintProfile!.overlayAnyDirty, isTrue);
      expect(RenderTerminal.lastPaintProfile!.overlayDirtyRows, isPositive);
      expect(RenderTerminal.lastPaintProfile!.overlayRowCacheHits, isPositive);
      expect(RenderTerminal.lastPaintProfile!.overlayRowCacheMisses, isZero);
      expect(
        RenderTerminal.lastPaintProfile!.overlayRowPictureDraws,
        isPositive,
      );
      expect(RenderTerminal.lastPaintProfile!.renderCommandBuffers, isPositive);
      expect(
        RenderTerminal.lastPaintProfile!.renderCommandPictureDraws,
        isPositive,
      );
      expect(
        RenderTerminal.lastPaintProfile!.renderCommandRectDraws,
        isPositive,
      );
      expect(RenderTerminal.lastPaintProfile!.contentPicturesDrawn, isZero);
      expect(
        RenderTerminal.lastPaintProfile!.overlayRowSignatureSkips,
        isPositive,
      );
      expect(RenderTerminal.lastPaintProfile!.selectionRuns, isPositive);

      controller.clearSelection();
      await tester.pump();

      expect(
        RenderTerminal.lastPaintProfile!.paintReason,
        TerminalPaintReason.controller,
      );
      expect(RenderTerminal.lastPaintProfile!.overlayAnyDirty, isTrue);
      expect(RenderTerminal.lastPaintProfile!.overlayDirtyRows, isPositive);
      expect(RenderTerminal.lastPaintProfile!.overlayRowCacheMisses, isZero);
      expect(RenderTerminal.lastPaintProfile!.selectionRuns, isZero);

      term.write('terminal direct draw\r\n');
      await tester.pump();

      expect(
        RenderTerminal.lastPaintProfile!.paintReason,
        TerminalPaintReason.terminal,
      );
      expect(
        RenderTerminal.lastPaintProfile!.viewportContentDirectDraws,
        isPositive,
      );
      expect(RenderTerminal.lastPaintProfile!.viewportContentPictureDraws, 0);
      expect(RenderTerminal.lastPaintProfile!.viewportContentCacheMisses, 0);
      expect(RenderTerminal.lastPaintProfile!.lineSignatureChecks, isPositive);
      expect(RenderTerminal.lastPaintProfile!.renderCommandBuffers, isPositive);
      expect(RenderTerminal.lastPaintProfile!.renderCommands, isPositive);
      expect(
        RenderTerminal.lastPaintProfile!.renderCommandPictureDraws,
        isPositive,
      );
      expect(
        RenderTerminal.lastPaintProfile!.renderCommandParagraphDraws,
        isPositive,
      );

      term.write('\x1b[41mbackground rect command\x1b[0m\r\n');
      await tester.pump();

      expect(
        RenderTerminal.lastPaintProfile!.paintReason,
        TerminalPaintReason.terminal,
      );
      expect(
        RenderTerminal.lastPaintProfile!.renderCommandRectDraws,
        isPositive,
      );
      expect(RenderTerminal.lastPaintProfile!.backgroundRuns, isPositive);

      term.buffer.lines[0].setCell(0, 'X'.codeUnitAt(0), 1, CursorStyle());
      final renderTerminal = tester.renderObject<RenderTerminal>(
        find.byWidgetPredicate(
          (widget) => widget.runtimeType.toString() == '_TerminalView',
        ),
      );
      renderTerminal.markNeedsPaint();
      await tester.pump();

      expect(
        RenderTerminal.lastPaintProfile!.paintReason,
        TerminalPaintReason.unknown,
      );
      expect(
        RenderTerminal.lastPaintProfile!.viewportContentCacheMisses,
        isPositive,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 500,
              height: 160,
              child: TerminalView(
                term,
                controller: controller,
                focusNode: focusNode,
                cursorType: TerminalCursorType.underline,
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(
        RenderTerminal.lastPaintProfile!.paintReason,
        TerminalPaintReason.cursor,
      );
      expect(RenderTerminal.lastPaintProfile!.overlayAnyDirty, isTrue);
      expect(RenderTerminal.lastPaintProfile!.overlayDirtyRows, 1);
      expect(RenderTerminal.lastPaintProfile!.overlayRowCacheHits, isPositive);
      expect(
        RenderTerminal.lastPaintProfile!.overlayRowCacheMisses,
        isPositive,
      );
      expect(
        RenderTerminal.lastPaintProfile!.overlayRowSignatureSkips,
        isPositive,
      );
      expect(RenderTerminal.lastPaintProfile!.cursorPaints, isPositive);

      RenderTerminal.debugProfilePaint = false;
      term.write('next line\r\n');
      await tester.pump();

      expect(RenderTerminal.lastPaintProfile, isNull);
    } finally {
      RenderTerminal.debugProfilePaint = false;
      RenderTerminal.lastPaintProfile = null;
      controller.dispose();
      focusNode.dispose();
    }
  });
}
