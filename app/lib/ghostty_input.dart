import 'package:flutter/services.dart';
import 'package:libghostty/libghostty.dart' as ghostty;
import 'package:xterm/xterm.dart' as xterm;

class GhosttyInputEncoder {
  GhosttyInputEncoder() : _keyEncoder = ghostty.KeyEncoder();

  final ghostty.KeyEncoder _keyEncoder;

  String encodeKeyEvent(KeyEvent event, {ghostty.Terminal? syncTerminal}) {
    if (syncTerminal != null) {
      _keyEncoder.sync(syncTerminal);
    }

    final ghosttyKey =
        _keyFromPhysical(event.physicalKey) ??
        _keyFromLogical(event.logicalKey) ??
        _keyFromCharacter(event.character);
    if (ghosttyKey == null || ghosttyKey == ghostty.Key.unidentified) {
      return '';
    }

    final ghosttyEvent = ghostty.KeyEvent()
      ..action = _keyAction(event)
      ..key = ghosttyKey
      ..mods = _mods();

    final character = event.character;
    if (character != null && character.isNotEmpty) {
      ghosttyEvent.utf8 = character;
      ghosttyEvent.unshiftedCodepoint = _unshiftedCodepoint(ghosttyKey);
    }

    try {
      return _keyEncoder.encode(ghosttyEvent);
    } finally {
      ghosttyEvent.dispose();
    }
  }

  void dispose() {
    _keyEncoder.dispose();
  }
}

ghostty.KeyAction _keyAction(KeyEvent event) {
  if (event is KeyUpEvent) return ghostty.KeyAction.release;
  if (event is KeyRepeatEvent) return ghostty.KeyAction.repeat;
  return ghostty.KeyAction.press;
}

String encodeGhosttyMouseCell({
  required int x,
  required int y,
  required xterm.MouseReportMode reportMode,
  required xterm.MouseMode mouseMode,
  required xterm.TerminalMouseButton button,
  required xterm.TerminalMouseButtonState state,
}) {
  if (_isWheel(button)) {
    return '';
  }
  final tracking = _tracking(mouseMode);
  if (tracking == null) return '';

  final encoder = ghostty.MouseEncoder()
    ..setTrackingMode(tracking)
    ..setFormat(_mouseFormat(reportMode))
    ..setSize(
      const ghostty.MouseEncoderSize(
        screenWidth: 10000,
        screenHeight: 10000,
        cellWidth: 1,
        cellHeight: 1,
      ),
    );
  final event = ghostty.MouseEvent()
    ..action = _mouseAction(state)
    ..button = _mouseButton(button)
    ..setPosition(x: x - 1.0, y: y - 1.0);

  try {
    return encoder.encode(event);
  } finally {
    event.dispose();
    encoder.dispose();
  }
}

bool _isWheel(xterm.TerminalMouseButton button) {
  return button == xterm.TerminalMouseButton.wheelUp ||
      button == xterm.TerminalMouseButton.wheelDown ||
      button == xterm.TerminalMouseButton.wheelLeft ||
      button == xterm.TerminalMouseButton.wheelRight;
}

ghostty.MouseTracking? _tracking(xterm.MouseMode mode) {
  if (mode == xterm.MouseMode.none) return null;
  if (mode == xterm.MouseMode.clickOnly) return ghostty.MouseTracking.normal;
  if (mode == xterm.MouseMode.upDownScroll) {
    return ghostty.MouseTracking.button;
  }
  if (mode == xterm.MouseMode.upDownScrollDrag) {
    return ghostty.MouseTracking.button;
  }
  return ghostty.MouseTracking.any;
}

ghostty.MouseFormat _mouseFormat(xterm.MouseReportMode mode) {
  return switch (mode) {
    xterm.MouseReportMode.normal => ghostty.MouseFormat.x10,
    xterm.MouseReportMode.utf => ghostty.MouseFormat.utf8,
    xterm.MouseReportMode.sgr => ghostty.MouseFormat.sgr,
    xterm.MouseReportMode.urxvt => ghostty.MouseFormat.urxvt,
  };
}

ghostty.MouseButton _mouseButton(xterm.TerminalMouseButton button) {
  return switch (button) {
    xterm.TerminalMouseButton.left => ghostty.MouseButton.left,
    xterm.TerminalMouseButton.middle => ghostty.MouseButton.middle,
    xterm.TerminalMouseButton.right => ghostty.MouseButton.right,
    _ => ghostty.MouseButton.unknown,
  };
}

ghostty.MouseAction _mouseAction(xterm.TerminalMouseButtonState state) {
  return switch (state) {
    xterm.TerminalMouseButtonState.down => ghostty.MouseAction.press,
    xterm.TerminalMouseButtonState.up => ghostty.MouseAction.release,
  };
}

ghostty.Mods _mods() {
  final hw = HardwareKeyboard.instance;
  var mods = const ghostty.Mods.none();
  if (hw.isShiftPressed) mods |= const ghostty.Mods.shift();
  if (hw.isAltPressed) mods |= const ghostty.Mods.alt();
  if (hw.isControlPressed) mods |= const ghostty.Mods.ctrl();
  if (hw.isMetaPressed) mods |= const ghostty.Mods.superKey();
  return mods;
}

ghostty.Key? _keyFromCharacter(String? character) {
  if (character == null || character.isEmpty) return null;
  return _codepointToKey[character.runes.first];
}

ghostty.Key? _keyFromPhysical(PhysicalKeyboardKey key) {
  return _physicalToKey[key];
}

ghostty.Key? _keyFromLogical(LogicalKeyboardKey key) {
  return _logicalToKey[key];
}

int _unshiftedCodepoint(ghostty.Key key) => _keyToCodepoint[key] ?? 0;

final Map<int, ghostty.Key> _codepointToKey = {
  0x20: ghostty.Key.space,
  0x21: ghostty.Key.digit1,
  0x22: ghostty.Key.quote,
  0x23: ghostty.Key.digit3,
  0x24: ghostty.Key.digit4,
  0x25: ghostty.Key.digit5,
  0x26: ghostty.Key.digit7,
  0x27: ghostty.Key.quote,
  0x28: ghostty.Key.digit9,
  0x29: ghostty.Key.digit0,
  0x2a: ghostty.Key.digit8,
  0x2b: ghostty.Key.equal,
  0x2c: ghostty.Key.comma,
  0x2d: ghostty.Key.minus,
  0x2e: ghostty.Key.period,
  0x2f: ghostty.Key.slash,
  for (var i = 0; i < 26; i++)
    0x61 + i: ghostty.Key.values[ghostty.Key.a.index + i],
  for (var i = 0; i < 26; i++)
    0x41 + i: ghostty.Key.values[ghostty.Key.a.index + i],
  for (var i = 0; i < 10; i++)
    0x30 + i: ghostty.Key.values[ghostty.Key.digit0.index + i],
  0x3a: ghostty.Key.semicolon,
  0x3b: ghostty.Key.semicolon,
  0x3c: ghostty.Key.comma,
  0x3d: ghostty.Key.equal,
  0x3e: ghostty.Key.period,
  0x3f: ghostty.Key.slash,
  0x40: ghostty.Key.digit2,
  0x5b: ghostty.Key.bracketLeft,
  0x5c: ghostty.Key.backslash,
  0x5d: ghostty.Key.bracketRight,
  0x5e: ghostty.Key.digit6,
  0x5f: ghostty.Key.minus,
  0x60: ghostty.Key.backquote,
  0x7b: ghostty.Key.bracketLeft,
  0x7c: ghostty.Key.backslash,
  0x7d: ghostty.Key.bracketRight,
  0x7e: ghostty.Key.backquote,
};

final Map<ghostty.Key, int> _keyToCodepoint = {
  ghostty.Key.backquote: 0x60,
  ghostty.Key.backslash: 0x5c,
  ghostty.Key.bracketLeft: 0x5b,
  ghostty.Key.bracketRight: 0x5d,
  ghostty.Key.comma: 0x2c,
  for (var i = 0; i < 26; i++)
    ghostty.Key.values[ghostty.Key.a.index + i]: 0x61 + i,
  for (var i = 0; i < 10; i++)
    ghostty.Key.values[ghostty.Key.digit0.index + i]: 0x30 + i,
  ghostty.Key.equal: 0x3d,
  ghostty.Key.minus: 0x2d,
  ghostty.Key.period: 0x2e,
  ghostty.Key.quote: 0x27,
  ghostty.Key.semicolon: 0x3b,
  ghostty.Key.slash: 0x2f,
};

final Map<LogicalKeyboardKey, ghostty.Key> _logicalToKey = {
  LogicalKeyboardKey.enter: ghostty.Key.enter,
  LogicalKeyboardKey.numpadEnter: ghostty.Key.enter,
  LogicalKeyboardKey.backspace: ghostty.Key.backspace,
  LogicalKeyboardKey.tab: ghostty.Key.tab,
  LogicalKeyboardKey.escape: ghostty.Key.escape,
  LogicalKeyboardKey.delete: ghostty.Key.delete,
  LogicalKeyboardKey.arrowUp: ghostty.Key.arrowUp,
  LogicalKeyboardKey.arrowDown: ghostty.Key.arrowDown,
  LogicalKeyboardKey.arrowLeft: ghostty.Key.arrowLeft,
  LogicalKeyboardKey.arrowRight: ghostty.Key.arrowRight,
  LogicalKeyboardKey.home: ghostty.Key.home,
  LogicalKeyboardKey.end: ghostty.Key.end,
  LogicalKeyboardKey.pageUp: ghostty.Key.pageUp,
  LogicalKeyboardKey.pageDown: ghostty.Key.pageDown,
  LogicalKeyboardKey.insert: ghostty.Key.insert,
  LogicalKeyboardKey.f1: ghostty.Key.f1,
  LogicalKeyboardKey.f2: ghostty.Key.f2,
  LogicalKeyboardKey.f3: ghostty.Key.f3,
  LogicalKeyboardKey.f4: ghostty.Key.f4,
  LogicalKeyboardKey.f5: ghostty.Key.f5,
  LogicalKeyboardKey.f6: ghostty.Key.f6,
  LogicalKeyboardKey.f7: ghostty.Key.f7,
  LogicalKeyboardKey.f8: ghostty.Key.f8,
  LogicalKeyboardKey.f9: ghostty.Key.f9,
  LogicalKeyboardKey.f10: ghostty.Key.f10,
  LogicalKeyboardKey.f11: ghostty.Key.f11,
  LogicalKeyboardKey.f12: ghostty.Key.f12,
};

final Map<PhysicalKeyboardKey, ghostty.Key> _physicalToKey = {
  PhysicalKeyboardKey.backquote: ghostty.Key.backquote,
  PhysicalKeyboardKey.backslash: ghostty.Key.backslash,
  PhysicalKeyboardKey.bracketLeft: ghostty.Key.bracketLeft,
  PhysicalKeyboardKey.bracketRight: ghostty.Key.bracketRight,
  PhysicalKeyboardKey.comma: ghostty.Key.comma,
  PhysicalKeyboardKey.equal: ghostty.Key.equal,
  PhysicalKeyboardKey.minus: ghostty.Key.minus,
  PhysicalKeyboardKey.period: ghostty.Key.period,
  PhysicalKeyboardKey.quote: ghostty.Key.quote,
  PhysicalKeyboardKey.semicolon: ghostty.Key.semicolon,
  PhysicalKeyboardKey.slash: ghostty.Key.slash,
  PhysicalKeyboardKey.digit0: ghostty.Key.digit0,
  PhysicalKeyboardKey.digit1: ghostty.Key.digit1,
  PhysicalKeyboardKey.digit2: ghostty.Key.digit2,
  PhysicalKeyboardKey.digit3: ghostty.Key.digit3,
  PhysicalKeyboardKey.digit4: ghostty.Key.digit4,
  PhysicalKeyboardKey.digit5: ghostty.Key.digit5,
  PhysicalKeyboardKey.digit6: ghostty.Key.digit6,
  PhysicalKeyboardKey.digit7: ghostty.Key.digit7,
  PhysicalKeyboardKey.digit8: ghostty.Key.digit8,
  PhysicalKeyboardKey.digit9: ghostty.Key.digit9,
  for (var i = 0; i < 26; i++)
    PhysicalKeyboardKey.findKeyByCode(0x00070004 + i)!:
        ghostty.Key.values[ghostty.Key.a.index + i],
};
