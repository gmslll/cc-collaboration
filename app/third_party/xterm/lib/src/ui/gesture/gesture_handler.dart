import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:xterm/src/core/buffer/cell_offset.dart';
import 'package:xterm/src/core/mouse/button.dart';
import 'package:xterm/src/core/mouse/button_state.dart';
import 'package:xterm/src/terminal_view.dart';
import 'package:xterm/src/ui/controller.dart';
import 'package:xterm/src/ui/gesture/gesture_detector.dart';
import 'package:xterm/src/ui/pointer_input.dart';
import 'package:xterm/src/ui/render.dart';
import 'package:xterm/src/ui/selection_mode.dart';

class TerminalGestureHandler extends StatefulWidget {
  const TerminalGestureHandler({
    super.key,
    required this.terminalView,
    required this.terminalController,
    this.child,
    this.onTapUp,
    this.onSingleTapUp,
    this.onTapDown,
    this.onSecondaryTapDown,
    this.onSecondaryTapUp,
    this.onTertiaryTapDown,
    this.onTertiaryTapUp,
    this.readOnly = false,
  });

  final TerminalViewState terminalView;

  final TerminalController terminalController;

  final Widget? child;

  final GestureTapUpCallback? onTapUp;

  final GestureTapUpCallback? onSingleTapUp;

  final GestureTapDownCallback? onTapDown;

  final GestureTapDownCallback? onSecondaryTapDown;

  final GestureTapUpCallback? onSecondaryTapUp;

  final GestureTapDownCallback? onTertiaryTapDown;

  final GestureTapUpCallback? onTertiaryTapUp;

  final bool readOnly;

  @override
  State<TerminalGestureHandler> createState() => _TerminalGestureHandlerState();
}

class _TerminalGestureHandlerState extends State<TerminalGestureHandler> {
  TerminalViewState get terminalView => widget.terminalView;

  RenderTerminal get renderTerminal => terminalView.renderTerminal;

  DragStartDetails? _lastDragStartDetails;

  LongPressStartDetails? _lastLongPressStartDetails;

  CellOffset? _selectionAnchor;

  Offset? _selectionExtent;

  Timer? _selectionAutoScrollTimer;

  bool _routingMouseDragToTerminal = false;

  Offset? _lastMouseDragPosition;

  SelectionMode _dragSelectionMode = SelectionMode.line;

  static const _selectionAutoScrollInterval = Duration(milliseconds: 50);

  @override
  void dispose() {
    _stopSelectionAutoScroll();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TerminalGestureDetector(
      onTapUp: widget.onTapUp,
      onSingleTapUp: onSingleTapUp,
      onTapDown: onTapDown,
      onSecondaryTapDown: onSecondaryTapDown,
      onSecondaryTapUp: onSecondaryTapUp,
      onTertiaryTapDown: onTertiaryTapDown,
      onTertiaryTapUp: onTertiaryTapUp,
      onLongPressStart: onLongPressStart,
      onLongPressMoveUpdate: onLongPressMoveUpdate,
      onLongPressUp: onSelectionEnd,
      onLongPressCancel: onSelectionEnd,
      onDragStart: onDragStart,
      onDragUpdate: onDragUpdate,
      onDragEnd: (_) => onSelectionEnd(),
      onDragCancel: onSelectionEnd,
      onDoubleTapDown: onDoubleTapDown,
      onTripleTapDown: onTripleTapDown,
      child: widget.child,
    );
  }

  bool get _shouldSendTapEvent =>
      !widget.readOnly &&
      widget.terminalController.shouldSendPointerInput(PointerInput.tap) &&
      terminalView.shouldRouteMouseToTerminal();

  bool get _shouldSendDragEvent =>
      !widget.readOnly &&
      widget.terminalController.shouldSendPointerInput(PointerInput.drag) &&
      terminalView.shouldRouteMouseToTerminal();

  void _tapDown(
    GestureTapDownCallback? callback,
    TapDownDetails details,
    TerminalMouseButton button, {
    bool forceCallback = false,
  }) {
    // Check if the terminal should and can handle the tap down event.
    var handled = false;
    if (_shouldSendTapEvent) {
      handled = renderTerminal.mouseEvent(
        button,
        TerminalMouseButtonState.down,
        details.localPosition,
      );
    }
    // If the event was not handled by the terminal, use the supplied callback.
    if (!handled || forceCallback) {
      callback?.call(details);
    }
  }

  void _tapUp(
    GestureTapUpCallback? callback,
    TapUpDetails details,
    TerminalMouseButton button, {
    bool forceCallback = false,
  }) {
    // Check if the terminal should and can handle the tap up event.
    var handled = false;
    if (_shouldSendTapEvent) {
      handled = renderTerminal.mouseEvent(
        button,
        TerminalMouseButtonState.up,
        details.localPosition,
      );
    }
    // If the event was not handled by the terminal, use the supplied callback.
    if (!handled || forceCallback) {
      callback?.call(details);
    }
  }

  void onTapDown(TapDownDetails details) {
    // onTapDown is special, as it will always call the supplied callback.
    // The TerminalView depends on it to bring the terminal into focus.
    _tapDown(
      widget.onTapDown,
      details,
      TerminalMouseButton.left,
      forceCallback: true,
    );
  }

  void onSingleTapUp(TapUpDetails details) {
    _tapUp(widget.onSingleTapUp, details, TerminalMouseButton.left);
  }

  void onSecondaryTapDown(TapDownDetails details) {
    _tapDown(widget.onSecondaryTapDown, details, TerminalMouseButton.right);
  }

  void onSecondaryTapUp(TapUpDetails details) {
    _tapUp(widget.onSecondaryTapUp, details, TerminalMouseButton.right);
  }

  void onTertiaryTapDown(TapDownDetails details) {
    _tapDown(widget.onTertiaryTapDown, details, TerminalMouseButton.middle);
  }

  void onTertiaryTapUp(TapUpDetails details) {
    _tapUp(widget.onTertiaryTapUp, details, TerminalMouseButton.middle);
  }

  void onDoubleTapDown(TapDownDetails details) {
    renderTerminal.selectWord(details.localPosition);
  }

  void onTripleTapDown(TapDownDetails details) {
    renderTerminal.selectLine(details.localPosition);
  }

  void onLongPressStart(LongPressStartDetails details) {
    _lastLongPressStartDetails = details;
    _beginSelection(details.localPosition, SelectionMode.line);
  }

  void onLongPressMoveUpdate(LongPressMoveUpdateDetails details) {
    _updateSelection(
      _lastLongPressStartDetails!.localPosition,
      details.localPosition,
      SelectionMode.line,
    );
  }

  void onDragStart(DragStartDetails details) {
    _lastDragStartDetails = details;
    _lastMouseDragPosition = details.localPosition;

    if (details.kind == PointerDeviceKind.mouse) {
      if (_shouldSendDragEvent) {
        _routingMouseDragToTerminal = true;
        return;
      }
      _dragSelectionMode = HardwareKeyboard.instance.isAltPressed
          ? SelectionMode.block
          : SelectionMode.line;
      _beginSelection(details.localPosition, _dragSelectionMode);
    } else {
      _dragSelectionMode = SelectionMode.line;
      renderTerminal.selectWord(details.localPosition);
    }
  }

  void onDragUpdate(DragUpdateDetails details) {
    _lastMouseDragPosition = details.localPosition;
    if (_routingMouseDragToTerminal) return;
    _updateSelection(
      _lastDragStartDetails!.localPosition,
      details.localPosition,
      _dragSelectionMode,
    );
  }

  void onSelectionEnd() {
    _finishTerminalMouseDrag();
    _selectionAnchor = null;
    _selectionExtent = null;
    _stopSelectionAutoScroll();
  }

  void _finishTerminalMouseDrag() {
    if (!_routingMouseDragToTerminal) return;
    final position = _lastMouseDragPosition;
    _routingMouseDragToTerminal = false;
    _lastMouseDragPosition = null;
    if (position == null) return;
    renderTerminal.mouseEvent(
      TerminalMouseButton.left,
      TerminalMouseButtonState.up,
      position,
    );
  }

  void _beginSelection(Offset position, SelectionMode mode) {
    final anchor = renderTerminal.getCellOffset(position);
    _selectionAnchor = anchor;
    _selectionExtent = position;
    _dragSelectionMode = mode;
    renderTerminal.selectCharactersFromCell(anchor, null, mode);
    _updateSelectionAutoScroll();
  }

  void _updateSelection(Offset anchor, Offset extent, SelectionMode mode) {
    _selectionAnchor ??= renderTerminal.getCellOffset(anchor);
    _selectionExtent = extent;
    _dragSelectionMode = mode;
    renderTerminal.selectCharactersFromCell(_selectionAnchor!, extent, mode);
    _updateSelectionAutoScroll();
  }

  void _updateSelectionAutoScroll() {
    final extent = _selectionExtent;
    if (extent == null || !terminalView.autoscrollSelection(extent)) {
      _stopSelectionAutoScroll();
      return;
    }
    _selectionAutoScrollTimer ??= Timer.periodic(
      _selectionAutoScrollInterval,
      (_) => _tickSelectionAutoScroll(),
    );
  }

  void _tickSelectionAutoScroll() {
    final anchor = _selectionAnchor;
    final extent = _selectionExtent;
    if (anchor == null || extent == null) {
      _stopSelectionAutoScroll();
      return;
    }
    if (!terminalView.autoscrollSelection(extent)) {
      _stopSelectionAutoScroll();
      return;
    }
    renderTerminal.selectCharactersFromCell(anchor, extent, _dragSelectionMode);
  }

  void _stopSelectionAutoScroll() {
    _selectionAutoScrollTimer?.cancel();
    _selectionAutoScrollTimer = null;
  }
}
