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
    required double backgroundOpacity,
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
        _backgroundOpacity = backgroundOpacity,
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

  double _backgroundOpacity;
  set backgroundOpacity(double value) {
    if (value == _backgroundOpacity) return;
    _backgroundOpacity = value;
    _clearViewportContentCache();
    _markNeedsPaintFor(TerminalPaintReason.theme);
  }

  bool get _paintsOpaqueBackground => _backgroundOpacity >= 1.0;

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
  final _contentCommandBuffer = _RenderCommandBuffer();
  final _overlayCommandBuffer = _RenderCommandBuffer();
  final _lineCommandBuildBuffer = _RenderCommandBuffer();
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
    _controller.pruneSelectionOffsets(_terminal.buffer.lines.length);
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
    _mergeNextPaintReason(reason);
    markNeedsPaint();
  }

  void _markNeedsLayoutFor(TerminalPaintReason reason) {
    if (_invalidatesContentLayer(reason)) {
      _clearViewportContentCache();
    }
    _mergeNextPaintReason(reason);
    markNeedsLayout();
  }

  void _mergeNextPaintReason(TerminalPaintReason reason) {
    if (_paintReasonPriority(reason) >=
        _paintReasonPriority(_nextPaintReason)) {
      _nextPaintReason = reason;
    }
  }

  int _paintReasonPriority(TerminalPaintReason reason) {
    return switch (reason) {
      TerminalPaintReason.unknown => 0,
      TerminalPaintReason.controller ||
      TerminalPaintReason.focus ||
      TerminalPaintReason.cursor ||
      TerminalPaintReason.composingText =>
        1,
      TerminalPaintReason.scroll => 2,
      TerminalPaintReason.terminal => 3,
      TerminalPaintReason.style ||
      TerminalPaintReason.theme ||
      TerminalPaintReason.layout ||
      TerminalPaintReason.initial =>
        4,
    };
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
    _lineCommandBuildBuffer.clear();
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
  bool selectWord(Offset from, [Offset? to]) {
    final fromOffset = _snapToCellHead(getCellOffset(from));
    final fromBoundary = _terminal.buffer.getWordBoundary(fromOffset);
    if (fromBoundary == null) return false;
    if (to == null) {
      _controller.setSelectionOffsets(
        fromBoundary.begin,
        fromBoundary.end,
        mode: SelectionMode.line,
      );
    } else {
      final toOffset = _snapToCellHead(getCellOffset(to));
      final toBoundary = _terminal.buffer.getWordBoundary(toOffset);
      if (toBoundary == null) return false;
      final range = fromBoundary.merge(toBoundary);
      _controller.setSelectionOffsets(
        range.begin,
        range.end,
        mode: SelectionMode.line,
      );
    }
    return true;
  }

  void selectLine(Offset offset) {
    final cell = getCellOffset(offset);
    final row = cell.y.clamp(0, _terminal.buffer.lines.length - 1);
    _controller.setSelectionOffsets(
      CellOffset(0, row),
      CellOffset(_terminal.viewWidth, row),
      mode: SelectionMode.line,
    );
  }

  /// Selects characters in the terminal that starts from [from] to [to]. At
  /// least one cell is selected even if [from] and [to] are same.
  void selectCharacters(
    Offset from, [
    Offset? to,
    SelectionMode mode = SelectionMode.line,
  ]) {
    selectCharactersFromCell(_getCellOffset(from, clamp: true), to, mode);
  }

  void selectCharactersFromCell(
    CellOffset fromCell, [
    Offset? to,
    SelectionMode mode = SelectionMode.line,
  ]) {
    final fromHead = _snapToCellHead(fromCell);
    final fromEnd = _snapToCellEnd(fromCell);
    if (to == null) {
      _controller.setSelectionOffsets(
        fromHead,
        fromEnd,
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
      _controller.setSelectionOffsets(
        base,
        extent,
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
      cacheViewport: _shouldCacheViewportContent(paintReason),
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
    required bool cacheViewport,
  }) {
    if (!cacheViewport) {
      _paintContentLinesDirectly(
        canvas,
        offset,
        firstLine,
        lastLine,
        profile,
        validateSignature: validateSignature,
      );
      return;
    }

    final geometrySignature = Object.hash(
      firstLine,
      lastLine,
      size.width,
      size.height,
      _lineOffset,
      _painter.cellSize.width,
      _painter.cellSize.height,
      _backgroundOpacity,
    );
    final contentSignature = validateSignature
        ? _viewportContentSignature(
            firstLine,
            lastLine,
            geometrySignature,
            profile,
          )
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
      final commands = _contentCommandBuffer..clear();

      for (var i = firstLine; i <= lastLine; i++) {
        _recordCachedLineCommand(
          contentCanvas,
          commands,
          Offset(0, _lineBandTop(i)),
          i,
          lines[i],
          profile,
          validateSignature: validateSignature,
        );
      }
      commands.draw(contentCanvas, Offset.zero, profile);
      commands.clear();

      cache = _ViewportContentCache(
        geometrySignature: geometrySignature,
        contentSignature: contentSignature ??
            _viewportContentSignature(
              firstLine,
              lastLine,
              geometrySignature,
              profile,
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

  bool _shouldCacheViewportContent(TerminalPaintReason reason) {
    switch (reason) {
      case TerminalPaintReason.terminal:
      case TerminalPaintReason.scroll:
        return false;
      case TerminalPaintReason.style:
      case TerminalPaintReason.theme:
      case TerminalPaintReason.layout:
      case TerminalPaintReason.initial:
      case TerminalPaintReason.unknown:
      case TerminalPaintReason.controller:
      case TerminalPaintReason.focus:
      case TerminalPaintReason.cursor:
      case TerminalPaintReason.composingText:
        return true;
    }
  }

  void _paintContentLinesDirectly(
    Canvas canvas,
    Offset offset,
    int firstLine,
    int lastLine,
    TerminalRenderProfile? profile, {
    required bool validateSignature,
  }) {
    final lines = _terminal.buffer.lines;
    final commands = _contentCommandBuffer..clear();
    profile?.viewportContentDirectDraws++;
    for (var i = firstLine; i <= lastLine; i++) {
      _recordCachedLineCommand(
        canvas,
        commands,
        offset.translate(0, _lineBandTop(i)),
        i,
        lines[i],
        profile,
        validateSignature: validateSignature,
      );
    }
    commands.draw(canvas, Offset.zero, profile);
    commands.clear();
  }

  int _viewportContentSignature(
    int firstLine,
    int lastLine,
    int geometrySignature,
    TerminalRenderProfile? profile,
  ) {
    var signature = geometrySignature;
    final lines = _terminal.buffer.lines;
    profile?.viewportContentSignatureRows += lastLine - firstLine + 1;
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
    final charHeight = _painter.cellSize.height;
    final commands = _overlayCommandBuffer..clear();
    for (var row = firstLine; row <= lastLine; row++) {
      var entry = _overlayRowPictureCache[row];
      if (trustCleanRows && !_overlayDirtyRows.isDirty(row) && entry != null) {
        profile?.overlayRowSignatureSkips++;
        profile?.overlayRowCacheHits++;
        _recordOverlayRowPictureCommand(
          commands,
          offset,
          row,
          entry,
        );
        continue;
      }

      final signature = _overlayPictureRowSignature(row);
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

      _recordOverlayRowPictureCommand(
        commands,
        offset,
        row,
        entry,
      );
    }
    _recordOverlayHighlightCommands(
      commands,
      offset,
      firstLine,
      lastLine,
      profile,
    );
    _recordOverlaySelectionCommands(
      commands,
      offset,
      firstLine,
      lastLine,
      profile,
    );
    commands.draw(canvas, Offset.zero, profile);
    commands.clear();
    _pruneOverlayRowPictureCache(firstLine, lastLine);
  }

  void _recordOverlayRowPictureCommand(
    _RenderCommandBuffer commands,
    Offset offset,
    int row,
    _OverlayRowPictureCache entry,
  ) {
    final picture = entry.picture;
    if (picture == null) {
      return;
    }
    commands.addPictureAt(
      picture,
      offset.dx,
      offset.dy + _lineBandTop(row),
      kind: _RenderCommandKind.overlay,
    );
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
  }

  int _overlayPictureRowSignature(int row) {
    var signature = 0;

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

  void _recordCachedLineCommand(
    Canvas canvas,
    _RenderCommandBuffer commands,
    Offset offset,
    int lineIndex,
    BufferLine line,
    TerminalRenderProfile? profile, {
    required bool validateSignature,
  }) {
    var entry = _linePictureCache[lineIndex];
    var recordedLineCommands = false;
    if (entry != null && !validateSignature && !line.hasDirtyRange) {
      profile?.lineSignatureSkips++;
      profile?.lineCacheHits++;
      if (entry.commandCache == null) {
        profile?.lineCommandCacheMisses++;
      } else {
        profile?.lineCommandCacheHits++;
      }
    } else {
      final signature = _linePaintSignature(line);
      profile?.lineSignatureChecks++;
      if (entry?.signature != signature) {
        profile?.lineCacheMisses++;
        profile?.lineCommandCacheMisses++;
        entry?.dispose();
        if (_isBlankLine(line)) {
          _recordLineDefaultBackgroundCommand(
            commands,
            offset,
            line,
            profile,
            height: _backgroundBandHeight(lineIndex),
          );
          entry = _LinePictureCache(
            signature,
            commandCache: _LineCommandCache.empty,
          );
          _linePictureCache[lineIndex] = entry;
          line.clearDirtyRange();
          profile?.blankLines++;
          return;
        }
        if (!_shouldCacheLine(lineIndex, line)) {
          _linePictureCache.remove(lineIndex);
          commands.draw(canvas, Offset.zero, profile);
          commands.clear();
          _paintUncachedLine(canvas, offset, lineIndex, line, profile);
          line.clearDirtyRange();
          return;
        }
        if (entry != null &&
            _canPartiallyRepaintLine(entry, line) &&
            _paintPartiallyDirtyLine(
              canvas,
              commands,
              offset,
              lineIndex,
              line,
              entry,
              profile,
            )) {
          return;
        }
        final lineCommands = _lineCommandBuildBuffer..clear();
        _recordLineBackgroundCommands(
          commands,
          offset,
          line,
          profile,
          height: _backgroundBandHeight(lineIndex),
        );
        final textRunsCoverForeground = _recordLineTextRunCommands(
          lineCommands,
          Offset.zero,
          line,
          profile,
        );
        final geometryRunsCoverForeground = _recordLineGeometryCommands(
          lineCommands,
          Offset.zero,
          line,
          profile,
        );
        final needsGeometryCommands = lineCommands.containsPictures;
        final commandCache = lineCommands.snapshot(skipPictures: true);
        lineCommands.replayInto(commands, offset);
        recordedLineCommands = true;
        lineCommands.clear();
        if (textRunsCoverForeground || geometryRunsCoverForeground) {
          entry = _LinePictureCache(
            signature,
            commandCache: commandCache,
            needsGeometryCommands: needsGeometryCommands,
          );
        } else {
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
            paintBackgrounds: false,
            paintTextRuns: false,
            paintGeometryRuns: false,
          );
          if (profile != null) {
            final painterProfile = _painter.takeProfile();
            if (painterProfile != null) {
              _mergePainterProfile(profile, painterProfile);
            }
          }
          entry = _LinePictureCache(
            signature,
            picture: recorder.endRecording(),
            commandCache: commandCache,
            needsGeometryCommands: needsGeometryCommands,
          );
        }
        _linePictureCache[lineIndex] = entry;
        line.clearDirtyRange();
      } else {
        profile?.lineCacheHits++;
        if (entry?.commandCache == null) {
          profile?.lineCommandCacheMisses++;
        } else {
          profile?.lineCommandCacheHits++;
        }
      }
    }
    entry = entry!;

    if (!recordedLineCommands) {
      final commandCache = entry.commandCache;
      if (commandCache == null) {
        _recordLineBackgroundCommands(
          commands,
          offset,
          line,
          profile,
          height: _backgroundBandHeight(lineIndex),
        );
        _recordLineTextRunCommands(commands, offset, line, profile);
        _recordLineGeometryCommands(commands, offset, line, profile);
      } else {
        _recordLineBackgroundCommands(
          commands,
          offset,
          line,
          profile,
          height: _backgroundBandHeight(lineIndex),
        );
        commandCache.replay(commands, offset);
        if (entry.needsGeometryCommands) {
          _recordLineGeometryCommands(commands, offset, line, profile);
        }
      }
    }

    final picture = entry.picture;
    if (picture == null) {
      return;
    }
    commands.addPicture(picture, offset);
  }

  bool _canPartiallyRepaintLine(_LinePictureCache entry, BufferLine line) {
    if (!line.hasDirtyRange) return false;
    if (entry.picture != null || entry.needsGeometryCommands) return false;
    if (entry.commandCache == null) return false;
    final dirtyCells = line.dirtyEnd - line.dirtyStart;
    if (dirtyCells <= 0) return false;
    return dirtyCells <= (line.length ~/ 2).clamp(8, 32);
  }

  bool _paintPartiallyDirtyLine(
    Canvas canvas,
    _RenderCommandBuffer commands,
    Offset offset,
    int lineIndex,
    BufferLine line,
    _LinePictureCache entry,
    TerminalRenderProfile? profile,
  ) {
    final commandCache = entry.commandCache;
    if (commandCache == null) return false;

    commands.draw(canvas, Offset.zero, profile);
    commands.clear();

    final cellWidth = _painter.cellSize.width;
    final start = (line.dirtyStart - 1).clamp(0, line.length).toInt();
    final end = (line.dirtyEnd + 1).clamp(0, line.length).toInt();
    if (end <= start) return false;

    final lineLeft = offset.dx;
    final lineRight = offset.dx + line.length * cellWidth;
    final dirtyLeft = offset.dx + start * cellWidth;
    final dirtyRight = offset.dx + end * cellWidth;
    final top = offset.dy;
    final bottom = offset.dy + _backgroundBandHeight(lineIndex);

    _recordLineBackgroundCommands(
      commands,
      offset,
      line,
      profile,
      height: _backgroundBandHeight(lineIndex),
    );
    commands.draw(canvas, Offset.zero, profile);
    commands.clear();

    void replayOldClip(double left, double right) {
      if (right <= left) return;
      canvas.save();
      canvas.clipRect(Rect.fromLTRB(left, top, right, bottom));
      commandCache.replay(commands, offset);
      commands.draw(canvas, Offset.zero, profile);
      commands.clear();
      canvas.restore();
    }

    replayOldClip(lineLeft, dirtyLeft);
    replayOldClip(dirtyRight, lineRight);

    canvas.save();
    canvas.clipRect(Rect.fromLTRB(dirtyLeft, top, dirtyRight, bottom));
    _paintUncachedLine(canvas, offset, lineIndex, line, profile);
    canvas.restore();

    profile?.partialDirtyLinePaints++;
    profile?.partialDirtyCells += end - start;
    return true;
  }

  bool _recordLineGeometryCommands(
    _RenderCommandBuffer commands,
    Offset offset,
    BufferLine line,
    TerminalRenderProfile? profile,
  ) {
    final coversForeground = _painter.recordGeometryGlyphRunPictures(
      line,
      offset,
      (picture, pictureOffset) {
        commands.addPictureAt(
          picture,
          pictureOffset.dx,
          pictureOffset.dy,
          kind: _RenderCommandKind.content,
        );
      },
      collectProfile: profile != null,
    );
    final painterProfile = profile == null ? null : _painter.takeProfile();
    if (profile != null && painterProfile != null) {
      _mergePainterProfile(profile, painterProfile);
    }
    return coversForeground;
  }

  bool _recordLineTextRunCommands(
    _RenderCommandBuffer commands,
    Offset offset,
    BufferLine line,
    TerminalRenderProfile? profile,
  ) {
    final coversForeground = _painter.recordTextRunParagraphs(
      line,
      offset,
      (paragraph, paragraphOffset) {
        commands.addParagraphAt(
          paragraph,
          paragraphOffset.dx,
          paragraphOffset.dy,
          kind: _RenderCommandKind.content,
        );
      },
      collectProfile: profile != null,
    );
    final painterProfile = profile == null ? null : _painter.takeProfile();
    if (profile != null && painterProfile != null) {
      _mergePainterProfile(profile, painterProfile);
    }
    return coversForeground;
  }

  void _recordLineBackgroundCommands(
    _RenderCommandBuffer commands,
    Offset offset,
    BufferLine line,
    TerminalRenderProfile? profile, {
    double? height,
  }) {
    final cellWidth = _painter.cellSize.width;
    final cellHeight = height ?? _painter.cellSize.height;
    _recordLineDefaultBackgroundCommand(
      commands,
      offset,
      line,
      profile,
      height: cellHeight,
    );
    Color? runColor;
    var runStart = 0;
    var runWidth = 0;

    void flush() {
      final color = runColor;
      if (color == null || runWidth == 0) return;
      commands.addRectAt(
        offset.dx + runStart * cellWidth,
        offset.dy,
        runWidth * cellWidth + 1,
        cellHeight,
        color,
        kind: _RenderCommandKind.content,
      );
      profile?.backgroundRuns++;
      runColor = null;
      runWidth = 0;
    }

    for (var i = 0; i < line.length; i++) {
      final content = line.getContent(i);
      final charWidth = content >> CellContent.widthShift;
      final cellSpan = charWidth == 2 ? 2 : 1;
      final flags = line.getAttributes(i);
      final color = _lineCellBackgroundColor(
        foreground: line.getForeground(i),
        background: line.getBackground(i),
        flags: flags,
      );
      if (color == null) {
        flush();
      } else if (runColor == color) {
        runWidth += cellSpan;
      } else {
        flush();
        runColor = color;
        runStart = i;
        runWidth = cellSpan;
      }

      if (charWidth == 2) {
        i++;
      }
    }
    flush();
  }

  void _recordLineDefaultBackgroundCommand(
    _RenderCommandBuffer commands,
    Offset offset,
    BufferLine line,
    TerminalRenderProfile? profile, {
    required double height,
  }) {
    if (!_paintsOpaqueBackground) return;
    commands.addRectAt(
      offset.dx,
      offset.dy,
      max(size.width, line.length * _painter.cellSize.width) + 1,
      height,
      _painter.theme.background,
      kind: _RenderCommandKind.content,
    );
    profile?.backgroundRuns++;
  }

  Color? _lineCellBackgroundColor({
    required int foreground,
    required int background,
    required int flags,
  }) {
    if (flags & CellFlags.inverse != 0) {
      return _painter.resolveForegroundColor(foreground);
    }
    final colorType = background & CellColor.typeMask;
    if (colorType == CellColor.normal) {
      return null;
    }
    return _painter.resolveBackgroundColor(background);
  }

  void _mergePainterProfile(
    TerminalRenderProfile profile,
    TerminalPainterProfile painterProfile,
  ) {
    profile
      ..backgroundRuns += painterProfile.backgroundRuns
      ..asciiRuns += painterProfile.asciiRuns
      ..asciiRunFallbacks += painterProfile.asciiRunFallbacks
      ..renderPlanCacheHits += painterProfile.renderPlanCacheHits
      ..renderPlanCacheMisses += painterProfile.renderPlanCacheMisses
      ..glyphPictureCacheHits += painterProfile.glyphPictureCacheHits
      ..glyphPictureCacheMisses += painterProfile.glyphPictureCacheMisses
      ..glyphRunPictureCacheHits += painterProfile.glyphRunPictureCacheHits
      ..glyphRunPictureCacheMisses += painterProfile.glyphRunPictureCacheMisses
      ..glyphAtlasHits += painterProfile.glyphAtlasHits
      ..glyphAtlasMisses += painterProfile.glyphAtlasMisses
      ..glyphAtlasDraws += painterProfile.glyphAtlasDraws
      ..glyphAtlasRunDraws += painterProfile.glyphAtlasRunDraws
      ..emojiFallbackCells += painterProfile.emojiFallbackCells
      ..wideGlyphFallbackCells += painterProfile.wideGlyphFallbackCells
      ..paragraphCacheHits += painterProfile.paragraphCacheHits
      ..paragraphCacheMisses += painterProfile.paragraphCacheMisses
      ..runParagraphCacheHits += painterProfile.runParagraphCacheHits
      ..runParagraphCacheMisses += painterProfile.runParagraphCacheMisses
      ..singleCells += painterProfile.singleCells
      ..blankLines += painterProfile.blankLines;
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
    int lineIndex,
    BufferLine line,
    TerminalRenderProfile? profile,
  ) {
    _painter.paintLine(
      canvas,
      offset,
      line,
      collectProfile: profile != null,
      backgroundHeight: _backgroundBandHeight(lineIndex),
    );
    final painterProfile = profile == null ? null : _painter.takeProfile();
    final renderProfile = profile;
    if (renderProfile != null && painterProfile != null) {
      renderProfile.uncachedLines++;
      _mergePainterProfile(renderProfile, painterProfile);
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

  double _backgroundBandHeight(int lineIndex) {
    final charHeight = _painter.cellSize.height;
    final top = _lineBandTop(lineIndex);
    final bottom = _lineBandBottom(lineIndex);
    final height = bottom - top;
    return height > 0 ? height : charHeight;
  }

  double _lineBandTop(int lineIndex) {
    return (lineIndex * _painter.cellSize.height + _lineOffset).floorToDouble();
  }

  double _lineBandBottom(int lineIndex) {
    return ((lineIndex + 1) * _painter.cellSize.height + _lineOffset)
        .ceilToDouble();
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

  void _recordOverlaySelectionCommands(
    _RenderCommandBuffer commands,
    Offset offset,
    int firstLine,
    int lastLine,
    TerminalRenderProfile? profile,
  ) {
    final selection = _controller.selection;
    if (selection == null) return;
    final runs = _recordOverlaySegmentRunCommands(
      commands,
      offset,
      selection.toSegments(),
      _painter.theme.selection,
      firstLine,
      lastLine,
    );
    profile?.selectionRuns += runs;
  }

  void _recordOverlayHighlightCommands(
    _RenderCommandBuffer commands,
    Offset offset,
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

      final runs = _recordOverlaySegmentRunCommands(
        commands,
        offset,
        range.toSegments(),
        highlight.color,
        firstLine,
        lastLine,
      );
      profile?.highlightRuns += runs;
    }
  }

  int _recordOverlaySegmentRunCommands(
    _RenderCommandBuffer commands,
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
      _recordOverlaySegmentRectCommand(
        commands,
        offset,
        line,
        runStart,
        runEnd,
        color,
      );
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
  void _recordOverlaySegmentRectCommand(
    _RenderCommandBuffer commands,
    Offset offset,
    int line,
    int start,
    int end,
    Color color,
  ) {
    final dx = offset.dx + start * _painter.cellSize.width;
    final dy = offset.dy + _lineBandTop(line);
    commands.addRectAt(
      dx,
      dy,
      (end - start) * _painter.cellSize.width,
      _overlayBandHeight(line),
      color,
      kind: _RenderCommandKind.overlay,
    );
  }

  double _overlayBandHeight(int lineIndex) {
    final top = _lineBandTop(lineIndex);
    final bottom = _lineBandTop(lineIndex + 1);
    final height = bottom - top;
    return height > 0 ? height : _painter.cellSize.height;
  }
}

class _RenderCommandBuffer {
  static const _transparent = Color(0x00000000);

  final _types = <_RenderCommandType>[];
  final _pictures = <Picture?>[];
  final _paragraphs = <Paragraph?>[];
  final _dx = <double>[];
  final _dy = <double>[];
  final _width = <double>[];
  final _height = <double>[];
  final _colors = <Color>[];
  final _kinds = <_RenderCommandKind>[];
  final _rectPaint = Paint();

  bool get containsPictures => _pictures.any((picture) => picture != null);

  void clear() {
    _types.clear();
    _pictures.clear();
    _paragraphs.clear();
    _dx.clear();
    _dy.clear();
    _width.clear();
    _height.clear();
    _colors.clear();
    _kinds.clear();
  }

  void addPicture(
    Picture picture,
    Offset offset, {
    _RenderCommandKind kind = _RenderCommandKind.content,
  }) {
    addPictureAt(picture, offset.dx, offset.dy, kind: kind);
  }

  void addPictureAt(
    Picture picture,
    double dx,
    double dy, {
    _RenderCommandKind kind = _RenderCommandKind.content,
  }) {
    _types.add(_RenderCommandType.picture);
    _pictures.add(picture);
    _paragraphs.add(null);
    _dx.add(dx);
    _dy.add(dy);
    _width.add(0);
    _height.add(0);
    _colors.add(_transparent);
    _kinds.add(kind);
  }

  void addRectAt(
    double dx,
    double dy,
    double width,
    double height,
    Color color, {
    _RenderCommandKind kind = _RenderCommandKind.content,
  }) {
    if (width <= 0 || height <= 0) return;
    _types.add(_RenderCommandType.rect);
    _pictures.add(null);
    _paragraphs.add(null);
    _dx.add(dx);
    _dy.add(dy);
    _width.add(width);
    _height.add(height);
    _colors.add(color);
    _kinds.add(kind);
  }

  void addParagraphAt(
    Paragraph paragraph,
    double dx,
    double dy, {
    _RenderCommandKind kind = _RenderCommandKind.content,
  }) {
    _types.add(_RenderCommandType.paragraph);
    _pictures.add(null);
    _paragraphs.add(paragraph);
    _dx.add(dx);
    _dy.add(dy);
    _width.add(0);
    _height.add(0);
    _colors.add(_transparent);
    _kinds.add(kind);
  }

  void draw(Canvas canvas, Offset offset, TerminalRenderProfile? profile) {
    if (_types.isEmpty) return;
    profile?.renderCommandBuffers++;
    profile?.renderCommands += _types.length;
    for (var i = 0; i < _types.length; i++) {
      switch (_types[i]) {
        case _RenderCommandType.picture:
          final picture = _pictures[i];
          if (picture == null) continue;
          canvas.save();
          canvas.translate(
            offset.dx + _dx[i],
            offset.dy + _dy[i],
          );
          canvas.drawPicture(picture);
          canvas.restore();
          if (profile != null) {
            profile.renderCommandPictureDraws += 1;
            switch (_kinds[i]) {
              case _RenderCommandKind.content:
                profile.contentPicturesDrawn += 1;
              case _RenderCommandKind.overlay:
                profile.overlayRowPictureDraws += 1;
            }
          }
        case _RenderCommandType.rect:
          _rectPaint
            ..color = _colors[i]
            ..style = PaintingStyle.fill
            ..isAntiAlias = false;
          final left = offset.dx + _dx[i];
          final top = offset.dy + _dy[i];
          final right = left + _width[i];
          final bottom = top + _height[i];
          final rect = switch (_kinds[i]) {
            _RenderCommandKind.content => Rect.fromLTRB(
                left,
                top.floorToDouble(),
                right,
                bottom.ceilToDouble(),
              ),
            _RenderCommandKind.overlay => Rect.fromLTRB(
                left,
                top,
                right,
                bottom,
              ),
          };
          canvas.drawRect(rect, _rectPaint);
          profile?.renderCommandRectDraws++;
        case _RenderCommandType.paragraph:
          final paragraph = _paragraphs[i];
          if (paragraph == null) continue;
          canvas.drawParagraph(
            paragraph,
            Offset(offset.dx + _dx[i], offset.dy + _dy[i]),
          );
          profile?.renderCommandParagraphDraws++;
      }
    }
  }

  void replayInto(_RenderCommandBuffer commands, Offset offset) {
    for (var i = 0; i < _types.length; i++) {
      final dx = offset.dx + _dx[i];
      final dy = offset.dy + _dy[i];
      switch (_types[i]) {
        case _RenderCommandType.picture:
          final picture = _pictures[i];
          if (picture == null) continue;
          commands.addPictureAt(picture, dx, dy, kind: _kinds[i]);
        case _RenderCommandType.rect:
          commands.addRectAt(
            dx,
            dy,
            _width[i],
            _height[i],
            _colors[i],
            kind: _kinds[i],
          );
        case _RenderCommandType.paragraph:
          final paragraph = _paragraphs[i];
          if (paragraph == null) continue;
          commands.addParagraphAt(paragraph, dx, dy, kind: _kinds[i]);
      }
    }
  }

  _LineCommandCache snapshot({bool skipPictures = false}) {
    if (_types.isEmpty) return _LineCommandCache.empty;
    if (!skipPictures) {
      return _LineCommandCache(
        List<_RenderCommandType>.of(_types),
        List<Picture?>.of(_pictures),
        List<Paragraph?>.of(_paragraphs),
        List<double>.of(_dx),
        List<double>.of(_dy),
        List<double>.of(_width),
        List<double>.of(_height),
        List<Color>.of(_colors),
        List<_RenderCommandKind>.of(_kinds),
      );
    }
    final types = <_RenderCommandType>[];
    final pictures = <Picture?>[];
    final paragraphs = <Paragraph?>[];
    final dx = <double>[];
    final dy = <double>[];
    final width = <double>[];
    final height = <double>[];
    final colors = <Color>[];
    final kinds = <_RenderCommandKind>[];
    for (var i = 0; i < _types.length; i++) {
      if (_types[i] == _RenderCommandType.picture) continue;
      types.add(_types[i]);
      pictures.add(_pictures[i]);
      paragraphs.add(_paragraphs[i]);
      dx.add(_dx[i]);
      dy.add(_dy[i]);
      width.add(_width[i]);
      height.add(_height[i]);
      colors.add(_colors[i]);
      kinds.add(_kinds[i]);
    }
    if (types.isEmpty) return _LineCommandCache.empty;
    return _LineCommandCache(
      types,
      pictures,
      paragraphs,
      dx,
      dy,
      width,
      height,
      colors,
      kinds,
    );
  }
}

class _LineCommandCache {
  const _LineCommandCache(
    this._types,
    this._pictures,
    this._paragraphs,
    this._dx,
    this._dy,
    this._width,
    this._height,
    this._colors,
    this._kinds,
  );

  static const empty = _LineCommandCache(
    [],
    [],
    [],
    [],
    [],
    [],
    [],
    [],
    [],
  );

  final List<_RenderCommandType> _types;
  final List<Picture?> _pictures;
  final List<Paragraph?> _paragraphs;
  final List<double> _dx;
  final List<double> _dy;
  final List<double> _width;
  final List<double> _height;
  final List<Color> _colors;
  final List<_RenderCommandKind> _kinds;

  void replay(_RenderCommandBuffer commands, Offset offset) {
    for (var i = 0; i < _types.length; i++) {
      final dx = offset.dx + _dx[i];
      final dy = offset.dy + _dy[i];
      switch (_types[i]) {
        case _RenderCommandType.picture:
          final picture = _pictures[i];
          if (picture == null) continue;
          commands.addPictureAt(picture, dx, dy, kind: _kinds[i]);
        case _RenderCommandType.rect:
          commands.addRectAt(
            dx,
            dy,
            _width[i],
            _height[i],
            _colors[i],
            kind: _kinds[i],
          );
        case _RenderCommandType.paragraph:
          final paragraph = _paragraphs[i];
          if (paragraph == null) continue;
          commands.addParagraphAt(paragraph, dx, dy, kind: _kinds[i]);
      }
    }
  }
}

enum _RenderCommandType {
  picture,
  rect,
  paragraph,
}

enum _RenderCommandKind {
  content,
  overlay,
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
  var lineCommandCacheHits = 0;
  var lineCommandCacheMisses = 0;
  var partialDirtyLinePaints = 0;
  var partialDirtyCells = 0;
  var cachedPictures = 0;
  var viewportContentCacheHits = 0;
  var viewportContentCacheMisses = 0;
  var viewportContentSignatureRows = 0;
  var viewportContentDirectDraws = 0;
  var viewportContentPictureDraws = 0;
  var contentPicturesDrawn = 0;
  var renderCommandBuffers = 0;
  var renderCommands = 0;
  var renderCommandPictureDraws = 0;
  var renderCommandRectDraws = 0;
  var renderCommandParagraphDraws = 0;
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
  var glyphAtlasHits = 0;
  var glyphAtlasMisses = 0;
  var glyphAtlasDraws = 0;
  var glyphAtlasRunDraws = 0;
  var emojiFallbackCells = 0;
  var wideGlyphFallbackCells = 0;
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
        'lineCommandCacheHits: $lineCommandCacheHits, '
        'lineCommandCacheMisses: $lineCommandCacheMisses, '
        'partialDirtyLinePaints: $partialDirtyLinePaints, '
        'partialDirtyCells: $partialDirtyCells, '
        'cachedPictures: $cachedPictures, '
        'viewportContentCacheHits: $viewportContentCacheHits, '
        'viewportContentCacheMisses: $viewportContentCacheMisses, '
        'viewportContentSignatureRows: $viewportContentSignatureRows, '
        'viewportContentDirectDraws: $viewportContentDirectDraws, '
        'viewportContentPictureDraws: $viewportContentPictureDraws, '
        'contentPicturesDrawn: $contentPicturesDrawn, '
        'renderCommandBuffers: $renderCommandBuffers, '
        'renderCommands: $renderCommands, '
        'renderCommandPictureDraws: $renderCommandPictureDraws, '
        'renderCommandRectDraws: $renderCommandRectDraws, '
        'renderCommandParagraphDraws: $renderCommandParagraphDraws, '
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
        'glyphAtlasHits: $glyphAtlasHits, '
        'glyphAtlasMisses: $glyphAtlasMisses, '
        'glyphAtlasDraws: $glyphAtlasDraws, '
        'glyphAtlasRunDraws: $glyphAtlasRunDraws, '
        'emojiFallbackCells: $emojiFallbackCells, '
        'wideGlyphFallbackCells: $wideGlyphFallbackCells, '
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
  _LinePictureCache(
    this.signature, {
    this.picture,
    this.commandCache = _LineCommandCache.empty,
    this.needsGeometryCommands = false,
  });

  final int signature;
  final Picture? picture;
  final _LineCommandCache? commandCache;
  final bool needsGeometryCommands;

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
