import 'package:flutter/painting.dart' show Color;
import 'package:xterm/xterm.dart';

// Terminal palette aligned with the app: indigo cursor, our bg/fg, and semantic
// red/green/amber ANSI hues (VS Code-derived) so agent TUIs look cohesive.
//
// Lives in its own terminal-theme file so desktop and remote terminal views can
// share the same palette without importing terminal_pane.dart, which pulls in
// flutter_pty + dart:io and would break the Flutter Web build.
const ccTerminalTheme = TerminalTheme(
  cursor: Color(0xFF818CF8),
  selection: Color(0x55818CF8),
  foreground: Color(0xFFE6EAF2),
  background: Color(0xFF0A0E1A),
  black: Color(0xFF1E2536),
  red: Color(0xFFF87171),
  green: Color(0xFF34D399),
  yellow: Color(0xFFFBBF24),
  blue: Color(0xFF60A5FA),
  magenta: Color(0xFFC084FC),
  cyan: Color(0xFF22D3EE),
  white: Color(0xFFE5E5E5),
  brightBlack: Color(0xFF5E6A82),
  brightRed: Color(0xFFFCA5A5),
  brightGreen: Color(0xFF6EE7B7),
  brightYellow: Color(0xFFFDE68A),
  brightBlue: Color(0xFF93C5FD),
  brightMagenta: Color(0xFFD8B4FE),
  brightCyan: Color(0xFF67E8F9),
  brightWhite: Color(0xFFFFFFFF),
  searchHitBackground: Color(0xFFFFFF2B),
  searchHitBackgroundCurrent: Color(0xFF31FF26),
  searchHitForeground: Color(0xFF000000),
);

int _terminalRgb(Color color) => color.toARGB32() & 0x00ffffff;

Terminal ccTerminal({int maxLines = 1000, bool answerColorQueries = true}) =>
    Terminal(
      maxLines: maxLines,
      defaultForegroundColor: answerColorQueries
          ? _terminalRgb(ccTerminalTheme.foreground)
          : null,
      defaultBackgroundColor: answerColorQueries
          ? _terminalRgb(ccTerminalTheme.background)
          : null,
    );
