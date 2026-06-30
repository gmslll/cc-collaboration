import 'dart:math' show max;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:xterm/src/core/buffer/cell_offset.dart';
import 'package:xterm/src/core/buffer/line.dart';
import 'package:xterm/src/core/buffer/range.dart';
import 'package:xterm/src/core/buffer/segment.dart';
import 'package:xterm/src/core/buffer/cell_flags.dart';
import 'package:xterm/src/core/cell.dart';
import 'package:xterm/src/core/mouse/button.dart';
import 'package:xterm/src/core/mouse/button_state.dart';
import 'package:xterm/src/terminal.dart';
import 'package:xterm/src/ui/controller.dart';
import 'package:xterm/src/ui/cursor_type.dart';
import 'package:xterm/src/ui/painter.dart';
import 'package:xterm/src/ui/selection_mode.dart';
import 'package:xterm/src/ui/terminal_size.dart';
import 'package:xterm/src/ui/terminal_text_style.dart';
import 'package:xterm/src/ui/terminal_theme.dart';

typedef EditableRectCallback = void Function(Rect rect, Rect caretRect);

class RenderTerminal extends RenderBox with RelayoutWhenSystemFontsChangeMixin {
  static const _maxCachedLinePictures = 256;
  static const _maxCachedLinePicturePixels = 2000000.0;

  static var debugProfilePaint = false;
  static TerminalRenderProfile? lastPaintProfile;

  RenderTerminal({
    required Terminal terminal,
    required TerminalController controller,
    required ViewportOffset offset,
    required EdgeInsets padding,
    required bool autoResize,
    required TerminalStyle textStyle,
    required TextScaler textScaler,
    required TerminalTheme theme,
    required FocusNode focusNode,
    required TerminalCursorType cursorType,
    required bool alwaysShowCursor,
    EditableRectCallback? onEditableRect,
    String? composingText,
  })  : _terminal = terminal,
        _controller = controller,
        _offset = offset,
        _padding = padding,
        _autoResize = autoResize,
        _focusNode = focusNode,
        _cursorType = cursorType,
        _alwaysShowCursor = alwaysShowCursor,
        _onEditableRect = onEditableRect,
        _composingText = composingText,
        _painter = TerminalPainter(
          theme: theme,
          textStyle: textStyle,
          textScaler: textScaler,
        );

  Terminal _terminal;
  set terminal(Terminal terminal) {
    if (_terminal == terminal) return;
    if (attached) _terminal.removeListener(_onTerminalChange);
    _terminal = terminal;
    if (attached) _terminal.addListener(_onTerminalChange);
    _clearLinePictureCache();
    _resizeTerminalIfNeeded();
    _markNeedsLayoutFor(TerminalPaintReason.terminal);
  }

  TerminalController _controller;
  set controller(TerminalController controller) {
    if (_controller == controller) return;
    if (attached) _controller.removeListener(_onControllerUpdate);
    _controller = controller;
    if (attached) _controller.addListener(_onControllerUpdate);
    _markNeedsLayoutFor(TerminalPaintReason.controller);
  }

  ViewportOffset _offset;
  set offset(ViewportOffset value) {
    if (value == _offset) return;
    if (attached) _offset.removeListener(_onScroll);
    _offset = value;
    if (attached) _offset.addListener(_onScroll);
    _markNeedsLayoutFor(TerminalPaintReason.scroll);
  }

  EdgeInsets _padding;
  set padding(EdgeInsets value) {
    if (value == _padding) return;
    _padding = value;
    _markNeedsLayoutFor(TerminalPaintReason.layout);
  }

  bool _autoResize;
  set autoResize(bool value) {
    if (value == _autoResize) return;
    _autoResize = value;
    _markNeedsLayoutFor(TerminalPaintReason.layout);
  }

  set textStyle(TerminalStyle value) {
    if (value == _painter.textStyle) return;
    _painter.textStyle = value;
    _clearLinePictureCache();
    _markNeedsLayoutFor(TerminalPaintReason.style);
  }

  set textScaler(TextScaler value) {
    if (value == _painter.textScaler) return;
    _painter.textScaler = value;
    _clearLinePictureCache();
    _markNeedsLayoutFor(TerminalPaintReason.style);
  }

  set theme(TerminalTheme value) {
    if (value == _painter.theme) return;
    _painter.theme = value;
    _clearLinePictureCache();
    _markNeedsPaintFor(TerminalPaintReason.theme);
  }

  FocusNode _focusNode;
  set focusNode(FocusNode value) {
    if (value == _focusNode) return;
    if (attached) _focusNode.removeListener(_onFocusChange);
    _focusNode = value;
    if (attached) _focusNode.addListener(_onFocusChange);
    _markNeedsPaintFor(TerminalPaintReason.focus);
  }

  TerminalCursorType _cursorType;
  set cursorType(TerminalCursorType value) {
    if (value == _cursorType) return;
    _cursorType = value;
    _markNeedsPaintFor(TerminalPaintReason.cursor);
  }

  bool _alwaysShowCursor;
  set alwaysShowCursor(bool value) {
    if (value == _alwaysShowCursor) return;
    _alwaysShowCursor = value;
    _markNeedsPaintFor(TerminalPaintReason.cursor);
  }

  EditableRectCallback? _onEditableRect;
  set onEditableRect(EditableRectCallback? value) {
    if (value == _onEditableRect) return;
    _onEditableRect = value;
    _markNeedsLayoutFor(TerminalPaintReason.layout);
  }

  String? _composingText;
  set composingText(String? value) {
    if (value == _composingText) return;
    _composingText = value;
    _markNeedsPaintFor(TerminalPaintReason.composingText);
  }

  TerminalSize? _viewportSize;

  final TerminalPainter _painter;
  final _linePictureCache = <int, _LinePictureCache>{};
  final _overlayRowPictureCache = <int, _OverlayRowPictureCache>{};
  final _overlayDirtyRows = _RowDirtyTracker();
  _ViewportContentCache? _viewportContentCache;
  TerminalPaintReason _nextPaintReason = TerminalPaintReason.initial;
  BufferRange? _lastOverlaySelection;
  List<BufferRange> _lastOverlayHighlights = const [];
  int? _lastOverlayCursorRow;
  String? _lastOverlayComposingText;

  var _stickToBottom = true;
  var _lastUsingAltBuffer = false;
  double? _savedMainScrollOffset;
  var _restoreMainScrollOffset = false;

  void _onScroll() {
    _stickToBottom = _scrollOffset >= _maxScrollExtent;
    _markNeedsLayoutFor(TerminalPaintReason.scroll);
    _notifyEditableRect();
  }

  void _onFocusChange() {
    _markNeedsPaintFor(TerminalPaintReason.focus);
  }

  void _onTerminalChange() {
    _syncActiveBufferScrollState();
    _markNeedsLayoutFor(TerminalPaintReason.terminal);
    _notifyEditableRect();
  }

  void _syncActiveBufferScrollState() {
    final usingAltBuffer = _terminal.isUsingAltBuffer;
    if (usingAltBuffer == _lastUsingAltBuffer) return;

    if (usingAltBuffer) {
      _savedMainScrollOffset = _scrollOffset;
    } else {
      _restoreMainScrollOffset = true;
    }
    _lastUsingAltBuffer = usingAltBuffer;
  }

  void _onControllerUpdate() {
    _markNeedsLayoutFor(TerminalPaintReason.controller);
  }

  void _markNeedsPaintFor(TerminalPaintReason reason) {
    if (_invalidatesContentLayer(reason)) {
      _clearViewportContentCache();
    }
    _nextPaintReason = reason;
    markNeedsPaint();
  }

  void _markNeedsLayoutFor(TerminalPaintReason reason) {
    if (_invalidatesContentLayer(reason)) {
      _clearViewportContentCache();
    }
    _nextPaintReason = reason;
    markNeedsLayout();
  }

  bool _invalidatesContentLayer(TerminalPaintReason reason) {
    switch (reason) {
      case TerminalPaintReason.terminal:
      case TerminalPaintReason.scroll:
      case TerminalPaintReason.style:
      case TerminalPaintReason.theme:
      case TerminalPaintReason.layout:
      case TerminalPaintReason.initial:
      case TerminalPaintReason.unknown:
        return true;
      case TerminalPaintReason.controller:
      case TerminalPaintReason.focus:
      case TerminalPaintReason.cursor:
      case TerminalPaintReason.composingText:
        return false;
    }
  }

  @override
  final isRepaintBoundary = true;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _offset.addListener(_onScroll);
    _terminal.addListener(_onTerminalChange);
    _controller.addListener(_onControllerUpdate);
    _focusNode.addListener(_onFocusChange);
  }

  @override
  void detach() {
    super.detach();
    _offset.removeListener(_onScroll);
    _terminal.removeListener(_onTerminalChange);
    _controller.removeListener(_onControllerUpdate);
    _focusNode.removeListener(_onFocusChange);
  }

  @override
  void dispose() {
    _clearViewportContentCache();
    _clearOverlayRowPictureCache();
    _clearLinePictureCache();
    _painter.dispose();
    super.dispose();
  }

  @override
  bool hitTestSelf(Offset position) {
    return true;
  }

  @override
  void systemFontsDidChange() {
    _painter.clearFontCache();
    _clearViewportContentCache();
    _clearLinePictureCache();
    _nextPaintReason = TerminalPaintReason.style;
    super.systemFontsDidChange();
  }

  @override
  void performLayout() {
    size = constraints.biggest;

    _updateViewportSize();

    _updateScrollOffset();

    if (_restoreMainScrollOffset) {
      final target = (_savedMainScrollOffset ?? _maxScrollExtent)
          .clamp(0.0, _maxScrollExtent);
      _offset.correctBy(target - _scrollOffset);
      _stickToBottom = target >= _maxScrollExtent;
      _restoreMainScrollOffset = false;
    } else if (_stickToBottom) {
      _offset.correctBy(_maxScrollExtent - _scrollOffset);
    }
  }

  /// Total height of the terminal in pixels. Includes scrollback buffer.
  double get _terminalHeight =>
      _terminal.buffer.lines.length * _painter.cellSize.height;

  /// The distance from the top of the terminal to the top of the viewport.
  // double get _scrollOffset => _offset.pixels;
  double get _scrollOffset {
    // return _offset.pixels ~/ _painter.cellSize.height * _painter.cellSize.height;
    return _offset.pixels;
  }

  /// The height of a terminal line in pixels. This includes the line spacing.
  /// Height of the entire terminal is expected to be a multiple of this value.
  double get lineHeight => _painter.cellSize.height;

  /// Get the top-left corner of the cell at [cellOffset] in pixels.
  Offset getOffset(CellOffset cellOffset) {
    final row = cellOffset.y;
    final col = cellOffset.x;
    final x = col * _painter.cellSize.width;
    final y = row * _painter.cellSize.height;
    return Offset(x + _padding.left, y + _padding.top - _scrollOffset);
  }

  /// Get the [CellOffset] of the cell that [offset] is in.
  CellOffset getCellOffset(Offset offset) {
    return _getCellOffset(offset, clamp: true);
  }

  /// Converts a local pixel offset into a cell offset.
  ///
  /// Selection needs the unclamped position first so dragging outside the
  /// viewport can still extend in the intended direction. This mirrors flterm's
  /// flow: convert pixels to a raw cell, then clamp at the gesture boundary.
  CellOffset _getCellOffset(Offset offset, {required bool clamp}) {
    final x = offset.dx - _padding.left;
    // PATCH(cc-handoff): 在 alt buffer(全屏 TUI,被 ScrollHandler 包进 InfiniteScrollView)
    // 里,手势 localPosition 已是滚动后的内容坐标,再叠加 _scrollOffset 会重复计入,把
    // 选区行算得过大、被下面的 clamp 钳到最底行 —— 表现为「中上拖选不中、只有底部能选」。
    // alt buffer 内容高度=视口、本不该叠加滚动偏移;普通 buffer 维持原样(视口相对坐标)。
    final y = offset.dy -
        _padding.top +
        (_terminal.isUsingAltBuffer ? 0 : _scrollOffset);
    final row = y ~/ _painter.cellSize.height;
    final col = x ~/ _painter.cellSize.width;
    if (!clamp) {
      return CellOffset(col, row);
    }
    return CellOffset(
      col.clamp(0, _terminal.viewWidth - 1),
      row.clamp(0, _terminal.buffer.lines.length - 1),
    );
  }

  CellOffset _snapToCellHead(CellOffset offset) {
    if (offset.y < 0 || offset.y >= _terminal.buffer.lines.length) {
      return offset;
    }
    if (offset.x <= 0 || offset.x >= _terminal.viewWidth) {
      return offset;
    }
    final line = _terminal.buffer.lines[offset.y];
    if (line.getCodePoint(offset.x) == 0 && line.getWidth(offset.x - 1) == 2) {
      return CellOffset(offset.x - 1, offset.y);
    }
    return offset;
  }

  CellOffset _snapToCellEnd(CellOffset offset) {
    if (offset.y < 0 || offset.y >= _terminal.buffer.lines.length) {
      return offset;
    }
    if (offset.x < 0 || offset.x >= _terminal.viewWidth) {
      return offset;
    }
    final line = _terminal.buffer.lines[offset.y];
    if (offset.x > 0 &&
        line.getCodePoint(offset.x) == 0 &&
        line.getWidth(offset.x - 1) == 2) {
      return CellOffset(offset.x + 1, offset.y);
    }
    final width = line.getWidth(offset.x);
    if (width > 1) {
      return CellOffset(
        (offset.x + width).clamp(0, _terminal.viewWidth),
        offset.y,
      );
    }
    return CellOffset(
      (offset.x + 1).clamp(0, _terminal.viewWidth),
      offset.y,
    );
  }

  /// Selects entire words in the terminal that contains [from] and [to].
  void selectWord(Offset from, [Offset? to]) {
    final fromOffset = _snapToCellHead(getCellOffset(from));
    final fromBoundary = _terminal.buffer.getWordBoundary(fromOffset);
    if (fromBoundary == null) return;
    if (to == null) {
      _controller.setSelection(
        _terminal.buffer.createAnchorFromOffset(fromBoundary.begin),
        _terminal.buffer.createAnchorFromOffset(fromBoundary.end),
        mode: SelectionMode.line,
      );
    } else {
      final toOffset = _snapToCellHead(getCellOffset(to));
      final toBoundary = _terminal.buffer.getWordBoundary(toOffset);
      if (toBoundary == null) return;
      final range = fromBoundary.merge(toBoundary);
      _controller.setSelection(
        _terminal.buffer.createAnchorFromOffset(range.begin),
        _terminal.buffer.createAnchorFromOffset(range.end),
        mode: SelectionMode.line,
      );
    }
  }

  /// Selects characters in the terminal that starts from [from] to [to]. At
  /// least one cell is selected even if [from] and [to] are same.
  void selectCharacters(
    Offset from, [
    Offset? to,
    SelectionMode mode = SelectionMode.line,
  ]) {
    final fromCell = _getCellOffset(from, clamp: true);
    final fromHead = _snapToCellHead(fromCell);
    final fromEnd = _snapToCellEnd(fromCell);
    if (to == null) {
      _controller.setSelection(
        _terminal.buffer.createAnchorFromOffset(fromHead),
        _terminal.buffer.createAnchorFromOffset(fromEnd),
        mode: mode,
      );
    } else {
      final rawToPosition = _getCellOffset(to, clamp: false);
      final toCell = CellOffset(
        rawToPosition.x.clamp(0, _terminal.viewWidth - 1),
        rawToPosition.y.clamp(0, _terminal.buffer.lines.length - 1),
      );
      final extendsForward = rawToPosition.y > fromHead.y ||
          (rawToPosition.y == fromHead.y && rawToPosition.x >= fromHead.x);
      final base = extendsForward ? fromHead : fromEnd;
      final extent =
          extendsForward ? _snapToCellEnd(toCell) : _snapToCellHead(toCell);
      _controller.setSelection(
        _terminal.buffer.createAnchorFromOffset(base),
        _terminal.buffer.createAnchorFromOffset(extent),
        mode: mode,
      );
    }
  }

  /// Send a mouse event at [offset] with [button] being currently in [buttonState].
  bool mouseEvent(
    TerminalMouseButton button,
    TerminalMouseButtonState buttonState,
    Offset offset,
  ) {
    final position = getCellOffset(offset);
    return _terminal.mouseInput(button, buttonState, position);
  }

  void _notifyEditableRect() {
    final cursor = localToGlobal(cursorOffset);

    final rect = Rect.fromLTRB(
      cursor.dx,
      cursor.dy,
      size.width,
      cursor.dy + _painter.cellSize.height,
    );

    final caretRect = cursor & _painter.cellSize;

    _onEditableRect?.call(rect, caretRect);
  }

  /// Update the viewport size in cells based on the current widget size in
  /// pixels.
  void _updateViewportSize() {
    if (size <= _painter.cellSize) {
      return;
    }

    final cols = size.width ~/ _painter.cellSize.width;
    final rows = _viewportHeight ~/ _painter.cellSize.height;

    // Only ignore a TRULY degenerate layout: a route-animation sliver that
    // floors to ~1 col (→ 竖排). The earlier <20-col floor was WRONG — a large
    // font makes a phone's viewport a LEGIT narrow one (well under 20 cols), and
    // blocking it left the Terminal stuck at the default 80, so its real
    // viewport was never recorded (adoptSize then sends 80) and content
    // overflowed. cols<2 still stops 竖排; the 120ms debounce on onResize
    // absorbs the brief mid-animation narrow frames so the host PTY doesn't
    // thrash. Orthogonal to the size negotiation — only filters the 1-col value.
    if (cols < 2 || rows < 2) {
      return;
    }

    final viewportSize = TerminalSize(cols, rows);

    if (_viewportSize != viewportSize) {
      _viewportSize = viewportSize;
      _resizeTerminalIfNeeded();
    }
  }

  /// Notify the underlying terminal that the viewport size has changed.
  void _resizeTerminalIfNeeded() {
    if (_autoResize && _viewportSize != null) {
      _terminal.resize(
        _viewportSize!.width,
        _viewportSize!.height,
        _painter.cellSize.width.round(),
        _painter.cellSize.height.round(),
      );
    }
  }

  /// Update the scroll offset based on the current terminal state. This should
  /// be called in [performLayout] after the viewport size has been updated.
  void _updateScrollOffset() {
    _offset.applyViewportDimension(_viewportHeight);
    _offset.applyContentDimensions(0, _maxScrollExtent);
  }

  bool get _isComposingText {
    return _composingText != null && _composingText!.isNotEmpty;
  }

  bool get _shouldShowCursor {
    return _terminal.cursorVisibleMode || _alwaysShowCursor || _isComposingText;
  }

  double get _viewportHeight {
    return size.height - _padding.vertical;
  }

  double get _maxScrollExtent {
    return max(_terminalHeight - _viewportHeight, 0.0);
  }

  double get _lineOffset {
    return -_scrollOffset + _padding.top;
  }

  /// The offset of the cursor from the top left corner of this render object.
  Offset get cursorOffset {
    return Offset(
      _terminal.buffer.cursorX * _painter.cellSize.width,
      _terminal.buffer.absoluteCursorY * _painter.cellSize.height + _lineOffset,
    );
  }

  Size get cellSize {
    return _painter.cellSize;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    _paint(context, offset);
    context.setWillChangeHint();
  }

  void _paint(PaintingContext context, Offset offset) {
    final canvas = context.canvas;
    final profile = debugProfilePaint ? TerminalRenderProfile() : null;
    final paintReason = _nextPaintReason;
    if (profile == null) {
      lastPaintProfile = null;
    } else {
      profile.paintReason = paintReason;
    }

    final lines = _terminal.buffer.lines;
    final charHeight = _painter.cellSize.height;

    final firstLineOffset = _scrollOffset - _padding.top;
    final lastLineOffset = _scrollOffset + size.height + _padding.bottom;

    final firstLine = firstLineOffset ~/ charHeight;
    final lastLine = lastLineOffset ~/ charHeight;

    final effectFirstLine = firstLine.clamp(0, lines.length - 1);
    final effectLastLine = lastLine.clamp(0, lines.length - 1);
    profile?.visibleLines = effectLastLine - effectFirstLine + 1;
    _overlayDirtyRows.resize(lines.length);
    _markOverlayDirtyRows(paintReason, effectFirstLine, effectLastLine);
    profile?.overlayDirtyRows = _overlayDirtyRows.countDirtyInRange(
      effectFirstLine,
      effectLastLine + 1,
    );
    profile?.overlayAnyDirty = _overlayDirtyRows.anyDirty;
    _pruneLinePictureCache(effectFirstLine, effectLastLine);
    profile?.cacheEntriesBeforePaint = _linePictureCache.length;

    _paintContentLayer(
      canvas,
      offset,
      effectFirstLine,
      effectLastLine,
      profile,
      validateSignature: _contentMayHaveChanged(paintReason),
    );
    _pruneLinePictureCache(effectFirstLine, effectLastLine);
    profile?.cachedPictures = _linePictureCache.length;

    _paintOverlayLayer(
      canvas,
      offset,
      effectFirstLine,
      effectLastLine,
      profile,
      trustCleanRows: !_contentMayHaveChanged(paintReason),
    );

    if (debugProfilePaint) {
      lastPaintProfile = profile;
    }
    _rememberOverlayState();
    _overlayDirtyRows.clear();
    _nextPaintReason = TerminalPaintReason.unknown;
  }

  void _markOverlayDirtyRows(
    TerminalPaintReason reason,
    int firstLine,
    int lastLine,
  ) {
    switch (reason) {
      case TerminalPaintReason.controller:
        _markSelectionDirtyRows(firstLine, lastLine);
        _markHighlightDirtyRows(firstLine, lastLine);
      case TerminalPaintReason.focus:
      case TerminalPaintReason.cursor:
      case TerminalPaintReason.composingText:
        _markCursorDirtyRow(firstLine, lastLine);
      case TerminalPaintReason.terminal:
      case TerminalPaintReason.scroll:
      case TerminalPaintReason.style:
      case TerminalPaintReason.theme:
      case TerminalPaintReason.layout:
      case TerminalPaintReason.initial:
      case TerminalPaintReason.unknown:
        break;
    }
  }

  void _markCursorDirtyRow(int firstLine, int lastLine) {
    final previousRow = _lastOverlayCursorRow;
    if (previousRow != null &&
        previousRow >= firstLine &&
        previousRow <= lastLine) {
      _overlayDirtyRows.markRow(previousRow);
    }
    if (_lastOverlayComposingText != _composingText && previousRow != null) {
      _overlayDirtyRows.markRow(previousRow);
    }
    final row = _terminal.buffer.absoluteCursorY;
    if (row < firstLine || row > lastLine) return;
    _overlayDirtyRows.markRow(row);
  }

  void _markSelectionDirtyRows(int firstLine, int lastLine) {
    final previous = _lastOverlaySelection?.normalized;
    if (previous != null) {
      _markRangeDirtyRows(previous, firstLine, lastLine);
    }
    final selection = _controller.selection?.normalized;
    if (selection == null) return;
    _markRangeDirtyRows(selection, firstLine, lastLine);
  }

  void _markRangeDirtyRows(BufferRange range, int firstLine, int lastLine) {
    _overlayDirtyRows.markRange(
      range.begin.y.clamp(firstLine, lastLine + 1),
      (range.end.y + 1).clamp(firstLine, lastLine + 1),
    );
  }

  void _markHighlightDirtyRows(int firstLine, int lastLine) {
    for (final range in _lastOverlayHighlights) {
      _markRangeDirtyRows(range.normalized, firstLine, lastLine);
    }
    for (final highlight in _controller.highlights) {
      final range = highlight.range?.normalized;
      if (range == null) continue;
      _markRangeDirtyRows(range, firstLine, lastLine);
    }
  }

  void _rememberOverlayState() {
    _lastOverlaySelection = _controller.selection?.normalized;
    _lastOverlayHighlights = [
      for (final highlight in _controller.highlights)
        if (highlight.range != null) highlight.range!.normalized,
    ];
    _lastOverlayCursorRow = _terminal.buffer.absoluteCursorY;
    _lastOverlayComposingText = _composingText;
  }

  void _paintContentLayer(
    Canvas canvas,
    Offset offset,
    int firstLine,
    int lastLine,
    TerminalRenderProfile? profile, {
    required bool validateSignature,
  }) {
    final geometrySignature = Object.hash(
      firstLine,
      lastLine,
      size.width,
      size.height,
      _lineOffset,
      _painter.cellSize.width,
      _painter.cellSize.height,
    );
    final contentSignature = validateSignature
        ? _viewportContentSignature(firstLine, lastLine, geometrySignature)
        : null;
    var cache = _viewportContentCache;
    final cacheHit = cache != null &&
        cache.geometrySignature == geometrySignature &&
        (!validateSignature || cache.contentSignature == contentSignature);
    if (cacheHit) {
      profile?.viewportContentCacheHits++;
    } else {
      profile?.viewportContentCacheMisses++;
      cache?.dispose();
      final recorder = PictureRecorder();
      final contentCanvas = Canvas(recorder, Offset.zero & size);
      final lines = _terminal.buffer.lines;
      final charHeight = _painter.cellSize.height;

      for (var i = firstLine; i <= lastLine; i++) {
        _paintCachedLine(
          contentCanvas,
          Offset(0, (i * charHeight + _lineOffset).truncateToDouble()),
          i,
          lines[i],
          profile,
          validateSignature: validateSignature,
        );
      }

      cache = _ViewportContentCache(
        geometrySignature: geometrySignature,
        contentSignature: contentSignature ??
            _viewportContentSignature(
              firstLine,
              lastLine,
              geometrySignature,
            ),
        picture: recorder.endRecording(),
      );
      _viewportContentCache = cache;
    }

    canvas.save();
    canvas.translate(offset.dx, offset.dy);
    canvas.drawPicture(cache.picture);
    profile?.viewportContentPictureDraws++;
    canvas.restore();
  }

  int _viewportContentSignature(
    int firstLine,
    int lastLine,
    int geometrySignature,
  ) {
    var signature = geometrySignature;
    final lines = _terminal.buffer.lines;
    for (var i = firstLine; i <= lastLine; i++) {
      final line = lines[i];
      signature = Object.hash(
        signature,
        i,
        line.length,
        line.isWrapped,
        line.revision,
      );
    }
    return signature;
  }

  void _paintOverlayLayer(
    Canvas canvas,
    Offset offset,
    int firstLine,
    int lastLine,
    TerminalRenderProfile? profile, {
    required bool trustCleanRows,
  }) {
    _pruneOverlayRowPictureCache(firstLine, lastLine);
    final rangeSegmentsCache = <BufferRange, List<BufferSegment>>{};
    final segmentSignatureCache = <BufferRange, Map<int, int>>{};
    final charHeight = _painter.cellSize.height;
    for (var row = firstLine; row <= lastLine; row++) {
      var entry = _overlayRowPictureCache[row];
      if (trustCleanRows && !_overlayDirtyRows.isDirty(row) && entry != null) {
        profile?.overlayRowSignatureSkips++;
        profile?.overlayRowCacheHits++;
        _drawOverlayRowPicture(canvas, offset, row, charHeight, entry, profile);
        continue;
      }

      final signature = _overlayRowSignature(
        row,
        rangeSegmentsCache,
        segmentSignatureCache,
      );
      if (entry == null || entry.signature != signature) {
        profile?.overlayRowCacheMisses++;
        entry?.dispose();
        Picture? picture;
        if (signature != 0) {
          final recorder = PictureRecorder();
          final rowCanvas = Canvas(
            recorder,
            Rect.fromLTWH(0, 0, size.width, charHeight),
          );
          _paintOverlayRow(
            rowCanvas,
            Offset(0, -row * charHeight - _lineOffset),
            row,
            profile,
          );
          picture = recorder.endRecording();
        }
        entry = _OverlayRowPictureCache(signature, picture);
        _overlayRowPictureCache[row] = entry;
      } else {
        profile?.overlayRowCacheHits++;
      }

      _drawOverlayRowPicture(canvas, offset, row, charHeight, entry, profile);
    }
    _pruneOverlayRowPictureCache(firstLine, lastLine);
  }

  void _drawOverlayRowPicture(
    Canvas canvas,
    Offset offset,
    int row,
    double charHeight,
    _OverlayRowPictureCache entry,
    TerminalRenderProfile? profile,
  ) {
    final picture = entry.picture;
    if (picture == null) {
      return;
    }
    canvas.save();
    canvas.translate(
      offset.dx,
      offset.dy + (row * charHeight + _lineOffset).truncateToDouble(),
    );
    canvas.drawPicture(picture);
    profile?.overlayRowPictureDraws++;
    canvas.restore();
  }

  void _paintOverlayRow(
    Canvas canvas,
    Offset offset,
    int row,
    TerminalRenderProfile? profile,
  ) {
    if (_terminal.buffer.absoluteCursorY == row) {
      if (_isComposingText) {
        _paintComposingText(canvas, offset + cursorOffset);
        profile?.composingPaints++;
      }

      if (_shouldShowCursor) {
        _painter.paintCursor(
          canvas,
          offset + cursorOffset,
          cursorType: _cursorType,
          hasFocus: _focusNode.hasFocus,
        );
        profile?.cursorPaints++;
      }
    }

    _paintHighlights(
      canvas,
      offset,
      _controller.highlights,
      row,
      row,
      profile,
    );

    final selection = _controller.selection;
    if (selection != null) {
      _paintSelection(
        canvas,
        offset,
        selection,
        row,
        row,
        profile,
      );
    }
  }

  int _overlayRowSignature(
    int row,
    Map<BufferRange, List<BufferSegment>> rangeSegmentsCache,
    Map<BufferRange, Map<int, int>> segmentSignatureCache,
  ) {
    var signature = 0;

    for (final highlight in _controller.highlights) {
      final range = highlight.range?.normalized;
      if (range == null || range.begin.y > row || range.end.y < row) {
        continue;
      }
      signature = Object.hash(
        signature,
        'h',
        highlight.color,
        _segmentSignatureForRangeRow(
          range,
          row,
          rangeSegmentsCache,
          segmentSignatureCache,
        ),
      );
    }

    final selection = _controller.selection?.normalized;
    if (selection != null &&
        selection.begin.y <= row &&
        selection.end.y >= row) {
      signature = Object.hash(
        signature,
        's',
        _painter.theme.selection,
        _segmentSignatureForRangeRow(
          selection,
          row,
          rangeSegmentsCache,
          segmentSignatureCache,
        ),
      );
    }

    if (_terminal.buffer.absoluteCursorY == row) {
      if (_isComposingText) {
        signature = Object.hash(
          signature,
          'i',
          _composingText,
          _terminal.cursor.foreground,
          _painter.paintRevision,
          _painter.cellSize.width,
          _painter.cellSize.height,
          _painter.textScaler,
        );
      }

      if (_shouldShowCursor) {
        signature = Object.hash(
          signature,
          'c',
          _terminal.buffer.cursorX,
          _cursorType,
          _focusNode.hasFocus,
          _painter.paintRevision,
          _painter.cellSize.width,
          _painter.cellSize.height,
        );
      }
    }

    if (signature == 0) {
      return 0;
    }
    return Object.hash(signature, row, size.width, _painter.paintRevision);
  }

  int _segmentSignatureForRangeRow(
    BufferRange range,
    int row,
    Map<BufferRange, List<BufferSegment>> rangeSegmentsCache,
    Map<BufferRange, Map<int, int>> cache,
  ) {
    final rowCache = cache.putIfAbsent(range, () => <int, int>{});
    final cached = rowCache[row];
    if (cached != null) {
      return cached;
    }
    final segments = rangeSegmentsCache.putIfAbsent(
      range,
      () => range.toSegments().toList(growable: false),
    );
    final signature = _segmentSignatureForRow(segments, row);
    rowCache[row] = signature;
    return signature;
  }

  int _segmentSignatureForRow(Iterable<BufferSegment> segments, int row) {
    var signature = 0;
    for (final segment in segments) {
      if (segment.line < row) {
        continue;
      }
      if (segment.line > row) {
        break;
      }
      final start = (segment.start ?? 0).clamp(0, _terminal.viewWidth).toInt();
      final end = (segment.end ?? _terminal.viewWidth)
          .clamp(0, _terminal.viewWidth)
          .toInt();
      if (end <= start) {
        continue;
      }
      signature = Object.hash(signature, start, end);
    }
    return signature;
  }

  /// Paints the text that is currently being composed in IME to [canvas] at
  /// [offset]. [offset] is usually the cursor position.
  void _paintComposingText(Canvas canvas, Offset offset) {
    final composingText = _composingText;
    if (composingText == null) {
      return;
    }

    final style = _painter.textStyle.toTextStyle(
      color: _painter.resolveForegroundColor(_terminal.cursor.foreground),
      backgroundColor: _painter.theme.background,
      underline: true,
    );

    final builder = ParagraphBuilder(style.getParagraphStyle());
    builder.addPlaceholder(
      offset.dx,
      _painter.cellSize.height,
      PlaceholderAlignment.middle,
    );
    builder.pushStyle(
      style.getTextStyle(textScaler: _painter.textScaler),
    );
    builder.addText(composingText);

    final paragraph = builder.build();
    paragraph.layout(ParagraphConstraints(width: size.width));

    canvas.drawParagraph(paragraph, Offset(0, offset.dy));
    paragraph.dispose();
  }

  void _paintCachedLine(
    Canvas canvas,
    Offset offset,
    int lineIndex,
    BufferLine line,
    TerminalRenderProfile? profile, {
    required bool validateSignature,
  }) {
    var entry = _linePictureCache[lineIndex];
    if (entry != null && !validateSignature) {
      profile?.lineSignatureSkips++;
      profile?.lineCacheHits++;
    } else {
      final signature = _linePaintSignature(line);
      profile?.lineSignatureChecks++;
      if (entry?.signature != signature) {
        profile?.lineCacheMisses++;
        entry?.dispose();
        if (_isBlankLine(line)) {
          entry = _LinePictureCache(signature);
          _linePictureCache[lineIndex] = entry;
          profile?.blankLines++;
          return;
        }
        if (!_shouldCacheLine(lineIndex, line)) {
          _linePictureCache.remove(lineIndex);
          _paintUncachedLine(canvas, offset, line, profile);
          return;
        }
        final recorder = PictureRecorder();
        final lineCanvas = Canvas(
          recorder,
          Rect.fromLTWH(
            0,
            0,
            line.length * _painter.cellSize.width,
            _painter.cellSize.height,
          ),
        );
        _painter.paintLine(
          lineCanvas,
          Offset.zero,
          line,
          collectProfile: profile != null,
        );
        if (profile != null) {
          final painterProfile = _painter.takeProfile();
          if (painterProfile != null) {
            profile
              ..backgroundRuns += painterProfile.backgroundRuns
              ..asciiRuns += painterProfile.asciiRuns
              ..asciiRunFallbacks += painterProfile.asciiRunFallbacks
              ..renderPlanCacheHits += painterProfile.renderPlanCacheHits
              ..renderPlanCacheMisses += painterProfile.renderPlanCacheMisses
              ..glyphPictureCacheHits += painterProfile.glyphPictureCacheHits
              ..glyphPictureCacheMisses +=
                  painterProfile.glyphPictureCacheMisses
              ..glyphRunPictureCacheHits +=
                  painterProfile.glyphRunPictureCacheHits
              ..glyphRunPictureCacheMisses +=
                  painterProfile.glyphRunPictureCacheMisses
              ..paragraphCacheHits += painterProfile.paragraphCacheHits
              ..paragraphCacheMisses += painterProfile.paragraphCacheMisses
              ..runParagraphCacheHits += painterProfile.runParagraphCacheHits
              ..runParagraphCacheMisses +=
                  painterProfile.runParagraphCacheMisses
              ..singleCells += painterProfile.singleCells
              ..blankLines += painterProfile.blankLines;
          }
        }
        entry = _LinePictureCache(signature, recorder.endRecording());
        _linePictureCache[lineIndex] = entry;
      } else {
        profile?.lineCacheHits++;
      }
    }
    entry = entry!;

    final picture = entry.picture;
    if (picture == null) {
      return;
    }
    canvas.save();
    canvas.translate(offset.dx, offset.dy);
    canvas.drawPicture(picture);
    profile?.contentPicturesDrawn++;
    canvas.restore();
  }

  bool _contentMayHaveChanged(TerminalPaintReason reason) {
    switch (reason) {
      case TerminalPaintReason.terminal:
      case TerminalPaintReason.style:
      case TerminalPaintReason.theme:
      case TerminalPaintReason.layout:
      case TerminalPaintReason.initial:
      case TerminalPaintReason.unknown:
        return true;
      case TerminalPaintReason.controller:
      case TerminalPaintReason.scroll:
      case TerminalPaintReason.focus:
      case TerminalPaintReason.cursor:
      case TerminalPaintReason.composingText:
        return false;
    }
  }

  int _linePaintSignature(BufferLine line) {
    return Object.hash(
      _painter.paintRevision,
      line.length,
      line.isWrapped,
      _painter.cellSize.width,
      _painter.cellSize.height,
      line.revision,
    );
  }

  void _paintUncachedLine(
    Canvas canvas,
    Offset offset,
    BufferLine line,
    TerminalRenderProfile? profile,
  ) {
    _painter.paintLine(canvas, offset, line, collectProfile: profile != null);
    final painterProfile = profile == null ? null : _painter.takeProfile();
    final renderProfile = profile;
    if (renderProfile != null && painterProfile != null) {
      renderProfile.uncachedLines++;
      renderProfile
        ..backgroundRuns += painterProfile.backgroundRuns
        ..asciiRuns += painterProfile.asciiRuns
        ..asciiRunFallbacks += painterProfile.asciiRunFallbacks
        ..renderPlanCacheHits += painterProfile.renderPlanCacheHits
        ..renderPlanCacheMisses += painterProfile.renderPlanCacheMisses
        ..glyphPictureCacheHits += painterProfile.glyphPictureCacheHits
        ..glyphPictureCacheMisses += painterProfile.glyphPictureCacheMisses
        ..glyphRunPictureCacheHits += painterProfile.glyphRunPictureCacheHits
        ..glyphRunPictureCacheMisses +=
            painterProfile.glyphRunPictureCacheMisses
        ..paragraphCacheHits += painterProfile.paragraphCacheHits
        ..paragraphCacheMisses += painterProfile.paragraphCacheMisses
        ..runParagraphCacheHits += painterProfile.runParagraphCacheHits
        ..runParagraphCacheMisses += painterProfile.runParagraphCacheMisses
        ..singleCells += painterProfile.singleCells
        ..blankLines += painterProfile.blankLines;
    }
  }

  bool _shouldCacheLine(int lineIndex, BufferLine line) {
    if (!_linePictureCache.containsKey(lineIndex) &&
        _linePictureCache.length >= _maxCachedLinePictures) {
      return false;
    }
    final pixels =
        line.length * _painter.cellSize.width * _painter.cellSize.height;
    return pixels <= _maxCachedLinePicturePixels;
  }

  bool _isBlankLine(BufferLine line) {
    for (var i = 0; i < line.length; i++) {
      final content = line.getContent(i);
      if ((content & CellContent.codepointMask) != 0) {
        return false;
      }
      final flags = line.getAttributes(i);
      if ((flags & CellFlags.inverse) != 0) {
        return false;
      }
      final background = line.getBackground(i);
      if ((background & CellColor.typeMask) != CellColor.normal) {
        return false;
      }
    }
    return true;
  }

  void _pruneLinePictureCache(int firstLine, int lastLine) {
    _linePictureCache.removeWhere((line, entry) {
      final remove = line < firstLine || line > lastLine;
      if (remove) entry.dispose();
      return remove;
    });
  }

  void _clearLinePictureCache() {
    _clearViewportContentCache();
    for (final entry in _linePictureCache.values) {
      entry.dispose();
    }
    _linePictureCache.clear();
  }

  void _pruneOverlayRowPictureCache(int firstLine, int lastLine) {
    _overlayRowPictureCache.removeWhere((line, entry) {
      final remove = line < firstLine || line > lastLine;
      if (remove) entry.dispose();
      return remove;
    });
  }

  void _clearOverlayRowPictureCache() {
    for (final entry in _overlayRowPictureCache.values) {
      entry.dispose();
    }
    _overlayRowPictureCache.clear();
  }

  void _clearViewportContentCache() {
    _viewportContentCache?.dispose();
    _viewportContentCache = null;
  }

  void _paintSelection(
    Canvas canvas,
    Offset offset,
    BufferRange selection,
    int firstLine,
    int lastLine,
    TerminalRenderProfile? profile,
  ) {
    final runs = _paintSegmentRuns(
      canvas,
      offset,
      selection.toSegments(),
      _painter.theme.selection,
      firstLine,
      lastLine,
    );
    profile?.selectionRuns += runs;
  }

  void _paintHighlights(
    Canvas canvas,
    Offset offset,
    List<TerminalHighlight> highlights,
    int firstLine,
    int lastLine,
    TerminalRenderProfile? profile,
  ) {
    for (var highlight in _controller.highlights) {
      final range = highlight.range?.normalized;

      if (range == null ||
          range.begin.y > lastLine ||
          range.end.y < firstLine) {
        continue;
      }

      final runs = _paintSegmentRuns(
        canvas,
        offset,
        range.toSegments(),
        highlight.color,
        firstLine,
        lastLine,
      );
      profile?.highlightRuns += runs;
    }
  }

  int _paintSegmentRuns(
    Canvas canvas,
    Offset offset,
    Iterable<BufferSegment> segments,
    Color color,
    int firstLine,
    int lastLine,
  ) {
    int? runLine;
    var runStart = 0;
    var runEnd = 0;
    var paintedRuns = 0;

    void flush() {
      final line = runLine;
      if (line == null || runEnd <= runStart) return;
      _paintSegmentRect(canvas, offset, line, runStart, runEnd, color);
      paintedRuns++;
      runLine = null;
    }

    for (final segment in segments) {
      if (segment.line >= _terminal.buffer.lines.length) {
        break;
      }
      if (segment.line < firstLine) {
        continue;
      }
      if (segment.line > lastLine) {
        break;
      }

      final start = (segment.start ?? 0).clamp(0, _terminal.viewWidth).toInt();
      final end = (segment.end ?? _terminal.viewWidth)
          .clamp(0, _terminal.viewWidth)
          .toInt();
      if (end <= start) {
        continue;
      }

      if (runLine == segment.line && start <= runEnd) {
        if (end > runEnd) {
          runEnd = end;
        }
        continue;
      }

      flush();
      runLine = segment.line;
      runStart = start;
      runEnd = end;
    }

    flush();
    return paintedRuns;
  }

  @pragma('vm:prefer-inline')
  void _paintSegmentRect(
    Canvas canvas,
    Offset offset,
    int line,
    int start,
    int end,
    Color color,
  ) {
    final startOffset = Offset(
      offset.dx + start * _painter.cellSize.width,
      offset.dy + line * _painter.cellSize.height + _lineOffset,
    );

    _painter.paintHighlight(canvas, startOffset, end - start, color);
  }
}

enum TerminalPaintReason {
  initial,
  unknown,
  terminal,
  controller,
  scroll,
  focus,
  cursor,
  composingText,
  style,
  theme,
  layout,
}

class TerminalRenderProfile {
  var paintReason = TerminalPaintReason.initial;
  var visibleLines = 0;
  var overlayDirtyRows = 0;
  var overlayAnyDirty = false;
  var cacheEntriesBeforePaint = 0;
  var lineSignatureChecks = 0;
  var lineSignatureSkips = 0;
  var lineCacheHits = 0;
  var lineCacheMisses = 0;
  var cachedPictures = 0;
  var viewportContentCacheHits = 0;
  var viewportContentCacheMisses = 0;
  var viewportContentPictureDraws = 0;
  var contentPicturesDrawn = 0;
  var overlayRowCacheHits = 0;
  var overlayRowCacheMisses = 0;
  var overlayRowSignatureSkips = 0;
  var overlayRowPictureDraws = 0;
  var cursorPaints = 0;
  var composingPaints = 0;
  var selectionRuns = 0;
  var highlightRuns = 0;
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
  var uncachedLines = 0;

  @override
  String toString() {
    return 'TerminalRenderProfile('
        'paintReason: $paintReason, '
        'visibleLines: $visibleLines, '
        'overlayDirtyRows: $overlayDirtyRows, '
        'overlayAnyDirty: $overlayAnyDirty, '
        'cacheEntriesBeforePaint: $cacheEntriesBeforePaint, '
        'lineSignatureChecks: $lineSignatureChecks, '
        'lineSignatureSkips: $lineSignatureSkips, '
        'lineCacheHits: $lineCacheHits, '
        'lineCacheMisses: $lineCacheMisses, '
        'cachedPictures: $cachedPictures, '
        'viewportContentCacheHits: $viewportContentCacheHits, '
        'viewportContentCacheMisses: $viewportContentCacheMisses, '
        'viewportContentPictureDraws: $viewportContentPictureDraws, '
        'contentPicturesDrawn: $contentPicturesDrawn, '
        'overlayRowCacheHits: $overlayRowCacheHits, '
        'overlayRowCacheMisses: $overlayRowCacheMisses, '
        'overlayRowSignatureSkips: $overlayRowSignatureSkips, '
        'overlayRowPictureDraws: $overlayRowPictureDraws, '
        'cursorPaints: $cursorPaints, '
        'composingPaints: $composingPaints, '
        'selectionRuns: $selectionRuns, '
        'highlightRuns: $highlightRuns, '
        'backgroundRuns: $backgroundRuns, '
        'asciiRuns: $asciiRuns, '
        'asciiRunFallbacks: $asciiRunFallbacks, '
        'renderPlanCacheHits: $renderPlanCacheHits, '
        'renderPlanCacheMisses: $renderPlanCacheMisses, '
        'glyphPictureCacheHits: $glyphPictureCacheHits, '
        'glyphPictureCacheMisses: $glyphPictureCacheMisses, '
        'glyphRunPictureCacheHits: $glyphRunPictureCacheHits, '
        'glyphRunPictureCacheMisses: $glyphRunPictureCacheMisses, '
        'paragraphCacheHits: $paragraphCacheHits, '
        'paragraphCacheMisses: $paragraphCacheMisses, '
        'runParagraphCacheHits: $runParagraphCacheHits, '
        'runParagraphCacheMisses: $runParagraphCacheMisses, '
        'singleCells: $singleCells, '
        'blankLines: $blankLines, '
        'uncachedLines: $uncachedLines)';
  }
}

class _RowDirtyTracker {
  var _rows = Uint8List(0);
  var _anyDirty = false;

  bool get anyDirty => _anyDirty;

  void clear() {
    if (!_anyDirty) return;
    _rows.fillRange(0, _rows.length, 0);
    _anyDirty = false;
  }

  int countDirtyInRange(int from, int toExclusive) {
    final start = from < 0 ? 0 : from;
    final end = toExclusive > _rows.length ? _rows.length : toExclusive;
    if (start >= end) return 0;
    var count = 0;
    for (var i = start; i < end; i++) {
      if (_rows[i] != 0) count++;
    }
    return count;
  }

  bool isDirty(int row) {
    return row >= 0 && row < _rows.length && _rows[row] != 0;
  }

  void markRange(int from, int toExclusive) {
    final start = from < 0 ? 0 : from;
    final end = toExclusive > _rows.length ? _rows.length : toExclusive;
    if (start >= end) return;
    _rows.fillRange(start, end, 1);
    _anyDirty = true;
  }

  void markRow(int row) {
    if (row < 0 || row >= _rows.length) return;
    _rows[row] = 1;
    _anyDirty = true;
  }

  void resize(int rowCount) {
    if (_rows.length != rowCount) {
      _rows = Uint8List(rowCount);
    } else {
      _rows.fillRange(0, rowCount, 0);
    }
    _anyDirty = false;
  }
}

class _LinePictureCache {
  _LinePictureCache(this.signature, [this.picture]);

  final int signature;
  final Picture? picture;

  void dispose() {
    picture?.dispose();
  }
}

class _ViewportContentCache {
  _ViewportContentCache({
    required this.geometrySignature,
    required this.contentSignature,
    required this.picture,
  });

  final int geometrySignature;
  final int contentSignature;
  final Picture picture;

  void dispose() {
    picture.dispose();
  }
}

class _OverlayRowPictureCache {
  _OverlayRowPictureCache(this.signature, [this.picture]);

  final int signature;
  final Picture? picture;

  void dispose() {
    picture?.dispose();
  }
}
