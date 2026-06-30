// ignore_for_file: prefer_collection_literals

import 'dart:collection';
import 'dart:ui';
import 'package:flutter/painting.dart';

import 'package:xterm/src/ui/palette_builder.dart';
import 'package:xterm/src/ui/paragraph_cache.dart';
import 'package:xterm/xterm.dart';

/// Encapsulates the logic for painting various terminal elements.
class TerminalPainter {
  static const _maxLineRenderPlans = 512;
  static const _maxGlyphPictures = 2048;
  static const _maxGlyphRunPictures = 512;
  static const _maxTextRunChunkCells = 256;
  static const _minGeometryGlyphRunLength = 4;
  static const _textRunFontFeatures = [
    FontFeature.disable('liga'),
    FontFeature.disable('clig'),
    FontFeature.disable('calt'),
  ];
  static const _minTextRunLength = 4;

  TerminalPainter({
    required TerminalTheme theme,
    required TerminalStyle textStyle,
    required TextScaler textScaler,
  })  : _textStyle = textStyle,
        _theme = theme,
        _textScaler = textScaler;

  /// A lookup table from terminal colors to Flutter colors.
  late var _colorPalette = PaletteBuilder(_theme).build();

  /// Size of each character in the terminal.
  late var _cellSize = _measureCharSize();

  /// The cached for cells in the terminal. Should be cleared when the same
  /// cell no longer produces the same visual output. For example, when
  /// [_textStyle] is changed, or when the system font changes.
  final _paragraphCache = ParagraphCache(10240);
  final _runParagraphCache = ParagraphCache(2048);
  // Keep insertion order so the oldest render plan can be evicted.
  final _lineRenderPlanCache =
      LinkedHashMap<BufferLine, _LineRenderPlanCache>();
  // Keep insertion order so the oldest geometry glyph can be evicted.
  final _glyphPictureCache = LinkedHashMap<_GlyphPictureKey, Picture>();
  final _glyphRunPictureCache = LinkedHashMap<_GlyphRunPictureKey, Picture>();
  final _cursorPaint = Paint();
  final _highlightPaint = Paint();
  final _backgroundPaint = Paint();
  final _glyphFillPaint = Paint();
  final _glyphStrokePaint = Paint();
  var _paintRevision = 0;

  TerminalStyle get textStyle => _textStyle;
  TerminalStyle _textStyle;
  set textStyle(TerminalStyle value) {
    if (value == _textStyle) return;
    _textStyle = value;
    _cellSize = _measureCharSize();
    _paragraphCache.clear();
    _runParagraphCache.clear();
    _lineRenderPlanCache.clear();
    _clearGlyphPictureCache();
    _clearGlyphRunPictureCache();
    _paintRevision++;
  }

  TextScaler get textScaler => _textScaler;
  TextScaler _textScaler = TextScaler.linear(1.0);
  set textScaler(TextScaler value) {
    if (value == _textScaler) return;
    _textScaler = value;
    _cellSize = _measureCharSize();
    _paragraphCache.clear();
    _runParagraphCache.clear();
    _lineRenderPlanCache.clear();
    _clearGlyphPictureCache();
    _clearGlyphRunPictureCache();
    _paintRevision++;
  }

  TerminalTheme get theme => _theme;
  TerminalTheme _theme;
  set theme(TerminalTheme value) {
    if (value == _theme) return;
    _theme = value;
    _colorPalette = PaletteBuilder(value).build();
    _paragraphCache.clear();
    _runParagraphCache.clear();
    _lineRenderPlanCache.clear();
    _clearGlyphPictureCache();
    _clearGlyphRunPictureCache();
    _paintRevision++;
  }

  Size _measureCharSize() {
    const test = 'mmmmmmmmmm';

    final textStyle = _textStyle.toTextStyle();
    final builder = ParagraphBuilder(textStyle.getParagraphStyle());
    builder.pushStyle(
      textStyle.getTextStyle(textScaler: _textScaler),
    );
    builder.addText(test);

    final paragraph = builder.build();
    paragraph.layout(ParagraphConstraints(width: double.infinity));

    final result = Size(
      paragraph.maxIntrinsicWidth / test.length,
      paragraph.height,
    );

    paragraph.dispose();
    return result;
  }

  /// The size of each character in the terminal.
  Size get cellSize => _cellSize;

  int get paintRevision => _paintRevision;

  TerminalPainterProfile? takeProfile() {
    final profile = _profile;
    _profile = null;
    return profile;
  }

  TerminalPainterProfile? _profile;

  void dispose() {
    _paragraphCache.clear();
    _runParagraphCache.clear();
    _lineRenderPlanCache.clear();
    _clearGlyphPictureCache();
    _clearGlyphRunPictureCache();
  }

  /// When the set of font available to the system changes, call this method to
  /// clear cached state related to font rendering.
  void clearFontCache() {
    _cellSize = _measureCharSize();
    _paragraphCache.clear();
    _runParagraphCache.clear();
    _lineRenderPlanCache.clear();
    _clearGlyphPictureCache();
    _clearGlyphRunPictureCache();
    _paintRevision++;
  }

  /// Paints the cursor based on the current cursor type.
  void paintCursor(
    Canvas canvas,
    Offset offset, {
    required TerminalCursorType cursorType,
    bool hasFocus = true,
  }) {
    final paint = _cursorPaint
      ..color = _theme.cursor
      ..strokeWidth = 1
      ..strokeCap = StrokeCap.butt;

    if (!hasFocus) {
      paint.style = PaintingStyle.stroke;
      canvas.drawRect(offset & _cellSize, paint);
      return;
    }

    switch (cursorType) {
      case TerminalCursorType.block:
        paint.style = PaintingStyle.fill;
        canvas.drawRect(offset & _cellSize, paint);
        return;
      case TerminalCursorType.underline:
        return canvas.drawLine(
          Offset(offset.dx, offset.dy + _cellSize.height - 1),
          Offset(
            offset.dx + _cellSize.width,
            offset.dy + _cellSize.height - 1,
          ),
          paint,
        );
      case TerminalCursorType.verticalBar:
        return canvas.drawLine(
          Offset(offset.dx, offset.dy),
          Offset(offset.dx, offset.dy + _cellSize.height),
          paint,
        );
    }
  }

  @pragma('vm:prefer-inline')
  void paintHighlight(Canvas canvas, Offset offset, int length, Color color) {
    final endOffset =
        offset.translate(length * _cellSize.width, _cellSize.height);

    final paint = _highlightPaint
      ..color = color
      ..style = PaintingStyle.fill;

    canvas.drawRect(
      Rect.fromPoints(offset, endOffset),
      paint,
    );
  }

  /// Paints [line] to [canvas] at [offset]. The x offset of [offset] is usually
  /// 0, and the y offset is the top of the line.
  void paintLine(Canvas canvas, Offset offset, BufferLine line,
      {bool collectProfile = false}) {
    final profile = collectProfile ? TerminalPainterProfile() : null;
    _profile = profile;
    final plan = _lineRenderPlanFor(line, profile);
    final cellWidth = _cellSize.width;

    for (final span in plan.backgroundSpans) {
      profile?.backgroundRuns++;
      _paintBackgroundRun(
        canvas,
        offset.translate(span.start * cellWidth, 0),
        span.width,
        span.color,
      );
    }

    for (final span in plan.foregroundSpans) {
      switch (span) {
        case _TextRunSpan():
          if (span.text.length < _minTextRunLength) {
            _paintTextRunCells(
              canvas,
              offset.translate(span.start * cellWidth, 0),
              span.text,
              span.foreground,
              span.background,
              span.flags,
            );
            profile?.singleCells += span.text.length;
          } else if (_paintTextRun(
            canvas,
            offset.translate(span.start * cellWidth, 0),
            span.text,
            span.foreground,
            span.background,
            span.flags,
          )) {
            profile?.asciiRuns++;
          } else {
            profile?.asciiRunFallbacks++;
          }
        case _GeometryGlyphRunSpan():
          final spanOffset = offset.translate(span.start * cellWidth, 0);
          if (span.charCodes.length < _minGeometryGlyphRunLength) {
            _paintGeometryGlyphCells(
              canvas,
              spanOffset,
              span.charCodes,
              span.foreground,
              span.background,
              span.flags,
            );
          } else {
            _paintGeometryGlyphRun(
              canvas,
              spanOffset,
              span.charCodes,
              span.foreground,
              span.background,
              span.flags,
            );
          }
          profile?.singleCells += span.charCodes.length;
        case _CellForegroundSpan():
          paintCellForeground(
            canvas,
            offset.translate(span.column * cellWidth, 0),
            span.cellData,
          );
          profile?.singleCells++;
      }
    }
  }

  _LineRenderPlan _lineRenderPlanFor(
    BufferLine line,
    TerminalPainterProfile? profile,
  ) {
    final cached = _lineRenderPlanCache[line];
    if (cached != null &&
        cached.revision == line.revision &&
        cached.length == line.length &&
        cached.paintRevision == _paintRevision) {
      _lineRenderPlanCache.remove(line);
      _lineRenderPlanCache[line] = cached;
      profile?.renderPlanCacheHits++;
      return cached.plan;
    }
    if (cached != null) {
      _lineRenderPlanCache.remove(line);
    }

    profile?.renderPlanCacheMisses++;
    final cellData = CellData.empty();
    final backgroundSpans = <_BackgroundSpan>[];
    final foregroundSpans = <_ForegroundSpan>[];
    Color? backgroundRunColor;
    var backgroundRunStart = 0;
    var backgroundRunWidth = 0;

    void flushBackgroundRun() {
      final color = backgroundRunColor;
      if (color == null || backgroundRunWidth == 0) return;
      backgroundSpans.add(
        _BackgroundSpan(
          backgroundRunStart,
          backgroundRunWidth,
          color,
        ),
      );
      backgroundRunColor = null;
      backgroundRunWidth = 0;
    }

    for (var i = 0; i < line.length; i++) {
      line.getCellData(i, cellData);

      final charWidth = cellData.content >> CellContent.widthShift;
      final cellSpan = charWidth == 2 ? 2 : 1;
      final color = _cellBackgroundColor(cellData);
      if (color == null) {
        flushBackgroundRun();
      } else if (backgroundRunColor == color) {
        backgroundRunWidth += cellSpan;
      } else {
        flushBackgroundRun();
        backgroundRunColor = color;
        backgroundRunStart = i;
        backgroundRunWidth = cellSpan;
      }

      if (charWidth == 2) {
        i++;
      }
    }
    flushBackgroundRun();

    for (var i = 0; i < line.length;) {
      line.getCellData(i, cellData);

      final charWidth = cellData.content >> CellContent.widthShift;
      if (_canStartTextRun(cellData)) {
        final runStart = i;
        final foreground = cellData.foreground;
        final background = cellData.background;
        final flags = cellData.flags;
        final text = StringBuffer()
          ..writeCharCode(cellData.content & CellContent.codepointMask);
        i++;

        while (i < line.length) {
          line.getCellData(i, cellData);
          if (!_canContinueTextRun(cellData, foreground, background, flags)) {
            break;
          }
          text.writeCharCode(cellData.content & CellContent.codepointMask);
          i++;
        }

        final runText = text.toString();
        _addTextRunSpans(
          foregroundSpans,
          runStart,
          runText,
          foreground,
          background,
          flags,
        );
        continue;
      }

      if (_canStartGeometryGlyphRun(cellData)) {
        final runStart = i;
        final foreground = cellData.foreground;
        final background = cellData.background;
        final flags = cellData.flags;
        final charCodes = <int>[
          cellData.content & CellContent.codepointMask,
        ];
        i++;

        while (i < line.length) {
          line.getCellData(i, cellData);
          if (!_canContinueGeometryGlyphRun(
            cellData,
            foreground,
            background,
            flags,
          )) {
            break;
          }
          charCodes.add(cellData.content & CellContent.codepointMask);
          i++;
        }

        foregroundSpans.add(
          _GeometryGlyphRunSpan(
            runStart,
            charCodes,
            foreground,
            background,
            flags,
          ),
        );
        continue;
      }

      if (_shouldPaintCellForeground(cellData)) {
        foregroundSpans.add(
          _CellForegroundSpan(
            i,
            CellData(
              foreground: cellData.foreground,
              background: cellData.background,
              flags: cellData.flags,
              content: cellData.content,
            ),
          ),
        );
      }

      if (charWidth == 2) {
        i++;
      }
      i++;
    }

    final plan = _LineRenderPlan(
      backgroundSpans: backgroundSpans,
      foregroundSpans: foregroundSpans,
    );
    _lineRenderPlanCache[line] = _LineRenderPlanCache(
      revision: line.revision,
      length: line.length,
      paintRevision: _paintRevision,
      plan: plan,
    );
    _pruneLineRenderPlanCache();
    return plan;
  }

  void _addTextRunSpans(
    List<_ForegroundSpan> spans,
    int start,
    String text,
    int foreground,
    int background,
    int flags,
  ) {
    if (text.length <= _maxTextRunChunkCells) {
      spans.add(_TextRunSpan(start, text, foreground, background, flags));
      return;
    }

    for (var offset = 0; offset < text.length;) {
      final remaining = text.length - offset;
      var chunkLength = remaining;
      if (remaining > _maxTextRunChunkCells) {
        chunkLength = _maxTextRunChunkCells;
        final tailLength = remaining - chunkLength;
        if (tailLength > 0 && tailLength < _minTextRunLength) {
          chunkLength += tailLength;
        }
      }
      final end = offset + chunkLength;
      spans.add(
        _TextRunSpan(
          start + offset,
          text.substring(offset, end),
          foreground,
          background,
          flags,
        ),
      );
      offset = end;
    }
  }

  void _pruneLineRenderPlanCache() {
    while (_lineRenderPlanCache.length > _maxLineRenderPlans) {
      _lineRenderPlanCache.remove(_lineRenderPlanCache.keys.first);
    }
  }

  @pragma('vm:prefer-inline')
  void paintCell(Canvas canvas, Offset offset, CellData cellData) {
    paintCellBackground(canvas, offset, cellData);
    paintCellForeground(canvas, offset, cellData);
  }

  /// Paints the character in the cell represented by [cellData] to [canvas] at
  /// [offset].
  @pragma('vm:prefer-inline')
  void paintCellForeground(Canvas canvas, Offset offset, CellData cellData) {
    final charCode = cellData.content & CellContent.codepointMask;
    if (charCode == 0) return;

    final cellFlags = cellData.flags;
    if (charCode == 0x20 && cellFlags & CellFlags.underline == 0) {
      return;
    }

    var color = _cellForegroundColor(cellData);

    if (_paintTerminalGlyph(canvas, offset, charCode, cellFlags, color)) {
      return;
    }

    final cacheKey = cellData.getHash() ^ _textScaler.hashCode;
    var paragraph = _paragraphCache.getLayoutFromCache(cacheKey);

    if (paragraph == null) {
      _profile?.paragraphCacheMisses++;
      final style = _textStyle.toTextStyle(
        color: color,
        bold: cellFlags & CellFlags.bold != 0,
        italic: cellFlags & CellFlags.italic != 0,
        underline: cellFlags & CellFlags.underline != 0,
      );

      // Flutter does not draw an underline below a space which is not between
      // other regular characters. As only single characters are drawn, this
      // will never produce an underline below a space in the terminal. As a
      // workaround the regular space CodePoint 0x20 is replaced with
      // the CodePoint 0xA0. This is a non breaking space and a underline can be
      // drawn below it.
      var char = String.fromCharCode(charCode);
      if (cellFlags & CellFlags.underline != 0 && charCode == 0x20) {
        char = String.fromCharCode(0xA0);
      }

      paragraph = _paragraphCache.performAndCacheLayout(
        char,
        style,
        _textScaler,
        cacheKey,
      );
    } else {
      _profile?.paragraphCacheHits++;
    }

    canvas.drawParagraph(paragraph, offset);
  }

  bool _shouldPaintCellForeground(CellData cellData) {
    final charCode = cellData.content & CellContent.codepointMask;
    if (charCode == 0) return false;
    final cellFlags = cellData.flags;
    return charCode != 0x20 || cellFlags & CellFlags.underline != 0;
  }

  Color _cellForegroundColor(CellData cellData) {
    return _foregroundColor(
      cellData.foreground,
      cellData.background,
      cellData.flags,
    );
  }

  bool _canStartTextRun(CellData cellData) {
    final charCode = cellData.content & CellContent.codepointMask;
    if (!_isBatchableTextRunCodepoint(charCode, allowSpace: false)) {
      return false;
    }
    return _canPaintTextRunCell(cellData);
  }

  bool _canContinueTextRun(
    CellData cellData,
    int foreground,
    int background,
    int flags,
  ) {
    if (cellData.foreground != foreground ||
        cellData.background != background ||
        cellData.flags != flags) {
      return false;
    }
    final charCode = cellData.content & CellContent.codepointMask;
    if (!_isBatchableTextRunCodepoint(charCode, allowSpace: true)) {
      return false;
    }
    return _canPaintTextRunCell(cellData);
  }

  bool _canPaintTextRunCell(CellData cellData) {
    final charWidth = cellData.content >> CellContent.widthShift;
    if (charWidth != 1) {
      return false;
    }
    const textOnlyFlags = CellFlags.italic | CellFlags.underline;
    return (cellData.flags & textOnlyFlags) == 0;
  }

  bool _canStartGeometryGlyphRun(CellData cellData) {
    final charCode = cellData.content & CellContent.codepointMask;
    if (!_isTerminalGlyphCodepoint(charCode)) {
      return false;
    }
    return _canPaintGeometryGlyphRunCell(cellData);
  }

  bool _canContinueGeometryGlyphRun(
    CellData cellData,
    int foreground,
    int background,
    int flags,
  ) {
    if (cellData.foreground != foreground ||
        cellData.background != background ||
        cellData.flags != flags) {
      return false;
    }
    final charCode = cellData.content & CellContent.codepointMask;
    if (!_isTerminalGlyphCodepoint(charCode)) {
      return false;
    }
    return _canPaintGeometryGlyphRunCell(cellData);
  }

  bool _canPaintGeometryGlyphRunCell(CellData cellData) {
    final charWidth = cellData.content >> CellContent.widthShift;
    if (charWidth != 1) {
      return false;
    }
    const textOnlyFlags = CellFlags.italic | CellFlags.underline;
    return (cellData.flags & textOnlyFlags) == 0;
  }

  bool _isBatchableTextRunCodepoint(int charCode, {required bool allowSpace}) {
    if (charCode == 0x20) {
      return allowSpace;
    }
    if (charCode <= 0x20 || charCode > 0xFFFF) {
      return false;
    }
    if (charCode >= 0x7F && charCode <= 0x9F) {
      return false;
    }
    if (_isTerminalGlyphCodepoint(charCode)) {
      return false;
    }
    return !_isCombiningCodepoint(charCode);
  }

  bool _isCombiningCodepoint(int charCode) {
    return (charCode >= 0x0300 && charCode <= 0x036F) ||
        (charCode >= 0x1AB0 && charCode <= 0x1AFF) ||
        (charCode >= 0x1DC0 && charCode <= 0x1DFF) ||
        (charCode >= 0x20D0 && charCode <= 0x20FF) ||
        (charCode >= 0xFE20 && charCode <= 0xFE2F);
  }

  bool _paintTextRun(
    Canvas canvas,
    Offset offset,
    String text,
    int foreground,
    int background,
    int flags,
  ) {
    final color = _foregroundColor(foreground, background, flags);
    final cacheKey = Object.hash(
      text,
      foreground,
      background,
      flags,
      _textScaler,
      _paintRevision,
    );
    var paragraph = _runParagraphCache.getLayoutFromCache(cacheKey);
    if (paragraph == null) {
      _profile?.runParagraphCacheMisses++;
      final style = _textStyle.toTextStyle(
        color: color,
        bold: flags & CellFlags.bold != 0,
        italic: false,
        underline: false,
        fontFeatures: _textRunFontFeatures,
      );
      paragraph = _runParagraphCache.performAndCacheLayout(
        text,
        style,
        _textScaler,
        cacheKey,
      );
    } else {
      _profile?.runParagraphCacheHits++;
    }
    final expectedWidth = text.length * _cellSize.width;
    final measuredWidth = paragraph.maxIntrinsicWidth;
    final tolerance = _cellSize.width * 0.08;
    if ((measuredWidth - expectedWidth).abs() > tolerance) {
      _paintTextRunCells(canvas, offset, text, foreground, background, flags);
      return false;
    }
    canvas.drawParagraph(paragraph, offset);
    return true;
  }

  void _paintTextRunCells(
    Canvas canvas,
    Offset offset,
    String text,
    int foreground,
    int background,
    int flags,
  ) {
    for (var i = 0; i < text.length; i++) {
      _paintTextRunCell(
        canvas,
        offset.translate(i * _cellSize.width, 0),
        text.codeUnitAt(i),
        foreground,
        background,
        flags,
      );
    }
  }

  void _paintTextRunCell(
    Canvas canvas,
    Offset offset,
    int charCode,
    int foreground,
    int background,
    int flags,
  ) {
    final cacheKey = Object.hash(
      charCode,
      foreground,
      background,
      flags,
      _textScaler,
      _paintRevision,
    );
    var paragraph = _paragraphCache.getLayoutFromCache(cacheKey);
    if (paragraph == null) {
      _profile?.paragraphCacheMisses++;
      final style = _textStyle.toTextStyle(
        color: _foregroundColor(foreground, background, flags),
        bold: flags & CellFlags.bold != 0,
      );
      paragraph = _paragraphCache.performAndCacheLayout(
        String.fromCharCode(charCode),
        style,
        _textScaler,
        cacheKey,
      );
    } else {
      _profile?.paragraphCacheHits++;
    }
    canvas.drawParagraph(paragraph, offset);
  }

  Color _foregroundColor(int foreground, int background, int flags) {
    var color = flags & CellFlags.inverse == 0
        ? resolveForegroundColor(foreground)
        : resolveBackgroundColor(background);

    if (flags & CellFlags.faint != 0) {
      color = color.withValues(alpha: 0.5);
    }

    return color;
  }

  void _paintGeometryGlyphRun(
    Canvas canvas,
    Offset offset,
    List<int> charCodes,
    int foreground,
    int background,
    int flags,
  ) {
    final color = _foregroundColor(foreground, background, flags);
    final key = _GlyphRunPictureKey(
      charCodes: charCodes,
      bold: flags & CellFlags.bold != 0,
      color: color,
      cellWidth: _cellSize.width,
      cellHeight: _cellSize.height,
      paintRevision: _paintRevision,
    );
    var picture = _glyphRunPictureCache.remove(key);
    if (picture == null) {
      _profile?.glyphRunPictureCacheMisses++;
      final recorder = PictureRecorder();
      final runCanvas = Canvas(
        recorder,
        Rect.fromLTWH(
          0,
          0,
          charCodes.length * _cellSize.width,
          _cellSize.height,
        ),
      );
      for (var i = 0; i < charCodes.length; i++) {
        final charCode = charCodes[i];
        final glyphOffset = Offset(i * _cellSize.width, 0);
        if (!_paintTerminalGlyphImmediate(
          runCanvas,
          glyphOffset,
          charCode,
          flags,
          color,
        )) {
          _paintTextRunCell(
            runCanvas,
            glyphOffset,
            charCode,
            foreground,
            background,
            flags,
          );
        }
      }
      picture = recorder.endRecording();
      _glyphRunPictureCache[key] = picture;
      _pruneGlyphRunPictureCache();
    } else {
      _profile?.glyphRunPictureCacheHits++;
      _glyphRunPictureCache[key] = picture;
    }

    canvas.save();
    canvas.translate(offset.dx, offset.dy);
    canvas.drawPicture(picture);
    canvas.restore();
  }

  void _paintGeometryGlyphCells(
    Canvas canvas,
    Offset offset,
    List<int> charCodes,
    int foreground,
    int background,
    int flags,
  ) {
    final color = _foregroundColor(foreground, background, flags);
    for (var i = 0; i < charCodes.length; i++) {
      final glyphOffset = offset.translate(i * _cellSize.width, 0);
      if (!_paintTerminalGlyph(
        canvas,
        glyphOffset,
        charCodes[i],
        flags,
        color,
      )) {
        _paintTextRunCell(
          canvas,
          glyphOffset,
          charCodes[i],
          foreground,
          background,
          flags,
        );
      }
    }
  }

  bool _paintTerminalGlyph(
    Canvas canvas,
    Offset offset,
    int charCode,
    int cellFlags,
    Color color,
  ) {
    const textOnlyFlags = CellFlags.italic | CellFlags.underline;
    if (cellFlags & textOnlyFlags != 0) {
      return false;
    }

    if (!_isTerminalGlyphCodepoint(charCode)) {
      return false;
    }

    final key = _GlyphPictureKey(
      charCode: charCode,
      bold: cellFlags & CellFlags.bold != 0,
      color: color,
      cellWidth: _cellSize.width,
      cellHeight: _cellSize.height,
      paintRevision: _paintRevision,
    );
    var picture = _glyphPictureCache.remove(key);
    if (picture == null) {
      _profile?.glyphPictureCacheMisses++;
      final recorder = PictureRecorder();
      final glyphCanvas = Canvas(recorder, Offset.zero & _cellSize);
      if (!_paintTerminalGlyphImmediate(
        glyphCanvas,
        Offset.zero,
        charCode,
        cellFlags,
        color,
      )) {
        recorder.endRecording().dispose();
        return false;
      }
      picture = recorder.endRecording();
      _glyphPictureCache[key] = picture;
      _pruneGlyphPictureCache();
    } else {
      _profile?.glyphPictureCacheHits++;
      _glyphPictureCache[key] = picture;
    }

    canvas.save();
    canvas.translate(offset.dx, offset.dy);
    canvas.drawPicture(picture);
    canvas.restore();
    return true;
  }

  bool _isTerminalGlyphCodepoint(int charCode) {
    return (charCode >= 0x2500 && charCode <= 0x257F) ||
        (charCode >= 0x2580 && charCode <= 0x259F) ||
        (charCode >= 0x2800 && charCode <= 0x28FF);
  }

  bool _paintTerminalGlyphImmediate(
    Canvas canvas,
    Offset offset,
    int charCode,
    int cellFlags,
    Color color,
  ) {
    if (charCode >= 0x2500 && charCode <= 0x257F) {
      return _paintBoxDrawing(canvas, offset, charCode, cellFlags, color);
    }
    if (charCode >= 0x2580 && charCode <= 0x259F) {
      return _paintBlockElement(canvas, offset, charCode, color);
    }
    if (charCode >= 0x2800 && charCode <= 0x28FF) {
      return _paintBraillePattern(canvas, offset, charCode, color);
    }
    return false;
  }

  void _pruneGlyphPictureCache() {
    while (_glyphPictureCache.length > _maxGlyphPictures) {
      final key = _glyphPictureCache.keys.first;
      _glyphPictureCache.remove(key)?.dispose();
    }
  }

  void _pruneGlyphRunPictureCache() {
    while (_glyphRunPictureCache.length > _maxGlyphRunPictures) {
      final key = _glyphRunPictureCache.keys.first;
      _glyphRunPictureCache.remove(key)?.dispose();
    }
  }

  void _clearGlyphPictureCache() {
    for (final picture in _glyphPictureCache.values) {
      picture.dispose();
    }
    _glyphPictureCache.clear();
  }

  void _clearGlyphRunPictureCache() {
    for (final picture in _glyphRunPictureCache.values) {
      picture.dispose();
    }
    _glyphRunPictureCache.clear();
  }

  bool _paintBlockElement(
    Canvas canvas,
    Offset offset,
    int charCode,
    Color color,
  ) {
    final w = _cellSize.width;
    final h = _cellSize.height;
    final paint = _glyphFillPaint
      ..color = color
      ..style = PaintingStyle.fill;

    Rect rect(double left, double top, double right, double bottom) {
      return Rect.fromLTRB(
        offset.dx + left * w,
        offset.dy + top * h,
        offset.dx + right * w,
        offset.dy + bottom * h,
      );
    }

    switch (charCode) {
      case 0x2580: // upper half block
        canvas.drawRect(rect(0, 0, 1, 0.5), paint);
        return true;
      case 0x2584: // lower half block
        canvas.drawRect(rect(0, 0.5, 1, 1), paint);
        return true;
      case 0x2588: // full block
        canvas.drawRect(offset & _cellSize, paint);
        return true;
      case 0x258C: // left half block
        canvas.drawRect(rect(0, 0, 0.5, 1), paint);
        return true;
      case 0x2590: // right half block
        canvas.drawRect(rect(0.5, 0, 1, 1), paint);
        return true;
      case 0x2591: // light shade
        _paintShade(canvas, offset, color, 0.25);
        return true;
      case 0x2592: // medium shade
        _paintShade(canvas, offset, color, 0.5);
        return true;
      case 0x2593: // dark shade
        _paintShade(canvas, offset, color, 0.75);
        return true;
      case 0x2596: // quadrant lower left
        canvas.drawRect(rect(0, 0.5, 0.5, 1), paint);
        return true;
      case 0x2597: // quadrant lower right
        canvas.drawRect(rect(0.5, 0.5, 1, 1), paint);
        return true;
      case 0x2598: // quadrant upper left
        canvas.drawRect(rect(0, 0, 0.5, 0.5), paint);
        return true;
      case 0x2599: // quadrants upper left, lower left, lower right
        canvas.drawRect(rect(0, 0, 0.5, 1), paint);
        canvas.drawRect(rect(0.5, 0.5, 1, 1), paint);
        return true;
      case 0x259A: // quadrants upper left and lower right
        canvas.drawRect(rect(0, 0, 0.5, 0.5), paint);
        canvas.drawRect(rect(0.5, 0.5, 1, 1), paint);
        return true;
      case 0x259B: // quadrants upper left, upper right, lower left
        canvas.drawRect(rect(0, 0, 1, 0.5), paint);
        canvas.drawRect(rect(0, 0.5, 0.5, 1), paint);
        return true;
      case 0x259C: // quadrants upper left, upper right, lower right
        canvas.drawRect(rect(0, 0, 1, 0.5), paint);
        canvas.drawRect(rect(0.5, 0.5, 1, 1), paint);
        return true;
      case 0x259D: // quadrant upper right
        canvas.drawRect(rect(0.5, 0, 1, 0.5), paint);
        return true;
      case 0x259E: // quadrants upper right and lower left
        canvas.drawRect(rect(0.5, 0, 1, 0.5), paint);
        canvas.drawRect(rect(0, 0.5, 0.5, 1), paint);
        return true;
      case 0x259F: // quadrants upper right, lower left, lower right
        canvas.drawRect(rect(0.5, 0, 1, 1), paint);
        canvas.drawRect(rect(0, 0.5, 0.5, 1), paint);
        return true;
    }
    return false;
  }

  void _paintShade(Canvas canvas, Offset offset, Color color, double opacity) {
    final paint = _glyphFillPaint
      ..color = color.withValues(alpha: color.a * opacity)
      ..style = PaintingStyle.fill;
    canvas.drawRect(offset & _cellSize, paint);
  }

  bool _paintBraillePattern(
    Canvas canvas,
    Offset offset,
    int charCode,
    Color color,
  ) {
    final dots = charCode - 0x2800;
    if (dots == 0) {
      return true;
    }

    final w = _cellSize.width;
    final h = _cellSize.height;
    final radius = (w < h ? w : h) * 0.105;
    final paint = _glyphFillPaint
      ..color = color
      ..style = PaintingStyle.fill;

    void dot(int bit, double x, double y) {
      if ((dots & (1 << bit)) == 0) {
        return;
      }
      canvas.drawCircle(
        Offset(offset.dx + x * w, offset.dy + y * h),
        radius,
        paint,
      );
    }

    dot(0, 0.32, 0.18);
    dot(1, 0.32, 0.39);
    dot(2, 0.32, 0.60);
    dot(6, 0.32, 0.81);
    dot(3, 0.68, 0.18);
    dot(4, 0.68, 0.39);
    dot(5, 0.68, 0.60);
    dot(7, 0.68, 0.81);
    return true;
  }

  bool _paintBoxDrawing(
    Canvas canvas,
    Offset offset,
    int charCode,
    int cellFlags,
    Color color,
  ) {
    final left = offset.dx;
    final top = offset.dy;
    final right = left + _cellSize.width;
    final bottom = top + _cellSize.height;
    final midX = left + _cellSize.width / 2;
    final midY = top + _cellSize.height / 2;
    final baseStroke = _cellSize.shortestSide * 0.085;
    final doubleGap = _cellSize.shortestSide * 0.12;
    final glyphBold = switch (charCode) {
      0x2501 ||
      0x2503 ||
      0x250F ||
      0x2513 ||
      0x2517 ||
      0x251B ||
      0x2523 ||
      0x252B ||
      0x2533 ||
      0x253B ||
      0x254B =>
        true,
      _ => false,
    };
    final strokeWidth = (baseStroke < 1 ? 1.0 : baseStroke) *
        (cellFlags & CellFlags.bold == 0 && !glyphBold ? 1.0 : 1.45);
    final paint = _glyphStrokePaint
      ..color = color
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.square
      ..style = PaintingStyle.stroke;

    void h(double x1, double x2) {
      canvas.drawLine(Offset(x1, midY), Offset(x2, midY), paint);
    }

    void v(double y1, double y2) {
      canvas.drawLine(Offset(midX, y1), Offset(midX, y2), paint);
    }

    void hd(double x1, double x2) {
      final segment = (x2 - x1) / 3;
      h(x1, x1 + segment);
      h(x2 - segment, x2);
    }

    void vd(double y1, double y2) {
      final segment = (y2 - y1) / 3;
      v(y1, y1 + segment);
      v(y2 - segment, y2);
    }

    void hh(double x1, double x2) {
      canvas.drawLine(
        Offset(x1, midY - doubleGap),
        Offset(x2, midY - doubleGap),
        paint,
      );
      canvas.drawLine(
        Offset(x1, midY + doubleGap),
        Offset(x2, midY + doubleGap),
        paint,
      );
    }

    void vv(double y1, double y2) {
      canvas.drawLine(
        Offset(midX - doubleGap, y1),
        Offset(midX - doubleGap, y2),
        paint,
      );
      canvas.drawLine(
        Offset(midX + doubleGap, y1),
        Offset(midX + doubleGap, y2),
        paint,
      );
    }

    switch (charCode) {
      case 0x2500: // ─
      case 0x2501: // ━
        h(left, right);
        return true;
      case 0x2504: // ┄
      case 0x2505: // ┅
      case 0x2508: // ┈
      case 0x2509: // ┉
        hd(left, right);
        return true;
      case 0x2502: // │
      case 0x2503: // ┃
        v(top, bottom);
        return true;
      case 0x2506: // ┆
      case 0x2507: // ┇
      case 0x250A: // ┊
      case 0x250B: // ┋
        vd(top, bottom);
        return true;
      case 0x250C: // ┌
      case 0x250F: // ┏
        h(midX, right);
        v(midY, bottom);
        return true;
      case 0x2510: // ┐
      case 0x2513: // ┓
        h(left, midX);
        v(midY, bottom);
        return true;
      case 0x2514: // └
      case 0x2517: // ┗
        h(midX, right);
        v(top, midY);
        return true;
      case 0x2518: // ┘
      case 0x251B: // ┛
        h(left, midX);
        v(top, midY);
        return true;
      case 0x251C: // ├
      case 0x2523: // ┣
        h(midX, right);
        v(top, bottom);
        return true;
      case 0x2524: // ┤
      case 0x252B: // ┫
        h(left, midX);
        v(top, bottom);
        return true;
      case 0x252C: // ┬
      case 0x2533: // ┳
        h(left, right);
        v(midY, bottom);
        return true;
      case 0x2534: // ┴
      case 0x253B: // ┻
        h(left, right);
        v(top, midY);
        return true;
      case 0x253C: // ┼
      case 0x254B: // ╋
        h(left, right);
        v(top, bottom);
        return true;
      case 0x2550: // ═
        hh(left, right);
        return true;
      case 0x2551: // ║
        vv(top, bottom);
        return true;
      case 0x2554: // ╔
        hh(midX, right);
        vv(midY, bottom);
        return true;
      case 0x2557: // ╗
        hh(left, midX);
        vv(midY, bottom);
        return true;
      case 0x255A: // ╚
        hh(midX, right);
        vv(top, midY);
        return true;
      case 0x255D: // ╝
        hh(left, midX);
        vv(top, midY);
        return true;
      case 0x2560: // ╠
        hh(midX, right);
        vv(top, bottom);
        return true;
      case 0x2563: // ╣
        hh(left, midX);
        vv(top, bottom);
        return true;
      case 0x2566: // ╦
        hh(left, right);
        vv(midY, bottom);
        return true;
      case 0x2569: // ╩
        hh(left, right);
        vv(top, midY);
        return true;
      case 0x256C: // ╬
        hh(left, right);
        vv(top, bottom);
        return true;
      case 0x256D: // ╭
        h(midX, right);
        v(midY, bottom);
        return true;
      case 0x256E: // ╮
        h(left, midX);
        v(midY, bottom);
        return true;
      case 0x256F: // ╯
        h(left, midX);
        v(top, midY);
        return true;
      case 0x2570: // ╰
        h(midX, right);
        v(top, midY);
        return true;
    }
    return false;
  }

  /// Paints the background of a cell represented by [cellData] to [canvas] at
  /// [offset].
  @pragma('vm:prefer-inline')
  void paintCellBackground(Canvas canvas, Offset offset, CellData cellData) {
    final color = _cellBackgroundColor(cellData);
    if (color == null) return;
    final doubleWidth = cellData.content >> CellContent.widthShift == 2;
    final widthScale = doubleWidth ? 2 : 1;
    _paintBackgroundRun(canvas, offset, widthScale, color);
  }

  Color? _cellBackgroundColor(CellData cellData) {
    final colorType = cellData.background & CellColor.typeMask;
    if (cellData.flags & CellFlags.inverse != 0) {
      return resolveForegroundColor(cellData.foreground);
    }
    if (colorType == CellColor.normal) {
      return null;
    }
    return resolveBackgroundColor(cellData.background);
  }

  void _paintBackgroundRun(
    Canvas canvas,
    Offset offset,
    int widthCells,
    Color color,
  ) {
    final paint = _backgroundPaint
      ..color = color
      ..style = PaintingStyle.fill;
    final size = Size(_cellSize.width * widthCells + 1, _cellSize.height);
    canvas.drawRect(offset & size, paint);
  }

  /// Get the effective foreground color for a cell from information encoded in
  /// [cellColor].
  @pragma('vm:prefer-inline')
  Color resolveForegroundColor(int cellColor) {
    final colorType = cellColor & CellColor.typeMask;
    final colorValue = cellColor & CellColor.valueMask;

    switch (colorType) {
      case CellColor.normal:
        return _theme.foreground;
      case CellColor.named:
      case CellColor.palette:
        return _colorPalette[colorValue];
      case CellColor.rgb:
      default:
        return Color(colorValue | 0xFF000000);
    }
  }

  /// Get the effective background color for a cell from information encoded in
  /// [cellColor].
  @pragma('vm:prefer-inline')
  Color resolveBackgroundColor(int cellColor) {
    final colorType = cellColor & CellColor.typeMask;
    final colorValue = cellColor & CellColor.valueMask;

    switch (colorType) {
      case CellColor.normal:
        return _theme.background;
      case CellColor.named:
      case CellColor.palette:
        return _colorPalette[colorValue];
      case CellColor.rgb:
      default:
        return Color(colorValue | 0xFF000000);
    }
  }
}

class TerminalPainterProfile {
  var backgroundRuns = 0;
  var asciiRuns = 0;
  var asciiRunFallbacks = 0;
  var renderPlanCacheHits = 0;
  var renderPlanCacheMisses = 0;
  var glyphPictureCacheHits = 0;
  var glyphPictureCacheMisses = 0;
  var glyphRunPictureCacheHits = 0;
  var glyphRunPictureCacheMisses = 0;
  var paragraphCacheHits = 0;
  var paragraphCacheMisses = 0;
  var runParagraphCacheHits = 0;
  var runParagraphCacheMisses = 0;
  var singleCells = 0;
  var blankLines = 0;
}

class _LineRenderPlanCache {
  _LineRenderPlanCache({
    required this.revision,
    required this.length,
    required this.paintRevision,
    required this.plan,
  });

  final int revision;
  final int length;
  final int paintRevision;
  final _LineRenderPlan plan;
}

class _LineRenderPlan {
  _LineRenderPlan({
    required this.backgroundSpans,
    required this.foregroundSpans,
  });

  final List<_BackgroundSpan> backgroundSpans;
  final List<_ForegroundSpan> foregroundSpans;
}

class _BackgroundSpan {
  _BackgroundSpan(this.start, this.width, this.color);

  final int start;
  final int width;
  final Color color;
}

sealed class _ForegroundSpan {
  const _ForegroundSpan();
}

class _TextRunSpan extends _ForegroundSpan {
  const _TextRunSpan(
    this.start,
    this.text,
    this.foreground,
    this.background,
    this.flags,
  );

  final int start;
  final String text;
  final int foreground;
  final int background;
  final int flags;
}

class _GeometryGlyphRunSpan extends _ForegroundSpan {
  const _GeometryGlyphRunSpan(
    this.start,
    this.charCodes,
    this.foreground,
    this.background,
    this.flags,
  );

  final int start;
  final List<int> charCodes;
  final int foreground;
  final int background;
  final int flags;
}

class _CellForegroundSpan extends _ForegroundSpan {
  const _CellForegroundSpan(this.column, this.cellData);

  final int column;
  final CellData cellData;
}

class _GlyphPictureKey {
  const _GlyphPictureKey({
    required this.charCode,
    required this.bold,
    required this.color,
    required this.cellWidth,
    required this.cellHeight,
    required this.paintRevision,
  });

  final int charCode;
  final bool bold;
  final Color color;
  final double cellWidth;
  final double cellHeight;
  final int paintRevision;

  @override
  bool operator ==(Object other) {
    return other is _GlyphPictureKey &&
        other.charCode == charCode &&
        other.bold == bold &&
        other.color == color &&
        other.cellWidth == cellWidth &&
        other.cellHeight == cellHeight &&
        other.paintRevision == paintRevision;
  }

  @override
  int get hashCode => Object.hash(
        charCode,
        bold,
        color,
        cellWidth,
        cellHeight,
        paintRevision,
      );
}

class _GlyphRunPictureKey {
  _GlyphRunPictureKey({
    required List<int> charCodes,
    required this.bold,
    required this.color,
    required this.cellWidth,
    required this.cellHeight,
    required this.paintRevision,
  })  : charCodes = List.unmodifiable(charCodes),
        _charCodesHash = Object.hashAll(charCodes);

  final List<int> charCodes;
  final int _charCodesHash;
  final bool bold;
  final Color color;
  final double cellWidth;
  final double cellHeight;
  final int paintRevision;

  @override
  bool operator ==(Object other) {
    if (other is! _GlyphRunPictureKey ||
        other._charCodesHash != _charCodesHash ||
        other.bold != bold ||
        other.color != color ||
        other.cellWidth != cellWidth ||
        other.cellHeight != cellHeight ||
        other.paintRevision != paintRevision ||
        other.charCodes.length != charCodes.length) {
      return false;
    }
    for (var i = 0; i < charCodes.length; i++) {
      if (other.charCodes[i] != charCodes[i]) {
        return false;
      }
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
        _charCodesHash,
        bold,
        color,
        cellWidth,
        cellHeight,
        paintRevision,
      );
}
