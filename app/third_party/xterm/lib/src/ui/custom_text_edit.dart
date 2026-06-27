import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// PATCH cc-handoff (TEMP DIAGNOSTIC): when the app sets this, input-pipeline
// events are mirrored out so we can see — on a packaged Windows build — exactly
// where keystrokes are lost (focus change, connection attach, raw key events,
// updateEditingValue). Remove once Windows IME input is sorted.
void Function(String msg)? kXtermInputDebug;

class CustomTextEdit extends StatefulWidget {
  CustomTextEdit({
    super.key,
    required this.child,
    required this.onInsert,
    required this.onDelete,
    required this.onComposing,
    required this.onAction,
    required this.onKeyEvent,
    required this.focusNode,
    this.autofocus = false,
    this.readOnly = false,
    // this.initEditingState = TextEditingValue.empty,
    this.inputType = TextInputType.text,
    this.inputAction = TextInputAction.newline,
    this.keyboardAppearance = Brightness.light,
    this.deleteDetection = false,
  });

  final Widget child;

  final void Function(String) onInsert;

  final void Function() onDelete;

  final void Function(String?) onComposing;

  final void Function(TextInputAction) onAction;

  final KeyEventResult Function(FocusNode, KeyEvent) onKeyEvent;

  final FocusNode focusNode;

  final bool autofocus;

  final bool readOnly;

  final TextInputType inputType;

  final TextInputAction inputAction;

  final Brightness keyboardAppearance;

  final bool deleteDetection;

  @override
  CustomTextEditState createState() => CustomTextEditState();
}

class CustomTextEditState extends State<CustomTextEdit> with TextInputClient {
  TextInputConnection? _connection;

  @override
  void initState() {
    widget.focusNode.addListener(_onFocusChange);
    super.initState();
  }

  @override
  void didUpdateWidget(CustomTextEdit oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.focusNode != oldWidget.focusNode) {
      oldWidget.focusNode.removeListener(_onFocusChange);
      widget.focusNode.addListener(_onFocusChange);
    }

    if (!_shouldCreateInputConnection) {
      _closeInputConnectionIfNeeded();
    } else {
      if (oldWidget.readOnly && widget.focusNode.hasFocus) {
        _openInputConnection();
      }
    }
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_onFocusChange);
    _closeInputConnectionIfNeeded();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      onKeyEvent: _onKeyEvent,
      child: widget.child,
    );
  }

  bool get hasInputConnection => _connection != null && _connection!.attached;

  void requestKeyboard() {
    if (widget.focusNode.hasFocus) {
      _openInputConnection();
    } else {
      widget.focusNode.requestFocus();
    }
  }

  void closeKeyboard() {
    if (hasInputConnection) {
      _connection?.close();
    }
  }

  void setEditingState(TextEditingValue value) {
    _currentEditingState = value;
    _connection?.setEditingState(value);
  }

  void setEditableRect(Rect rect, Rect caretRect) {
    if (!hasInputConnection) {
      return;
    }
    _updateSizeAndTransform();
    final box = context.findRenderObject();
    if (box is RenderBox && box.hasSize) {
      // caretRect arrives in global coords; map it into the editable's local
      // space (matching the transform reported by _updateSizeAndTransform).
      _connection?.setCaretRect(box.globalToLocal(caretRect.topLeft) & caretRect.size);
    }
  }

  // PATCH cc-handoff: report the terminal's true size and transform-to-window so
  // the platform text input (and IME) routes characters here. Upstream sent a
  // bogus rect.size + identity transform, which Windows treats as an invalid
  // field and silently drops ALL input (ASCII and IME composition alike) — the
  // terminal could be typed into on macOS (lenient) but not on Windows. This
  // mirrors what Flutter's own EditableText does (getTransformTo(null)).
  void _updateSizeAndTransform() {
    if (!hasInputConnection) {
      return;
    }
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) {
      return;
    }
    _connection!.setEditableSizeAndTransform(box.size, box.getTransformTo(null));
  }

  void _onFocusChange() {
    _openOrCloseInputConnectionIfNeeded();
  }

  KeyEventResult _onKeyEvent(FocusNode focusNode, KeyEvent event) {
    kXtermInputDebug?.call(
        'key ${event.runtimeType} ${event.logicalKey.keyLabel} ch="${event.character}" comp=${_currentEditingState.composing}');
    if (_currentEditingState.composing.isCollapsed) {
      return widget.onKeyEvent(focusNode, event);
    }

    return KeyEventResult.skipRemainingHandlers;
  }

  void _openOrCloseInputConnectionIfNeeded() {
    kXtermInputDebug?.call(
        'focuschg hasFocus=${widget.focusNode.hasFocus} hasConn=$hasInputConnection');
    // PATCH cc-handoff: open the connection whenever the node has focus, instead
    // of gating on consumeKeyboardToken() — on Windows desktop the token isn't
    // reliably granted for a tap-driven requestFocus, so the connection never
    // attached. Safe on every platform (no soft keyboard here).
    if (widget.focusNode.hasFocus) {
      _openInputConnection();
    } else {
      _closeInputConnectionIfNeeded();
    }
  }

  bool get _shouldCreateInputConnection => kIsWeb || !widget.readOnly;

  void _openInputConnection() {
    if (!_shouldCreateInputConnection) {
      return;
    }

    if (hasInputConnection) {
      _connection!.show();
    } else {
      final config = TextInputConfiguration(
        inputType: widget.inputType,
        inputAction: widget.inputAction,
        keyboardAppearance: widget.keyboardAppearance,
        autocorrect: false,
        enableSuggestions: false,
        enableIMEPersonalizedLearning: false,
      );

      _connection = TextInput.attach(this, config);
      kXtermInputDebug?.call('conn attached');

      _connection!.show();

      _connection!.setEditingState(_initEditingState);

      // PATCH cc-handoff: push the editable size/transform once the connection is
      // up (don't wait for the next terminal repaint to call setEditableRect), so
      // input routes immediately on Windows.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _updateSizeAndTransform();
      });
    }
  }

  void _closeInputConnectionIfNeeded() {
    if (_connection != null && _connection!.attached) {
      _connection!.close();
      _connection = null;
    }
  }

  TextEditingValue get _initEditingState => widget.deleteDetection
      ? const TextEditingValue(
          text: '  ',
          selection: TextSelection.collapsed(offset: 2),
        )
      : const TextEditingValue(
          text: '',
          selection: TextSelection.collapsed(offset: 0),
        );

  late var _currentEditingState = _initEditingState.copyWith();

  @override
  TextEditingValue? get currentTextEditingValue {
    return _currentEditingState;
  }

  @override
  AutofillScope? get currentAutofillScope {
    return null;
  }

  @override
  void updateEditingValue(TextEditingValue value) {
    kXtermInputDebug?.call('uev "${value.text}" comp=${value.composing}');
    _currentEditingState = value;

    // Get input after composing is done
    if (!_currentEditingState.composing.isCollapsed) {
      final text = _currentEditingState.text;
      final composingText = _currentEditingState.composing.textInside(text);
      widget.onComposing(composingText);
      return;
    }

    widget.onComposing(null);

    if (_currentEditingState.text.length < _initEditingState.text.length) {
      widget.onDelete();
    } else {
      final textDelta = _currentEditingState.text.substring(
        _initEditingState.text.length,
      );

      widget.onInsert(textDelta);
    }

    // Reset editing state if composing is done
    if (_currentEditingState.composing.isCollapsed &&
        _currentEditingState.text != _initEditingState.text) {
      _connection!.setEditingState(_initEditingState);
    }
  }

  @override
  void performAction(TextInputAction action) {
    // print('performAction $action');
    widget.onAction(action);
  }

  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {
    // print('updateFloatingCursor $point');
  }

  @override
  void showAutocorrectionPromptRect(int start, int end) {
    // print('showAutocorrectionPromptRect');
  }

  @override
  void connectionClosed() {
    kXtermInputDebug?.call('conn closed');
  }

  @override
  void performPrivateCommand(String action, Map<String, dynamic> data) {
    // print('performPrivateCommand $action');
  }

  @override
  void insertTextPlaceholder(Size size) {
    // print('insertTextPlaceholder');
  }

  @override
  void removeTextPlaceholder() {
    // print('removeTextPlaceholder');
  }

  @override
  void showToolbar() {
    // print('showToolbar');
  }
}
