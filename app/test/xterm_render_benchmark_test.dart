import 'dart:ui' show Canvas, Offset, PictureRecorder;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/src/ui/painter.dart';
import 'package:xterm/src/ui/render.dart';
import 'package:xterm/xterm.dart';

const _runBenchmarks = bool.fromEnvironment('RUN_XTERM_BENCHMARKS');

void main() {
  test('terminal painter microbenchmarks', () {
    final cases = <_PainterCase>[
      _PainterCase('ascii-600', _lineWithRepeated('a', 600)),
      _PainterCase('latin1-600', _lineWithRepeated('é', 600)),
      _PainterCase('geometry-600', _lineWithRepeated('─', 600)),
      _PainterCase('mixed-600', _mixedLine(600)),
    ];

    for (final benchCase in cases) {
      final painter = TerminalPainter(
        theme: TerminalThemes.defaultTheme,
        textStyle: const TerminalStyle(),
        textScaler: TextScaler.noScaling,
      );
      final noProfile = _measurePainter(
        painter,
        benchCase.line,
        iterations: 800,
        collectProfile: false,
      );
      final withProfile = _measurePainter(
        painter,
        benchCase.line,
        iterations: 80,
        collectProfile: true,
      );

      // ignore: avoid_print
      print(
        '[xterm-bench:painter] ${benchCase.name} '
        'avgNoProfileUs=${noProfile.averageMicroseconds.toStringAsFixed(1)} '
        'avgProfileUs=${withProfile.averageMicroseconds.toStringAsFixed(1)} '
        '${_painterProfileSummary(withProfile.profile)}',
      );
    }
  }, skip: !_runBenchmarks);

  testWidgets('terminal render overlay/cache benchmarks', (tester) async {
    final terminal = Terminal(maxLines: 2000);
    final controller = TerminalController(
      pointerInputs: const PointerInputs.none(),
    );
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);
    addTearDown(() {
      RenderTerminal.debugProfilePaint = false;
      RenderTerminal.lastPaintProfile = null;
    });

    for (var i = 0; i < 240; i++) {
      terminal.write('line $i abcdefghijklmnopqrstuvwxyz 0123456789\r\n');
    }

    RenderTerminal.debugProfilePaint = true;
    RenderTerminal.lastPaintProfile = null;
    Future<void> pumpTerminal({TerminalCursorType? cursorType}) {
      return tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 720,
              height: 360,
              child: TerminalView(
                terminal,
                controller: controller,
                focusNode: focusNode,
                cursorType: cursorType ?? TerminalCursorType.block,
              ),
            ),
          ),
        ),
      );
    }

    await pumpTerminal();
    await tester.pump();
    final initial = RenderTerminal.lastPaintProfile;

    final selectionTime = await _measureAsync(
      iterations: 120,
      body: () async {
        controller.setSelection(
          terminal.buffer.createAnchorFromOffset(const CellOffset(0, 220)),
          terminal.buffer.createAnchorFromOffset(const CellOffset(20, 220)),
        );
        await tester.pump();
        controller.clearSelection();
        await tester.pump();
      },
    );
    final selectionProfile = RenderTerminal.lastPaintProfile;

    var cursorUnderline = false;
    final cursorTime = await _measureAsync(
      iterations: 160,
      body: () async {
        cursorUnderline = !cursorUnderline;
        await pumpTerminal(
          cursorType: cursorUnderline
              ? TerminalCursorType.underline
              : TerminalCursorType.block,
        );
        await tester.pump();
      },
    );
    final cursorProfile = RenderTerminal.lastPaintProfile;

    // ignore: avoid_print
    print(
      '[xterm-bench:render] initial=$initial '
      'selectionToggleAvgUs=${selectionTime.averageMicroseconds.toStringAsFixed(1)} '
      'selectionLast=$selectionProfile '
      'cursorAvgUs=${cursorTime.averageMicroseconds.toStringAsFixed(1)} '
      'cursorLast=$cursorProfile',
    );
  }, skip: !_runBenchmarks);
}

class _PainterCase {
  const _PainterCase(this.name, this.line);

  final String name;
  final BufferLine line;
}

class _BenchResult {
  const _BenchResult(this.elapsed, this.iterations, this.profile);

  final Duration elapsed;
  final int iterations;
  final TerminalPainterProfile? profile;

  double get averageMicroseconds => elapsed.inMicroseconds / iterations;
}

String _painterProfileSummary(TerminalPainterProfile? profile) {
  if (profile == null) {
    return 'profile=null';
  }
  return 'renderPlanHits=${profile.renderPlanCacheHits} '
      'renderPlanMisses=${profile.renderPlanCacheMisses} '
      'asciiRuns=${profile.asciiRuns} '
      'asciiFallbacks=${profile.asciiRunFallbacks} '
      'glyphHits=${profile.glyphPictureCacheHits} '
      'glyphMisses=${profile.glyphPictureCacheMisses} '
      'glyphRunHits=${profile.glyphRunPictureCacheHits} '
      'glyphRunMisses=${profile.glyphRunPictureCacheMisses} '
      'glyphAtlasHits=${profile.glyphAtlasHits} '
      'glyphAtlasMisses=${profile.glyphAtlasMisses} '
      'glyphAtlasDraws=${profile.glyphAtlasDraws} '
      'glyphAtlasRunDraws=${profile.glyphAtlasRunDraws} '
      'runParagraphHits=${profile.runParagraphCacheHits} '
      'runParagraphMisses=${profile.runParagraphCacheMisses} '
      'paragraphHits=${profile.paragraphCacheHits} '
      'paragraphMisses=${profile.paragraphCacheMisses} '
      'singleCells=${profile.singleCells}';
}

BufferLine _lineWithRepeated(String char, int length) {
  final line = BufferLine(length);
  final style = CursorStyle();
  final codePoint = char.runes.first;
  for (var i = 0; i < length; i++) {
    line.setCell(i, codePoint, 1, style);
  }
  return line;
}

BufferLine _mixedLine(int length) {
  final line = BufferLine(length);
  final style = CursorStyle();
  const pattern = ['a', 'b', 'é', '─', 'x', 'y', 'z', ' '];
  for (var i = 0; i < length; i++) {
    final codePoint = pattern[i % pattern.length].runes.first;
    line.setCell(i, codePoint, 1, style);
  }
  return line;
}

_BenchResult _measurePainter(
  TerminalPainter painter,
  BufferLine line, {
  required int iterations,
  required bool collectProfile,
}) {
  for (var i = 0; i < 20; i++) {
    _paintLine(painter, line, collectProfile: false);
  }

  TerminalPainterProfile? profile;
  final watch = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    _paintLine(painter, line, collectProfile: collectProfile);
    if (collectProfile) {
      profile = painter.takeProfile();
    }
  }
  watch.stop();
  return _BenchResult(watch.elapsed, iterations, profile);
}

void _paintLine(
  TerminalPainter painter,
  BufferLine line, {
  required bool collectProfile,
}) {
  final recorder = PictureRecorder();
  final canvas = Canvas(recorder);
  painter.paintLine(canvas, Offset.zero, line, collectProfile: collectProfile);
  recorder.endRecording().dispose();
}

Future<_BenchResult> _measureAsync({
  required int iterations,
  required Future<void> Function() body,
}) async {
  final watch = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    await body();
  }
  watch.stop();
  return _BenchResult(watch.elapsed, iterations, null);
}
