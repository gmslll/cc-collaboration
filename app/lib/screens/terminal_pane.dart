import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_pty/flutter_pty.dart';
import 'package:xterm/xterm.dart';

// TerminalSession owns a PTY + xterm Terminal model. The cockpit keeps a list of
// these (one per pickup/worktree) for multi-session tabs and can sendText into
// the active one (e.g. paste the materialized prompt).
class TerminalSession {
  static int _seq = 0;
  final String id = 'ts${_seq++}'; // stable per-run id (for remote addressing)
  final String workdir;
  final String command;
  final String title;
  String? name; // user-given label; overrides the derived title when set
  final Terminal terminal = Terminal(maxLines: 10000);
  Pty? _pty;
  bool _started = false;

  // remoteSink, when set, also receives this terminal's (utf8-decoded) PTY
  // output so a remote phone client can mirror it. Null when nobody's watching.
  void Function(String chunk)? remoteSink;

  TerminalSession(this.workdir, this.command)
    : title = workdir.split('/').where((s) => s.isNotEmpty).isNotEmpty
          ? workdir.split('/').lastWhere((s) => s.isNotEmpty)
          : workdir {
    // Fix xterm 4.0.0's broken wheel reporting so scroll reaches full-screen
    // agent TUIs (claude/codex), which scroll fine in real terminals.
    terminal.mouseHandler = const _WheelMouseHandler();
  }

  // label is what the UI shows: the user-given name, else the derived title.
  String get label => (name != null && name!.isNotEmpty) ? name! : title;

  void start() {
    if (_started) return;
    _started = true;
    final shell = Platform.environment['SHELL'] ?? '/bin/sh';
    // Empty command = a plain interactive login shell (typeable + scrollable);
    // otherwise run the agent command and let the shell exit when it does.
    final args = command.isEmpty ? const ['-i', '-l'] : ['-i', '-c', command];
    final pty = Pty.start(
      shell,
      arguments: args,
      // Declare a real terminal type so full-screen TUIs (claude/codex) enable
      // mouse reporting → wheel scroll reaches them. A Finder-launched .app may
      // otherwise have no TERM. flutter_pty merges this over Platform.environment.
      environment: const {'TERM': 'xterm-256color', 'COLORTERM': 'truecolor'},
      workingDirectory: workdir,
      rows: terminal.viewHeight,
      columns: terminal.viewWidth,
    );
    _pty = pty;
    pty.output
        .cast<List<int>>()
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen((chunk) {
          terminal.write(chunk);
          remoteSink?.call(chunk);
        });
    pty.exitCode.then(
      (code) => terminal.write('\r\n\x1b[90m[已退出: $code]\x1b[0m\r\n'),
    );
    terminal.onOutput = (data) => pty.write(const Utf8Encoder().convert(data));
    terminal.onResize = (w, h, pw, ph) => pty.resize(h, w);
  }

  void sendText(String s) => _pty?.write(const Utf8Encoder().convert(s));

  // resizeFromRemote lets a connected phone size the PTY to its viewport.
  void resizeFromRemote(int rows, int cols) {
    if (rows > 0 && cols > 0) _pty?.resize(rows, cols);
  }

  void dispose() => _pty?.kill();
}

// _WheelMouseHandler fixes mouse-wheel scrolling in full-screen TUIs.
//
// xterm 4.0.0 is doubly broken for the wheel: (1) in basic click-tracking mode
// (?1000h / clickOnly) its default handler drops wheel events entirely, and
// (2) it encodes the wheel button as 64+4 / 64+5 (= 68 / 69) instead of the
// standard transposed X11 codes 64 / 65. Either way claude/codex never see a
// scroll (they scroll fine in real terminals, which send 64 / 65). This handler
// reports the wheel with the correct codes whenever any mouse tracking is on,
// and defers all non-wheel events (clicks/drag/move) to the package default.
class _WheelMouseHandler implements TerminalMouseHandler {
  const _WheelMouseHandler();

  @override
  String? call(TerminalMouseEvent e) {
    if (!e.button.isWheel) return defaultMouseHandler(e);
    if (e.state.mouseMode == MouseMode.none) return null;
    // Only the wheel "press" is reported; releases are not.
    if (e.buttonState != TerminalMouseButtonState.down) return null;
    final code = switch (e.button) {
      TerminalMouseButton.wheelUp => 64,
      TerminalMouseButton.wheelDown => 65,
      TerminalMouseButton.wheelLeft => 66,
      TerminalMouseButton.wheelRight => 67,
      _ => -1,
    };
    if (code < 0) return defaultMouseHandler(e);
    final x = e.position.x + 1;
    final y = e.position.y + 1;
    return switch (e.state.mouseReportMode) {
      MouseReportMode.sgr => '\x1b[<$code;$x;${y}M',
      MouseReportMode.urxvt => '\x1b[${32 + code};$x;${y}M',
      MouseReportMode.normal || MouseReportMode.utf =>
        '\x1b[M${String.fromCharCode(32 + code)}'
            '${String.fromCharCode(32 + x)}${String.fromCharCode(32 + y)}',
    };
  }
}

// TerminalPane renders one session and starts it on first build.
class TerminalPane extends StatefulWidget {
  final TerminalSession session;
  const TerminalPane({super.key, required this.session});

  @override
  State<TerminalPane> createState() => _TerminalPaneState();
}

class _TerminalPaneState extends State<TerminalPane> {
  @override
  void initState() {
    super.initState();
    widget.session.start();
  }

  @override
  Widget build(BuildContext context) {
    return TerminalView(
      widget.session.terminal,
      theme: ccTerminalTheme,
      textStyle: const TerminalStyle(fontFamily: 'JetBrainsMono', fontSize: 13),
      backgroundOpacity: 1,
      padding: const EdgeInsets.all(10),
    );
  }
}

// Terminal palette aligned with the app: indigo cursor, our bg/fg, and semantic
// red/green/amber ANSI hues (VS Code-derived) so agent TUIs look cohesive.
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
