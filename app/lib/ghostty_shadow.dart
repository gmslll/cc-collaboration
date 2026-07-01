import 'dart:convert';
import 'dart:typed_data';

import 'package:libghostty/libghostty.dart' as ghostty;

/// Mirrors PTY output into Ghostty's VT engine without replacing the xterm UI.
///
/// This is intentionally best-effort. The live terminal remains xterm; this
/// shadow is used only for formatted text/ANSI snapshots so we can validate
/// Ghostty against real Claude/Codex streams before considering a renderer swap.
class GhosttyShadowTerminal {
  GhosttyShadowTerminal._(this._terminal, this._cols);

  final ghostty.Terminal _terminal;
  int _cols;
  bool _disposed = false;

  static GhosttyShadowTerminal? create({
    required int cols,
    required int rows,
    int maxScrollback = 10000,
  }) {
    try {
      final safeCols = cols <= 0 ? 80 : cols;
      final safeRows = rows <= 0 ? 24 : rows;
      return GhosttyShadowTerminal._(
        ghostty.Terminal(
          cols: safeCols,
          rows: safeRows,
          maxScrollback: maxScrollback,
        ),
        safeCols,
      );
    } catch (_) {
      return null;
    }
  }

  void writeString(String data) {
    if (_disposed || data.isEmpty) return;
    try {
      _terminal.write(Uint8List.fromList(utf8.encode(data)));
    } catch (_) {
      // Keep shadow failures isolated from the live xterm terminal.
    }
  }

  void resize(int cols, int rows) {
    if (_disposed || cols <= 0 || rows <= 0) return;
    try {
      _terminal.resize(cols: cols, rows: rows);
      _cols = cols;
    } catch (_) {}
  }

  String? plainText({bool trim = true, bool unwrap = false}) {
    return _format(ghostty.FormatterFormat.plain, trim: trim, unwrap: unwrap);
  }

  String? vtText({bool trim = true, bool unwrap = false}) {
    return _format(ghostty.FormatterFormat.vt, trim: trim, unwrap: unwrap);
  }

  String? htmlText({bool trim = true, bool unwrap = false}) {
    return _format(ghostty.FormatterFormat.html, trim: trim, unwrap: unwrap);
  }

  String? plainTail(int rows) => _tail(plainText(), rows);

  String? vtTail(int rows) => _tail(vtText(), rows);

  String? htmlTail(int rows) => _tail(htmlText(), rows);

  String? plainSelection({
    required int startRow,
    required int startCol,
    required int endRow,
    required int endCol,
    bool trim = true,
    bool unwrap = false,
  }) {
    return _formatSelection(
      ghostty.FormatterFormat.plain,
      startRow: startRow,
      startCol: startCol,
      endRow: endRow,
      endCol: endCol,
      trim: trim,
      unwrap: unwrap,
    );
  }

  String? vtSelection({
    required int startRow,
    required int startCol,
    required int endRow,
    required int endCol,
    bool trim = true,
    bool unwrap = false,
  }) {
    return _formatSelection(
      ghostty.FormatterFormat.vt,
      startRow: startRow,
      startCol: startCol,
      endRow: endRow,
      endCol: endCol,
      trim: trim,
      unwrap: unwrap,
    );
  }

  String? htmlSelection({
    required int startRow,
    required int startCol,
    required int endRow,
    required int endCol,
    bool trim = true,
    bool unwrap = false,
  }) {
    return _formatSelection(
      ghostty.FormatterFormat.html,
      startRow: startRow,
      startCol: startCol,
      endRow: endRow,
      endCol: endCol,
      trim: trim,
      unwrap: unwrap,
    );
  }

  GhosttyShadowDigest? digest({int sampleRows = 80}) {
    if (_disposed) return null;
    try {
      final text = plainTail(sampleRows) ?? '';
      return GhosttyShadowDigest(
        cols: _cols,
        totalRows: _terminal.totalRows,
        tailHash: _fnv1a32(text),
        tailLength: text.length,
      );
    } catch (_) {
      return null;
    }
  }

  String? vtTailSelection(int rows) {
    if (_disposed || rows <= 0) return vtText();
    try {
      final totalRows = _terminal.totalRows;
      if (totalRows <= 0) return vtText();
      final endRow = _lastNonBlankScreenRow(totalRows);
      if (endRow == null) return '';
      final startRow = endRow + 1 > rows ? endRow + 1 - rows : 0;
      return _formatSelection(
        ghostty.FormatterFormat.vt,
        startRow: startRow,
        startCol: 0,
        endRow: endRow,
        endCol: _cols - 1,
        trim: true,
        unwrap: false,
      );
    } catch (_) {
      return null;
    }
  }

  int? _lastNonBlankScreenRow(int totalRows) {
    for (var row = totalRows - 1; row >= 0; row--) {
      for (var col = 0; col < _cols; col++) {
        final ref = ghostty.GridRef.at(
          _terminal,
          ghostty.Position(row: row, col: col),
          pointTag: ghostty.PointTag.screen,
        );
        if (ref.content.isNotEmpty) return row;
      }
    }
    return null;
  }

  String? _formatSelection(
    ghostty.FormatterFormat format, {
    required int startRow,
    required int startCol,
    required int endRow,
    required int endCol,
    required bool trim,
    required bool unwrap,
  }) {
    if (_disposed) return null;
    try {
      final totalRows = _terminal.totalRows;
      if (totalRows <= 0 || _cols <= 0) {
        return _format(format, trim: trim, unwrap: unwrap);
      }
      final safeStartRow = startRow.clamp(0, totalRows - 1);
      final safeEndRow = endRow.clamp(0, totalRows - 1);
      final safeStartCol = startCol.clamp(0, _cols - 1);
      final safeEndCol = endCol.clamp(0, _cols - 1);
      final start = ghostty.GridRef.at(
        _terminal,
        ghostty.Position(row: safeStartRow, col: safeStartCol),
        pointTag: ghostty.PointTag.screen,
      );
      final end = ghostty.GridRef.at(
        _terminal,
        ghostty.Position(row: safeEndRow, col: safeEndCol),
        pointTag: ghostty.PointTag.screen,
      );
      final selection = ghostty.Selection.fromRefs(start: start, end: end);
      return _format(format, trim: trim, unwrap: unwrap, selection: selection);
    } catch (_) {
      return null;
    }
  }

  String? _format(
    ghostty.FormatterFormat format, {
    required bool trim,
    required bool unwrap,
    ghostty.Selection? selection,
  }) {
    if (_disposed) return null;
    ghostty.Formatter? formatter;
    try {
      formatter = ghostty.Formatter(
        terminal: _terminal,
        format: format,
        trim: trim,
        unwrap: unwrap,
        selection: selection,
      );
      return formatter.format();
    } catch (_) {
      return null;
    } finally {
      formatter?.dispose();
    }
  }

  static String? _tail(String? text, int rows) {
    if (text == null || rows <= 0) return text;
    final lines = text.split(RegExp(r'\r?\n'));
    if (lines.length <= rows) return text;
    return lines.sublist(lines.length - rows).join('\r\n');
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _terminal.dispose();
  }

  static int _fnv1a32(String text) {
    var hash = 0x811c9dc5;
    for (final unit in text.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash;
  }
}

class GhosttyShadowDigest {
  const GhosttyShadowDigest({
    required this.cols,
    required this.totalRows,
    required this.tailHash,
    required this.tailLength,
  });

  final int cols;
  final int totalRows;
  final int tailHash;
  final int tailLength;
}
