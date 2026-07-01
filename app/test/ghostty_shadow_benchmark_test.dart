import 'package:app/ghostty_shadow.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

const _runBenchmarks = bool.fromEnvironment('RUN_XTERM_BENCHMARKS');

void main() {
  test('xterm and ghostty shadow write benchmarks', () {
    final cases = <_BenchCase>[
      _BenchCase('ascii-lines', _asciiLines(1000)),
      _BenchCase('ansi-lines', _ansiLines(1000)),
      _BenchCase('mixed-lines', _mixedLines(1000)),
    ];

    for (final benchCase in cases) {
      final xterm = _measureXtermWrite(benchCase.payload, iterations: 30);
      final ghostty = _measureGhosttyWrite(benchCase.payload, iterations: 30);
      final ghosttyFormat = _measureGhosttyFormat(
        benchCase.payload,
        iterations: 30,
      );

      // ignore: avoid_print
      print(
        '[ghostty-shadow-bench] ${benchCase.name} '
        'bytes=${benchCase.payload.length} '
        'xtermWriteUs=${xterm.averageMicroseconds.toStringAsFixed(1)} '
        'ghosttyWriteUs=${ghostty.averageMicroseconds.toStringAsFixed(1)} '
        'ghosttyPlainFormatUs='
        '${ghosttyFormat.averageMicroseconds.toStringAsFixed(1)}',
      );
    }
  }, skip: !_runBenchmarks);
}

class _BenchCase {
  const _BenchCase(this.name, this.payload);

  final String name;
  final String payload;
}

class _BenchResult {
  const _BenchResult(this.elapsed, this.iterations);

  final Duration elapsed;
  final int iterations;

  double get averageMicroseconds => elapsed.inMicroseconds / iterations;
}

_BenchResult _measureXtermWrite(String payload, {required int iterations}) {
  for (var i = 0; i < 3; i++) {
    Terminal(maxLines: 2000).write(payload);
  }

  final watch = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    Terminal(maxLines: 2000).write(payload);
  }
  watch.stop();
  return _BenchResult(watch.elapsed, iterations);
}

_BenchResult _measureGhosttyWrite(String payload, {required int iterations}) {
  for (var i = 0; i < 3; i++) {
    final shadow = GhosttyShadowTerminal.create(cols: 100, rows: 30);
    shadow?.writeString(payload);
    shadow?.dispose();
  }

  final watch = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    final shadow = GhosttyShadowTerminal.create(cols: 100, rows: 30);
    shadow?.writeString(payload);
    shadow?.dispose();
  }
  watch.stop();
  return _BenchResult(watch.elapsed, iterations);
}

_BenchResult _measureGhosttyFormat(String payload, {required int iterations}) {
  final shadow = GhosttyShadowTerminal.create(cols: 100, rows: 30);
  if (shadow == null) {
    return _BenchResult(Duration.zero, iterations);
  }
  addTearDown(shadow.dispose);
  shadow.writeString(payload);

  for (var i = 0; i < 3; i++) {
    shadow.plainText();
  }

  final watch = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    shadow.plainText();
  }
  watch.stop();
  return _BenchResult(watch.elapsed, iterations);
}

String _asciiLines(int count) {
  final buffer = StringBuffer();
  for (var i = 0; i < count; i++) {
    buffer.writeln('line $i abcdefghijklmnopqrstuvwxyz 0123456789');
  }
  return buffer.toString();
}

String _ansiLines(int count) {
  final buffer = StringBuffer();
  const colors = [31, 32, 33, 34, 35, 36];
  for (var i = 0; i < count; i++) {
    final color = colors[i % colors.length];
    buffer.write('\x1b[${color}mline $i colored output\x1b[0m\r\n');
  }
  return buffer.toString();
}

String _mixedLines(int count) {
  final buffer = StringBuffer();
  for (var i = 0; i < count; i++) {
    buffer.write('│ row $i │ alpha βeta 中文 😀 ');
    buffer.write(i.isEven ? '\x1b[42mgreen\x1b[0m' : '\x1b[44mblue\x1b[0m');
    buffer.write(' │\r\n');
  }
  return buffer.toString();
}
