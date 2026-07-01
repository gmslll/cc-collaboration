import 'dart:math' as math;

import 'package:xterm/xterm.dart';

class XtermSnapshotFormatter {
  const XtermSnapshotFormatter(this.terminal);

  final Terminal terminal;

  Buffer get _buffer => terminal.buffer;

  String plain({
    BufferRange? range,
    int? startRow,
    int? endRow,
    bool trimTrailingBlankLines = true,
    String lineEnding = '\n',
  }) {
    final effectiveRange =
        range ?? _rowRange(startRow: startRow, endRow: endRow);
    var text = _buffer.getText(effectiveRange);
    if (trimTrailingBlankLines) {
      text = text.replaceFirst(RegExp(r'\n*$'), '');
    }
    return lineEnding == '\n' ? text : text.split('\n').join(lineEnding);
  }

  String ansi({
    BufferRange? range,
    int? startRow,
    int? endRow,
    bool trimTrailingBlankLines = true,
  }) {
    final effectiveRange =
        range ?? _rowRange(startRow: startRow, endRow: endRow);
    final normalized = effectiveRange.normalized;
    final lastRow = trimTrailingBlankLines
        ? math.min(normalized.end.y, _lastNonBlankRow())
        : math.min(normalized.end.y, _buffer.height - 1);
    if (lastRow < normalized.begin.y) {
      return '\x1b[0m';
    }

    final out = StringBuffer();
    int? previousForeground;
    int? previousBackground;
    int? previousAttributes;
    var wroteAnyRow = false;

    for (final segment in normalized.toSegments()) {
      final row = segment.line;
      if (row < 0 || row >= _buffer.height) {
        continue;
      }
      if (row > lastRow) {
        break;
      }

      final line = _buffer.lines[row];
      if (wroteAnyRow && !line.isWrapped) {
        out.write('\r\n');
      }
      wroteAnyRow = true;

      final start = math.max(segment.start ?? 0, 0);
      final segmentEnd = segment.end ?? terminal.viewWidth;
      final end = math.min(segmentEnd, line.getTrimmedLength());
      if (end <= start) {
        continue;
      }

      for (var col = start; col < end; col++) {
        if (line.getWidth(col) == 0) {
          continue;
        }
        final foreground = line.getForeground(col);
        final background = line.getBackground(col);
        final attributes = line.getAttributes(col);
        if (foreground != previousForeground ||
            background != previousBackground ||
            attributes != previousAttributes) {
          out.write(_sgr(foreground, background, attributes));
          previousForeground = foreground;
          previousBackground = background;
          previousAttributes = attributes;
        }

        final codePoint = line.getCodePoint(col);
        out.writeCharCode(codePoint == 0 ? 0x20 : codePoint);
      }
    }

    out.write('\x1b[0m');
    return out.toString();
  }

  String ansiTail(int rows) {
    final last = _lastNonBlankRow();
    final start = rows <= 0 || last - rows + 1 < 0 ? 0 : last - rows + 1;
    return ansi(startRow: start, endRow: last);
  }

  BufferRangeLine _rowRange({int? startRow, int? endRow}) {
    final maxRow = math.max(_buffer.height - 1, 0);
    final start = (startRow ?? 0).clamp(0, maxRow);
    final end = (endRow ?? maxRow).clamp(0, maxRow);
    return BufferRangeLine(
      CellOffset(0, start),
      CellOffset(terminal.viewWidth, end),
    );
  }

  int _lastNonBlankRow() {
    var row = _buffer.height - 1;
    while (row >= 0 && _buffer.lines[row].getTrimmedLength() == 0) {
      row--;
    }
    return row;
  }

  static String _sgr(int foreground, int background, int attributes) {
    final parts = <String>['0'];
    if ((attributes & CellAttr.bold) != 0) parts.add('1');
    if ((attributes & CellAttr.faint) != 0) parts.add('2');
    if ((attributes & CellAttr.italic) != 0) parts.add('3');
    if ((attributes & CellAttr.underline) != 0) parts.add('4');
    if ((attributes & CellAttr.blink) != 0) parts.add('5');
    if ((attributes & CellAttr.inverse) != 0) parts.add('7');
    if ((attributes & CellAttr.invisible) != 0) parts.add('8');
    if ((attributes & CellAttr.strikethrough) != 0) parts.add('9');
    parts.add(_colorSgr(foreground, foreground: true));
    parts.add(_colorSgr(background, foreground: false));
    return '\x1b[${parts.join(';')}m';
  }

  static String _colorSgr(int color, {required bool foreground}) {
    final value = color & CellColor.valueMask;
    switch (color & CellColor.typeMask) {
      case CellColor.named:
        return '${value < 8 ? (foreground ? 30 : 40) + value : (foreground ? 90 : 100) + (value - 8)}';
      case CellColor.palette:
        return '${foreground ? 38 : 48};5;$value';
      case CellColor.rgb:
        return '${foreground ? 38 : 48};2;'
            '${(value >> 16) & 0xff};${(value >> 8) & 0xff};'
            '${value & 0xff}';
      default:
        return foreground ? '39' : '49';
    }
  }
}
